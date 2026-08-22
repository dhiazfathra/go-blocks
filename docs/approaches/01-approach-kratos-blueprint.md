# Approach 1 — Kratos Blueprint

Baseline approach. A curated blueprint repository plus hand-written reusable libraries.
No custom code generation beyond stock `buf` plugins. No runtime resource engine.

## Thesis in three sentences

go-blocks is a template repository plus roughly twenty well-factored Go libraries, and
all leverage comes from convention and library quality rather than from metaprogramming.
Vertical slices are hand-written by developers who wire proto-generated Kratos services
to block interfaces, in the same shape every time, because the blueprint leaves only one
obvious place for each kind of code. Everything a developer writes is ordinary Go that
`go doc`, `gopls`, a debugger, and a coding agent can read without knowing anything about
go-blocks itself.

## Architecture

One Go module for the platform, one per product. The platform module ships blocks and the
in-process/gRPC transport seam; the blueprint is a `gh repo create --template` target that
already contains a working two-module monolith, migrations, compose file, and CI.

```text
go-blocks/                          # platform module: github.com/org/go-blocks
├── blocks/
│   ├── authn/            # +usage-rules.md, +doc.go per block
│   ├── authz/
│   ├── audit/
│   ├── tenancy/
│   └── ... (see catalogue)
├── transport/
│   ├── inproc/           # direct-call ClientConn shim
│   └── grpcx/            # dialer, middleware chain, registry
├── kit/
│   ├── ctxkit/           # tenant, actor, request-id, locale in context
│   └── errkit/           # proto error codes -> HTTP/gRPC status
└── AGENTS.md

acme-fnb/                           # product module, from the blueprint template
├── api/
│   ├── menu/v1/menu.proto          # core domain: gRPC only
│   ├── inventory/v1/...
│   └── bff/admin/v1/admin.proto    # google.api.http lives ONLY here
├── gen/                            # buf output, committed
├── internal/
│   ├── modules/
│   │   ├── menu/
│   │   │   ├── service.go          # proto service impl (transport-facing)
│   │   │   ├── biz/                # use cases, no Ent, no proto structs
│   │   │   ├── data/               # Ent repo impls
│   │   │   ├── ent/schema/
│   │   │   └── module.go           # wire.ProviderSet + Register(grpc.Server)
│   │   └── inventory/
│   ├── bff/admin/                  # HTTP handlers calling module clients
│   └── host/
│       ├── monolith/main.go        # imports every module.ProviderSet
│       └── menu-svc/main.go        # imports one; same code, own binary
├── migrations/                     # atlas/tern SQL, versioned, no auto-DDL
└── AGENTS.md
```

Module boundaries are enforced socially plus one CI rule: a module may import
`go-blocks/blocks/...`, its own subtree, and other modules' **generated clients** — never
another module's `biz` or `data`. A `go-arch-lint`-style check in CI fails the build on
violation. That is the entire enforcement mechanism, and its weakness is discussed below.

The monolith host constructs every module in one process and registers all of them on one
Kratos `grpc.Server` and one `http.Server`. Extracting a module to a standalone Kratos
service is a `main.go` copy plus a deployment change; module code does not move.

### The transport seam

Callers never hold a concrete implementation. They hold the buf-generated client
interface, and the difference between monolith and microservice is which `grpc.ClientConn`
they were given.

```go
// blocks: transport/inproc — a ClientConn that dispatches in-process.
package inproc

// Hub registers server implementations so generated clients can call them
// without a socket. Interceptors still run, so audit/authz/otel behave
// identically in both modes.
type Hub struct {
	methods map[string]grpc.MethodHandler // generated _ServiceDesc handlers
	impls   map[string]any                // service implementation per method
	chain   grpc.UnaryServerInterceptor
}

func (h *Hub) Invoke(ctx context.Context, method string, args, reply any, _ ...grpc.CallOption) error {
	handler, ok := h.methods[method]
	if !ok {
		return status.Errorf(codes.Unimplemented, "inproc: %s", method)
	}
	// The generated handler owns the request type; the decoder hands it our args.
	dec := func(dst any) error {
		proto.Merge(dst.(proto.Message), args.(proto.Message))
		return nil
	}
	resp, err := handler(h.impls[method], ctx, dec, h.chain)
	if err != nil {
		return err
	}
	proto.Merge(reply.(proto.Message), resp.(proto.Message))
	return nil
}

func (h *Hub) NewStream(context.Context, *grpc.StreamDesc, string, ...grpc.CallOption) (grpc.ClientStream, error) {
	return nil, status.Error(codes.Unimplemented, "inproc: streaming requires grpc transport")
}
```

```go
// product: internal/bff/admin/wire.go — the only line that changes on extraction.
func provideMenuClient(hub *inproc.Hub, cfg *conf.Bootstrap) menuv1.MenuClient {
	if addr := cfg.Peers["menu"]; addr != "" {
		return menuv1.NewMenuClient(grpcx.MustDial(addr)) // remote
	}
	return menuv1.NewMenuClient(hub) // in-process
}
```

Consequence to accept up front: in-process calls still marshal-free but do pass through
the interceptor chain and through proto structs, so the seam costs a little allocation and
forbids sharing transactions across modules. Cross-module consistency is the outbox
(`blocks/events`), never a shared `*ent.Tx`. That is the correct constraint for later
extraction, and it is a real tax paid on day one.

## The block catalogue

Every block is a hand-written Go package: interfaces, a default implementation over the
named dependency, Kratos middleware where relevant, and a `usage-rules.md`.

| Block         | Package                | Wraps                                        | Contract (one line)                                                                              |
| ------------- | ---------------------- | -------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| authn         | `blocks/authn`         | Kratos middleware, `go-jose`, WebAuthn       | `Authenticate(ctx, Credential) (Principal, error)` plus JWT/session middleware.                  |
| authz         | `blocks/authz`         | Casbin (default), OPA (adapter)              | `Check(ctx, Subject, Action, Resource) (bool, error)`; interceptor denies by default.            |
| audit         | `blocks/audit`         | Ent hooks + append-only table                | `Record(ctx, Event) error`; auto-emits per mutating RPC (ISO 27001 A.8.15).                      |
| tenancy       | `blocks/tenancy`       | Ent privacy policies                         | `FromContext(ctx) (TenantID, error)`; injects row predicates in the data layer.                  |
| consent       | `blocks/consent`       | own tables + `blocks/audit`                  | `Grant/Revoke/Check(ctx, Subject, Purpose)`; purpose-bound (GDPR Art. 6/7, PDP Art. 20).         |
| retention     | `blocks/retention`     | asynq/river schedules                        | `Register(Policy)`; sweeps expiring rows to soft-delete then hard-delete.                        |
| crypto        | `blocks/crypto`        | `filippo.io/age`, Ent field hooks, KMS       | `Encrypt/Decrypt(ctx, purpose, []byte)`; envelope keys, per-subject DEK.                         |
| media         | `blocks/media`         | MinIO SDK                                    | `Put/Presign/Delete(ctx, Object)`; content-type sniffing, virus-scan hook.                       |
| jobs          | `blocks/jobs`          | asynq (Redis) or river (Postgres)            | `Enqueue(ctx, Task)` + typed handler registration with retry/backoff policy.                     |
| events        | `blocks/events`        | Ent tx + outbox table + Watermill            | `Publish(tx, Event) error` transactionally; at-least-once dispatch to subscribers.               |
| search        | `blocks/search`        | OpenSearch Go client                         | `Index/Query(ctx, ...)`; projection built from outbox events, never dual-write.                  |
| i18n          | `blocks/i18n`          | `go-i18n`, CLDR data                         | `T(ctx, key, args...)`; locale resolved from context, fallback chain.                            |
| money         | `blocks/money`         | `govalues/decimal` + proto `Money`           | `Amount` value type: exact decimal, currency-checked arithmetic, no float.                       |
| statemachine  | `blocks/statemachine`  | own (small), `stateless`-style               | `Fire(ctx, entity, event)`; declarative transition table, guards, audit on transition.           |
| workflow      | `blocks/workflow`      | jobs + outbox (saga), Temporal adapter       | `Run(ctx, Definition, input)`; compensating steps, idempotency keys.                             |
| ratelimit     | `blocks/ratelimit`     | `redis_rate`, `golang.org/x/time/rate`       | Kratos middleware: per-tenant, per-principal, per-method quotas.                                 |
| observability | `blocks/observability` | OTel SDK, Jaeger, Prometheus                 | `Setup(cfg) (shutdown func)`; traces/metrics/logs with tenant + actor baggage.                   |
| config        | `blocks/config`        | Kratos config, file + env + etcd             | `Load[T]` over layered sources returning `(*T, error)`; proto-defined config, validated at boot. |
| migration     | `blocks/migration`     | atlas (schema diff) + tern (SQL apply)       | `Verify(ctx, db) error` at boot; refuses to start on drift. No auto-DDL.                         |
| localdb       | `blocks/localdb`       | SQLite (`modernc.org/sqlite`), litestream    | Same Ent client against SQLite; `Sync(ctx)` push/pull with conflict policy.                      |
| archival      | `blocks/archival`      | Ent mixin                                    | `deleted_at` mixin + recycle-bin queries; restore within retention window.                       |
| pii           | `blocks/pii`           | proto field options + `protoc-gen-go-redact` | Redacts logs/errors by proto annotation; classification list is generated.                       |

Twenty-two shipped units. Two of them (`money`, `statemachine`) are genuinely small and
could be dropped, but both encode decisions teams otherwise get wrong.

## What a developer actually writes

Feature: changing a menu item's price requires approval when the delta exceeds a
threshold. This is a real F&B requirement — price changes are audited and dual-controlled.

**1. Proto.** Core domain, gRPC only; typed errors and PII annotations declared here.

```protobuf
// api/menu/v1/menu.proto
syntax = "proto3";
package menu.v1;

import "buf/validate/validate.proto";
import "google/type/money.proto";
import "errors/errors.proto";

service Menu {
  rpc ProposePriceChange(ProposePriceChangeRequest) returns (PriceChange);
  rpc ApprovePriceChange(ApprovePriceChangeRequest) returns (PriceChange);
}

enum MenuError {
  option (errors.default_code) = 500;
  APPROVAL_REQUIRED  = 0 [(errors.code) = 409];
  SELF_APPROVAL      = 1 [(errors.code) = 403];
}

message ProposePriceChangeRequest {
  string item_id = 1 [(buf.validate.field).string.uuid = true];
  google.type.Money new_price = 2 [(buf.validate.field).required = true];
  string reason = 3 [(buf.validate.field).string.min_len = 8];
}

message PriceChange {
  string id = 1;
  string item_id = 2;
  google.type.Money old_price = 3;
  google.type.Money new_price = 4;
  enum State { PENDING = 0; APPROVED = 1; REJECTED = 2; APPLIED = 3; }
  State state = 5;
}
```

**2. Generated.** `buf generate` — stock plugins only: `protoc-gen-go`,
`protoc-gen-go-grpc`, `protoc-gen-go-http` (Kratos), `protoc-gen-go-errors`,
`protoc-gen-validate`/`protovalidate`, `protoc-gen-openapiv2`, `protoc-gen-ts`. Developer
writes zero generator code. Output: `MenuServer`/`MenuClient` interfaces,
`ErrorApprovalRequired(...)` constructors with HTTP mapping, request validators, TS
client for the admin UI.

**3. Hand-written business logic.** One use case, blocks injected as interfaces.

```go
// internal/modules/menu/biz/price_change.go
package biz

type PriceChangeUC struct {
	repo   PriceChangeRepo
	items  ItemRepo
	authz  authz.Checker
	audit  audit.Recorder
	pii    pii.Classifier // supplies the classification audit.Redact requires
	clock  clock.Clock    // injected so Event.At is deterministic under test
	sm     *statemachine.Machine[PriceChangeState, PriceChangeEvent]
	events events.Publisher
	thresh money.Amount
}

func (uc *PriceChangeUC) Propose(ctx context.Context, in ProposeInput) (*PriceChange, error) {
	allowed, err := uc.authz.Check(ctx, authz.SubjectFromContext(ctx), "menu.price.propose", in.ItemID)
	if err != nil {
		return nil, err
	}
	if !allowed {
		return nil, authz.ErrDenied
	}
	item, err := uc.items.Get(ctx, in.ItemID) // tenancy predicate applied in data layer
	if err != nil {
		return nil, err
	}

	pc := &PriceChange{
		ItemID: item.ID, OldPrice: item.Price, NewPrice: in.NewPrice,
		Reason: in.Reason, ProposedBy: ctxkit.ActorID(ctx),
		State:  PriceChangePending,
	}
	delta, err := in.NewPrice.Sub(item.Price)
	if err != nil {
		return nil, err // currency mismatch is an error, not a silent coercion
	}
	autoApprove := delta.Abs().Cmp(uc.thresh) <= 0

	err = uc.repo.Tx(ctx, func(tx data.Tx) error {
		if err := uc.repo.Create(tx, pc); err != nil {
			return err
		}
		if autoApprove {
			if err := uc.sm.Fire(ctx, pc, PriceChangeApprove); err != nil {
				return err
			}
			if err := uc.items.SetPrice(tx, item.ID, in.NewPrice); err != nil {
				return err
			}
		}
		// Audit is written inside the same transaction: no commit without its
		// record, and a recorder failure rolls the price change back.
		//
		// Payloads go through audit.Redact, the block's only Payload constructor:
		// Record fails closed on a raw or unclassified value, so a hand-built
		// struct literal would be rejected even if it compiled.
		before, err := audit.Redact(uc.pii, "menu.MenuItem", item)
		if err != nil {
			return err
		}
		after, err := audit.Redact(uc.pii, "menu.PriceChange", pc)
		if err != nil {
			return err
		}
		actor := ctxkit.Actor(ctx)
		if err := uc.audit.Record(data.WithTx(ctx, tx), audit.Event{
			Actor: actor, TenantID: actor.TenantID,
			Action: "menu.price_change.propose",
			Resource: "menu.MenuItem", Entity: item.ID,
			Outcome: audit.Allowed, Reason: in.Reason,
			Channel: ctxkit.Channel(ctx), RequestID: ctxkit.RequestID(ctx),
			At:     uc.clock.Now(),
			Before: before, After: after,
		}); err != nil {
			return err
		}
		return uc.events.Publish(tx, events.New("menu.price_change.proposed", pc))
	})
	if err != nil {
		return nil, err
	}
	return pc, nil
}
```

```go
// internal/modules/menu/service.go — thin: proto <-> domain, errors, nothing else.
func (s *MenuService) ProposePriceChange(ctx context.Context, req *v1.ProposePriceChangeRequest) (*v1.PriceChange, error) {
	pc, err := s.uc.Propose(ctx, biz.ProposeInput{
		ItemID:   req.ItemId,
		NewPrice: money.FromProto(req.NewPrice),
		Reason:   req.Reason,
	})
	if err != nil {
		return nil, err
	}
	return toProto(pc), nil
}
```

The developer also writes: the Ent schema (`ent/schema/pricechange.go` with
`tenancy.Mixin`, `archival.Mixin`, `audit.Mixin`), the Ent repo implementation, the
statemachine transition table, a `migrations/0007_price_change.sql`, the Casbin policy
rows, the admin BFF handler, and tests. Call it 250–400 lines plus tests per feature of
this size. That number is the honest measure of this approach: the blocks removed the
cross-cutting concerns, not the plumbing.

## AI-agent friendliness

What works. The layout is deterministic, so an agent asked to add a feature can be told
"read `internal/modules/menu` and do the same in `inventory`" and succeed — imitation is
the dominant mode of coding agents and this approach optimizes for it. `AGENTS.md` at both
module roots names the layer rules, the forbidden imports, and the command sequence
(`buf generate`, `go generate ./ent`, `atlas migrate diff`, `go test ./...`). Each block
carries `usage-rules.md` in the Ash `UsageRules` spirit: the three correct call patterns,
the two common mistakes, the invariant that must hold. Because everything is plain Go,
`go doc ./blocks/authz` and `gopls` give an agent complete, accurate signatures without a
bespoke introspection protocol, and compiler plus `wire` errors are a fast, precise
feedback loop — a missing dependency fails at build time with a named type.

Where it falls short, and this is the decisive gap. There is no machine-readable registry
of resources and actions. Nothing can answer "what actions exist on MenuItem, what
arguments do they take, who may call them" without reading Go source. Consequences:
runtime LLM agents cannot be handed a generated tool surface — every exposed tool is
hand-written; the admin UI cannot be derived; authorization coverage cannot be audited
mechanically (a use case that forgets `authz.Require` compiles and passes tests); and
"same shape every time" is a convention an agent can silently break. Proto gets partway
there — service methods, field types, and validation rules are introspectable — but proto
knows nothing about which permission guards a method, which state transition it performs,
or which PII purposes it touches, because that lives in hand-written Go. Approaches 2–4
exist precisely to close this gap.

## Compliance posture

Blocks cover the mechanisms; projects still carry the paperwork and the judgment calls.

Covered by construction: access control (A.5.15–A.5.18) via `authz` deny-by-default
interceptor plus `tenancy` row predicates in Ent privacy policies, so a forgotten `WHERE`
cannot leak across tenants. Logging and monitoring (A.8.15–A.8.16) via `audit` Ent hooks
that record actor, tenant, before/after, and reason on every mutation, into an append-only
table. Cryptography (A.8.24, GDPR Art. 32) via `crypto` field-level envelope encryption
with per-subject DEKs, so key destruction is a usable erasure strategy (see
`10-compliance-blocks.md`). Data-subject rights: `pii` annotations generate the field
classification inventory, which makes Art. 15 export and Art. 17 erasure a traversal over
annotated fields rather than an archaeology exercise; `retention` enforces storage
limitation (Art. 5(1)(e)) with scheduled sweeps; `consent` gives purpose-bound lawful
basis with a revocation trail satisfying GDPR Art. 7(3) and PDP Law Art. 20.

Remains manual per project: the RoPA / processing-activity record, DPIAs, the ISO
statement of applicability and risk register, breach-notification runbooks (72-hour GDPR
Art. 33, PDP Art. 46 3×24-hour), processor agreements, and — critically — deciding which
fields are PII and which purpose each processing serves. A developer who does not annotate
a field gets no encryption, no redaction, and no erasure coverage, silently. That is the
compliance analogue of the missing action registry: the framework can enforce a mechanism
once invoked, but cannot detect that it was never invoked. Reviewers, not tooling, close
that hole here.

## Effort and timeline

Team of three senior Go engineers plus part-time review. Estimates are engineer-weeks of
build effort, excluding the product features themselves.

| Phase                     | Weeks | Ships                                                                                                                        |
| ------------------------- | ----- | ---------------------------------------------------------------------------------------------------------------------------- |
| 0 — spike                 | 3     | Kratos v3 monolith, `inproc` hub, buf pipeline, one module end to end, CI.                                                   |
| 1 — foundation blocks     | 8     | config, observability, migration, tenancy, authn, authz, audit, errkit. First real feature slice buildable.                  |
| 2 — blueprint template    | 4     | Template repo, `AGENTS.md`, per-block `usage-rules.md`, compose stack, admin BFF skeleton, TS client. Second team can start. |
| 3 — data and async blocks | 8     | events/outbox, jobs, media, search, archival, retention, crypto, pii.                                                        |
| 4 — domain blocks         | 6     | money, statemachine, workflow, i18n, ratelimit, consent.                                                                     |
| 5 — local-first           | 6     | localdb SQLite path, litestream, sync + conflict policy, offline POS proof.                                                  |
| 6 — hardening             | 5     | Kratos v3 churn absorption, load test, compliance evidence pack, docs.                                                       |

Roughly 40 engineer-weeks to a genuinely reusable platform; about 15 to the point where a
second product team can ship on it, which matters more than the total. Phase 5 is the
riskiest estimate — offline sync is where this doubles if the conflict model is not decided
early.

## Tradeoffs

| Strengths                                                                        | Weaknesses                                                                           |
| -------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| No framework to learn beyond Kratos and Ent; any Go hire is productive in days.  | Every vertical slice is hand-written; per-feature cost never drops below ~300 lines. |
| Debuggable end to end — stack traces land in code someone wrote.                 | Consistency is voluntary; nothing fails the build when a module deviates.            |
| Zero generator maintenance; stock buf plugins only.                              | No machine-readable action registry; no derived admin UI, no derived agent tools.    |
| Escape hatches are free — there is nothing to escape from.                       | Cross-cutting change (new audit field) means editing N modules by hand.              |
| Fastest path to a working, shippable platform.                                   | Compliance mechanisms can be silently skipped by omission.                           |
| Low exposure to Kratos v3 churn: blocks wrap it, product code rarely touches it. | Blueprint drifts from projects the moment they are created — no upgrade path.        |
| Blocks are independently useful and testable; each can be adopted alone.         | Twenty-two libraries is a real maintenance and versioning surface for a small team.  |

**When this is the right answer.** One to three teams, one product line, a hard delivery
date, and a platform team of two to four people. Everyone shares a code review culture and
a Slack channel, so convention holds because the same people enforce it. It is also the
right first step regardless of ambition: the blocks written here are the substrate every
other approach needs, so this work is never wasted — a compiler (Approach 2) or a resource
engine (Approach 3) generates or drives _these libraries_. Building the engine first, with
no blocks under it, is the classic failure mode.

**How this fails at scale.** With N teams and M services the blueprint is a snapshot, not
a dependency: team A's repo forked the template in Q1 and team B's in Q3, and they now
differ in module layout, middleware order, and error mapping. Copy-paste is the intended
propagation mechanism for everything the blocks do not cover — the service/biz/data
plumbing, the BFF handler shape, the migration workflow — so divergence is not a
discipline failure, it is the design working as specified. Nothing detects that team C's
`biz` layer calls Ent directly, that team D dropped the `authz` interceptor from its
middleware chain, or that team E's audit events omit `reason`. A new compliance requirement
— say, PDP-mandated purpose logging on every read of PII — is a coordinated pull request
across M repositories with no mechanical way to verify completion. And because the
convention lives in prose, the twentieth engineer's mental model is a lossy copy of the
second's. This approach scales with the number of people who can hold the conventions in
their heads, which is roughly fifteen.

## Risks and mitigations

| Risk                                               | Likelihood | Impact | Mitigation                                                                                                                                                    |
| -------------------------------------------------- | ---------- | ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Blueprint drift across projects                    | High       | High   | Version the template; ship `go-blocks upgrade` diff notes per release; keep as much as possible _inside_ versioned blocks rather than in the template.        |
| Convention violations undetected                   | High       | High   | CI import-boundary linter, a custom `go/analysis` pass asserting every mutating RPC calls `authz.Require`, and a golden-layout test. Accept partial coverage. |
| Kratos v3 ecosystem plugin lag                     | Medium     | Medium | Depend only on stock buf plugins plus `protoc-gen-go-http`; keep a v2-compatible transport shim behind `blocks/transport`; be ready to vendor one plugin.     |
| Twenty-two blocks outgrow a 3-person team          | Medium     | High   | Tier them: 8 core blocks get SLAs and semver, the rest are explicitly best-effort and may be inlined into products.                                           |
| Offline sync conflict model wrong                  | Medium     | High   | Decide per-entity policy (LWW, append-only, server-authoritative) in Phase 0 and encode it in `localdb`; POS load test before Phase 5 closes.                 |
| Ent lock-in in the data layer                      | Low        | Medium | `biz` never imports Ent; repos are interfaces. Swapping to sqlc is a data-layer rewrite, not a product rewrite.                                               |
| Audit/PII coverage gaps found during certification | Medium     | High   | Generate the PII inventory from proto annotations in CI and diff it against the reviewed classification list; fail on unclassified new fields.                |
| No agent-facing action registry blocks the AI goal | High       | Medium | Accept for v1; design proto annotations now (`action`, `permission`, `pii.purpose`) so a later generator can read them without a proto rewrite.               |

## Verdict

This is the approach that certainly works and certainly does not fully satisfy the brief.
It delivers a shippable, debuggable, hireable platform in about ten calendar weeks with
three engineers, and every line of it survives into any of the other four approaches
because generators and engines still need libraries underneath. What it cannot deliver is
goals 3 and 5 of the charter: "dead consistent and predictable" degrades to "consistent
while the founding team reviews every PR", and "AI-agent friendly" stops at legibility —
agents can read and imitate this codebase well, but nothing can enumerate its actions,
derive its admin surface, or prove its authorization coverage. Build it, but build it with
the proto annotations that a later compiler will consume, and treat it as Phase 1 of
Approach 5 rather than a destination.
