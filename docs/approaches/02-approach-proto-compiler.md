# Approach 2 — Proto as the DSL, go-blocks as the Compiler

## Thesis

Protobuf files annotated with go-blocks custom options become the single source of truth
for a resource — its identity, tenancy, PII classification, retention, actions,
authorization, and state machine — playing exactly the role an Ash resource module plays
in Elixir. A suite of custom protoc plugins driven by `buf generate` and wrapped by a
`blocksctl` CLI compiles that declaration into the whole vertical slice: Ent schema and
migrations, gRPC and HTTP handlers, validation, typed errors, policy checks, audit
emission, PII redaction, retention jobs, admin metadata, TypeScript client, OpenAPI, an
MCP tool manifest, and tests. Everything lands as static Go source with no runtime
reflection, so the compiler's opinions are visible in `git diff` and enforced by `go
build` rather than discovered in production.

## The DSL

Option definitions live in a dedicated, versioned buf module so they can be depended on
without pulling application protos.

```proto
// blocks/options/v1/annotations.proto
syntax = "proto3";
package blocks.options.v1;

import "google/protobuf/descriptor.proto";

extend google.protobuf.MessageOptions { Resource resource = 51000; }
extend google.protobuf.FieldOptions   { Field field = 51001; }
extend google.protobuf.MethodOptions  { Action action = 51002; }
extend google.protobuf.EnumValueOptions { StateValue state = 51003; }

enum Tenancy { TENANCY_UNSPECIFIED = 0; GLOBAL = 1; TENANT = 2; OUTLET = 3; }
enum AuditLevel { AUDIT_NONE = 0; AUDIT_MUTATIONS = 1; AUDIT_ALL = 2; }
enum PII { PII_NONE = 0; PII_BASIC = 1; PII_CONTACT = 2; PII_SENSITIVE = 3; }
enum LegalBasis {
  LEGAL_BASIS_UNSPECIFIED = 0; CONSENT = 1; CONTRACT = 2;
  LEGAL_OBLIGATION = 3; LEGITIMATE_INTEREST = 4;
}

message Resource {
  string name = 1;                 // singular, PascalCase
  string plural = 2;
  Tenancy tenancy = 3;
  bool soft_delete = 4;
  AuditLevel audit = 5;
  string retention = 6;            // ISO-8601 duration, e.g. "P7Y"
  repeated string searchable = 7;  // fields projected into OpenSearch
  repeated string unique = 8;      // composite uniqueness, "tenant_id,sku"
  string state_field = 9;          // enables the state machine generator
}

message Field {
  PII pii = 1;
  LegalBasis legal_basis = 2;
  bool encrypt = 3;                // field-level crypto, GDPR Art. 32
  bool immutable = 4;
  string default = 5;
  string index = 6;                // "btree" | "gin" | "unique"
}

message Action {
  string name = 1;                 // :publish_menu_item
  Kind kind = 2;
  string authorize = 3;            // policy expression, CEL subset
  repeated string transitions = 4; // "DRAFT->ACTIVE"
  bool idempotent = 5;
  string audit_reason_required = 6;
  enum Kind { KIND_UNSPECIFIED = 0; READ = 1; CREATE = 2; UPDATE = 3; DESTROY = 4; CUSTOM = 5; }
}
```

An F&B resource then reads as a declaration, not as plumbing.

```proto
// menu/v1/menu_item.proto
syntax = "proto3";
package fnb.menu.v1;

import "blocks/options/v1/annotations.proto";
import "google/api/annotations.proto";
import "google/protobuf/field_mask.proto";
import "buf/validate/validate.proto";

message MenuItem {
  option (blocks.options.v1.resource) = {
    name: "MenuItem"
    plural: "MenuItems"
    tenancy: OUTLET
    soft_delete: true
    audit: AUDIT_MUTATIONS
    retention: "P7Y"
    searchable: ["name", "sku", "description"]
    unique: ["tenant_id,outlet_id,sku"]
    state_field: "status"
  };

  string id = 1;
  string tenant_id = 2 [(blocks.options.v1.field) = { immutable: true }];
  string outlet_id = 3 [(blocks.options.v1.field) = { immutable: true, index: "btree" }];

  string sku = 4 [(buf.validate.field).string = { min_len: 3, max_len: 32 }];
  string name = 5 [(buf.validate.field).string.min_len = 1];
  string description = 6;
  int64 price_minor = 7 [(buf.validate.field).int64.gte = 0];
  string currency = 8 [(buf.validate.field).string.len = 3];

  Status status = 9;

  // The chef who owns the recipe: personal data under contract basis.
  string owner_email = 10 [(blocks.options.v1.field) = {
    pii: PII_CONTACT legal_basis: CONTRACT encrypt: true
  }];
  string supplier_note = 11 [(blocks.options.v1.field) = { pii: PII_BASIC }];

  enum Status {
    STATUS_UNSPECIFIED = 0;
    DRAFT   = 1 [(blocks.options.v1.state).initial = true];
    ACTIVE  = 2;
    PAUSED  = 3;
    RETIRED = 4 [(blocks.options.v1.state).terminal = true];
  }
}

service MenuItemService {
  rpc CreateMenuItem(CreateMenuItemRequest) returns (MenuItem) {
    option (google.api.http) = { post: "/v1/menu-items" body: "*" };
    option (blocks.options.v1.action) = {
      name: "create" kind: CREATE
      authorize: "actor.has_permission('menu.write') && actor.outlet_id == input.outlet_id"
    };
  }
  rpc PublishMenuItem(PublishMenuItemRequest) returns (MenuItem) {
    option (google.api.http) = { post: "/v1/menu-items/{id}:publish" body: "*" };
    option (blocks.options.v1.action) = {
      name: "publish" kind: CUSTOM
      authorize: "actor.has_role('outlet_manager') && resource.outlet_id == actor.outlet_id"
      transitions: ["DRAFT->ACTIVE", "PAUSED->ACTIVE"]
      idempotent: true
      audit_reason_required: "optional"
    };
  }
  rpc RetireMenuItem(RetireMenuItemRequest) returns (MenuItem) {
    option (blocks.options.v1.action) = {
      name: "retire" kind: DESTROY
      authorize: "actor.has_permission('menu.retire')"
      transitions: ["ACTIVE->RETIRED", "PAUSED->RETIRED"]
      audit_reason_required: "required"
    };
  }
}
```

That is the whole hand-authored contract for the slice. `PurchaseOrder` differs only in
tenancy (`TENANT`), retention (`P10Y` for tax), and a longer transition set
(`DRAFT->SUBMITTED->APPROVED->RECEIVED->CLOSED`).

## The Generator Pipeline

| Plugin                                  | Reads                                     | Emits                                                      |
| --------------------------------------- | ----------------------------------------- | ---------------------------------------------------------- |
| `protoc-gen-go`                         | messages, enums                           | `*.pb.go` types                                            |
| `protoc-gen-go-grpc`                    | services                                  | gRPC client/server interfaces                              |
| `protoc-gen-go-http` (Kratos)           | `google.api.http`                         | HTTP route registration                                    |
| `protoc-gen-validate` / `protovalidate` | `buf.validate.*`                          | request validation                                         |
| `protoc-gen-go-errors`                  | error enums                               | typed error constructors + HTTP mapping                    |
| `protoc-gen-openapiv2` / Gnostic        | `google.api.http`                         | per-BFF OpenAPI documents                                  |
| `protoc-gen-blocks-ent`                 | `resource`, `field`                       | Ent schema, mixins, indexes, migration plan                |
| `protoc-gen-blocks-policy`              | `action.authorize`                        | compiled policy funcs, Casbin/OPA seed data                |
| `protoc-gen-blocks-state`               | `state_field`, `transitions`              | transition table + guard funcs                             |
| `protoc-gen-blocks-audit`               | `resource.audit`, `audit_reason_required` | audit event structs and emitters                           |
| `protoc-gen-blocks-privacy`             | `field.pii`, `legal_basis`, `retention`   | redactors, crypto hooks, RoPA + retention YAML             |
| `protoc-gen-blocks-admin`               | `resource`, `searchable`, actions         | admin UI metadata JSON (columns, forms, filters)           |
| `protoc-gen-blocks-tool`                | actions + authorize                       | MCP tool manifest + dispatch adapter                       |
| `protoc-gen-blocks-ts`                  | messages, HTTP                            | TypeScript types and fetch client                          |
| `protoc-gen-blocks-test`                | actions, transitions                      | golden tests: authz denial, transition legality, redaction |

The buf workspace keeps three modules: `proto/blocks` (options, shared types),
`proto/api` (BFF services with HTTP annotations), `proto/core` (gRPC-only domain
services). `buf.yaml` per module, one `buf.work.yaml` at the root, breaking-change
detection against the `main` branch in CI.

```yaml
# buf.gen.yaml (abridged)
version: v2
managed:
  enabled: true
  override:
    - file_option: go_package_prefix
      value: github.com/dhiazfathra/go-blocks/gen
plugins:
  - local: protoc-gen-go
    out: gen
    opt: paths=source_relative
  - local: protoc-gen-go-grpc
    out: gen
  - local: protoc-gen-blocks-ent
    out: internal/data/ent/schema
    opt: [dialect=postgres, softdelete_mixin=blocks/archival]
  - local: protoc-gen-blocks-policy
    out: internal/policy
    opt: [engine=casbin, strict_unknown_attr=true]
  - local: protoc-gen-blocks-privacy
    out: internal/privacy
    opt:
      [ropa_out=compliance/ropa.yaml, retention_out=compliance/retention.yaml]
  - local: protoc-gen-blocks-tool
    out: internal/agent
    opt: [manifest=mcp/tools.json]
```

The generated/hand-written split is mechanical and enforced by CI: every generated file
ends in `.gen.go`, carries a `// Code generated by protoc-gen-blocks-*. DO NOT EDIT.`
header, and lives under a directory listed in `.gitattributes` as `linguist-generated`.
A CI job regenerates and fails on a dirty tree. Hand-written files sit beside them with
the same stem minus the suffix — `menu_item_hooks.go` next to `menu_item.gen.go` — and
`blocksctl scaffold` creates the hook file once, then never touches it again.

## Generated Output Walkthrough

For `PublishMenuItem`, `protoc-gen-blocks-*` collectively emit roughly this (elided for
length, but structurally what ships):

```go
// menu_item.gen.go — Code generated by protoc-gen-blocks-*. DO NOT EDIT.
func (s *MenuItemService) PublishMenuItem(
	ctx context.Context, req *menuv1.PublishMenuItemRequest,
) (*menuv1.MenuItem, error) {
	if err := protovalidate.Validate(req); err != nil {
		return nil, errors.ErrorInvalidArgument("publish_menu_item", err.Error())
	}
	actor, err := blocksauth.ActorFrom(ctx)
	if err != nil {
		return nil, errors.ErrorUnauthenticated("no_actor", "")
	}

	// Tenant predicate is not optional: the Ent client is scoped, and the
	// generated query repeats the predicate so a mis-scoped client still fails.
	row, err := s.data.MenuItem.Query().
		Where(
			menuitem.IDEQ(req.GetId()),
			menuitem.TenantIDEQ(actor.TenantID),
			menuitem.OutletIDEQ(actor.OutletID),
			menuitem.DeletedAtIsNil(),
		).Only(ctx)
	if err != nil {
		return nil, errors.ErrorMenuItemNotFound("id", req.GetId())
	}

	if err := policy.MenuItemPublish(ctx, actor, row); err != nil { // generated
		return nil, err
	}
	if err := state.MenuItemAssert(row.Status, menuv1.MenuItem_ACTIVE); err != nil {
		return nil, errors.ErrorIllegalTransition(row.Status.String(), "ACTIVE")
	}

	out, err := s.hooks.PublishMenuItem(ctx, PublishContext{
		Actor: actor, Item: row, Req: req, Tx: s.data.Tx(ctx),
	})
	if err != nil {
		return nil, err
	}

	audit.Emit(ctx, audit.Event{
		Action: "menu_item.publish", ResourceID: row.ID,
		TenantID: actor.TenantID, ActorID: actor.ID,
		Before: audit.Redact(row), After: audit.Redact(out),
		Reason: req.GetReason(),
	})
	return privacy.RedactMenuItem(ctx, actor, toProto(out)), nil
}
```

```go
// policy_menu_item.gen.go
func MenuItemPublish(ctx context.Context, a *blocksauth.Actor, r *ent.MenuItem) error {
	if !a.HasRole("outlet_manager") {
		return errors.ErrorForbidden("menu_item.publish", "requires role outlet_manager")
	}
	if r.OutletID != a.OutletID {
		return errors.ErrorForbidden("menu_item.publish", "outlet scope mismatch")
	}
	return nil
}

// privacy_menu_item.gen.go — driven by field.pii
func RedactMenuItem(ctx context.Context, a *blocksauth.Actor, m *menuv1.MenuItem) *menuv1.MenuItem {
	if !a.HasPurpose(privacy.PurposePII) {
		m.OwnerEmail = privacy.MaskEmail(m.OwnerEmail) // PII_CONTACT
	}
	return m
}
```

The developer writes only this:

```go
// menu_item_hooks.go — hand-written, never generated.
func (h *MenuItemHooks) PublishMenuItem(
	ctx context.Context, c PublishContext,
) (*ent.MenuItem, error) {
	if c.Item.PriceMinor == 0 {
		return nil, errors.ErrorPriceRequired("sku", c.Item.Sku)
	}
	return c.Tx.MenuItem.UpdateOne(c.Item).
		SetStatus(menuitem.StatusACTIVE).
		SetPublishedAt(time.Now()).
		Save(ctx)
}
```

Authorization, tenancy, validation, transition legality, audit, and redaction are absent
from the hand-written file because they cannot be forgotten there.

## Escape Hatches

Four levels, in increasing order of surrender.

1. **Override a hook.** The default hook body is a generated stub; replacing its
   contents is the normal path and needs no annotation change.
2. **Opt an action out of generation.** `option (blocks.options.v1.action).generate =
HANDLER_MANUAL` makes the plugin emit only the interface, the policy function, and
   the audit helper. You implement the handler and call the generated helpers yourself.
   The action still appears in the admin metadata, MCP manifest, and RoPA.
3. **Raw Ent or SQL.** Generated Ent schemas are ordinary Ent schemas; `s.data.Raw()`
   returns the unscoped `*sql.DB`. A `blocks.unsafe` build-tagged accessor and a linter
   rule (`blockslint: raw_query_requires_tenant_predicate`) make unscoped access
   deliberate and reviewable rather than impossible.
4. **Hand-written service outside the compiler.** A proto without the `resource` option
   generates nothing but stock stubs. Mixed services coexist in one Kratos app; the only
   loss is the derived compliance artifacts for that resource, which CI reports as an
   uncovered surface rather than silently omitting.

## AI-Agent Friendliness

This is the approach's strongest claim. The annotated proto set _is_ a machine-readable
resource registry: descriptors are self-describing, buf can emit a
`FileDescriptorSet` as JSON, and every action carries its kind, authorization
expression, transitions, PII touchpoints, and audit level. An agent does not need to
read Go to learn what the system can do.

Three concrete affordances:

- **Coding agents write annotations, not plumbing.** The unit of work becomes "add a
  `discount_percent` field, PII none, and a `SetDiscount` action authorized to
  `finance_manager`". Generation is deterministic, so agent output is reviewable as a
  small proto diff plus a regenerated tree; a wrong annotation fails `buf lint`,
  `buf breaking`, or `go build` rather than shipping.
- **Runtime agents call actions through a generated MCP manifest.** `protoc-gen-blocks-tool`
  emits one tool per action with JSON Schema derived from the request message, the
  authorization expression as human-readable text, and a side-effect classification from
  `Action.Kind`. Read actions are safe to expose broadly; `DESTROY` actions are
  gated.
- **Per-block usage rules.** Each generated package ships `usage-rules.md` derived from
  the same descriptors, so an agent reading the repository gets the same facts a human
  reviewer does.

The risks are real and specific. **Prompt injection** is the main one: an agent
summarizing supplier notes can be instructed by the note's contents to call
`RetireMenuItem`. Mitigations that hold: the MCP adapter executes every call through
the _same_ generated policy function as HTTP and gRPC, using the end user's actor rather
than a service account — an injected instruction inherits the user's permissions and
nothing more; agent-invoked mutations are marked `channel: agent` in the audit event so
they are queryable and revocable; `Action.Kind == DESTROY` and any action with
`audit_reason_required: "required"` are excluded from autonomous invocation and require
a human confirmation token in the request. Separately, **authorization expressions are
data an agent can propose changes to**, so `authorize` diffs get a CODEOWNERS gate and
a generated test asserting that no action's policy weakened relative to the previous
descriptor set. Finally, tool manifests must never carry raw PII examples; the manifest
generator emits schema only, with `pii` fields marked and example values synthesized.

## Compliance Posture

Annotations become enforced controls because the enforcement code is generated from
them and the generation is verified in CI.

| Requirement                            | Annotation                                       | Generated control                                                                         |
| -------------------------------------- | ------------------------------------------------ | ----------------------------------------------------------------------------------------- |
| GDPR Art. 30 / PDP Art. 31 records     | `field.pii`, `legal_basis`, `resource.retention` | `compliance/ropa.yaml` — a data inventory per resource and field, regenerated every build |
| GDPR Art. 15 access                    | `resource`, `pii`                                | per-subject export query joining every resource whose fields reference the subject        |
| GDPR Art. 17 erasure                   | `soft_delete`, `retention`                       | erasure job plus a crypto-shred path for `encrypt: true` fields                           |
| GDPR Art. 25 data protection by design | defaults                                         | tenancy predicate, redaction, and least-privilege policy are generated, not opt-in        |
| GDPR Art. 32 / ISO 27001 A.8.24        | `field.encrypt`                                  | field-level envelope encryption via `blocks/crypto`                                       |
| ISO 27001 A.8.15 logging               | `resource.audit`                                 | tamper-evident audit events with before/after redacted diffs                              |
| ISO 27001 A.5.15 access control        | `action.authorize`                               | compiled policy funcs plus Casbin seed data and a policy matrix report                    |
| PDP UU 27/2022 retention limits        | `resource.retention`                             | `compliance/retention.yaml` and a scheduled purge job per resource                        |

What an auditor receives is not a narrative: a generated RoPA listing every personal
data element with its legal basis and retention period, a retention matrix, an
action-by-role authorization matrix, an audit-event catalogue, and a CI artifact proving
the running binary was built from those exact descriptors. The honest limit is that
generation proves the control _exists_, not that it is _correct_ — a wrong
`legal_basis` produces a confidently wrong RoPA, so annotations still need legal
review. Consent capture, DPIAs, breach notification, and vendor management remain
process work outside the compiler.

## Effort and Timeline

Estimates assume one engineer fluent in protobuf descriptors and Go codegen; a first
plugin costs roughly double while the shared descriptor-walking library and golden-file
test harness are built.

| Component                                                                | Engineer-weeks | Order |
| ------------------------------------------------------------------------ | -------------- | ----- |
| Option definitions, buf workspace, `blocksctl` skeleton, codegen harness | 3              | 1     |
| `protoc-gen-blocks-ent` (schema, mixins, indexes, migrations)            | 4              | 2     |
| `protoc-gen-blocks-policy` (CEL subset compiler)                         | 4              | 3     |
| Handler generator (gRPC + HTTP wiring, Wire providers)                   | 3              | 4     |
| `protoc-gen-blocks-audit`                                                | 2              | 5     |
| `protoc-gen-blocks-privacy` (redaction, RoPA, retention)                 | 3              | 6     |
| `protoc-gen-blocks-state`                                                | 1.5            | 7     |
| `protoc-gen-blocks-test` (golden authz/transition tests)                 | 2              | 8     |
| `protoc-gen-blocks-tool` (MCP manifest + adapter)                        | 2              | 9     |
| `protoc-gen-blocks-admin`                                                | 3              | 10    |
| `protoc-gen-blocks-ts`                                                   | 2              | 11    |

Minimum viable generator set is items 1–5: options, Ent, policy, handlers, audit. That
is roughly 16 engineer-weeks and already delivers the core claim — a compliant vertical
slice from a proto. Privacy and state follow immediately because the F&B mini-ERP needs
retention and purchase-order workflow. Admin and TypeScript generation are deferrable;
hand-written Vben screens are cheaper than an admin metadata compiler until the
resource count passes roughly thirty.

## Tradeoffs

| Strengths                                                                                                                           | Weaknesses                                                                                                                                                                                           |
| ----------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| One declaration drives every layer; drift between schema, API, and policy becomes impossible by construction                        | You now maintain a compiler. Every Go, Kratos, Ent, or buf upgrade is a plugin maintenance event, and the bus factor is the person who wrote the descriptor walker                                   |
| Zero runtime reflection: generated static Go, compile-time type safety, no interpretation cost on the hot path                      | Proto options are a data language with no expressions. `authorize` strings need a hand-written CEL-subset parser, and conditionals or computed defaults become awkward stringly-typed mini-languages |
| Diffs are readable; a reviewer sees exactly what changed in the enforcement code                                                    | Generated volume is large — plausibly 15–30x the annotated proto — and review fatigue sets in fast. Reviewers start rubber-stamping `.gen.go` and then miss the one diff that mattered               |
| Compliance artifacts fall out of the same source, so the audit story is generated rather than assembled                             | Debugging happens in code nobody wrote. Stack traces point at `.gen.go` line numbers that move on every regeneration; delve sessions are noisy                                                       |
| Agent-legible: descriptors are a resource registry, tool manifests come free, authorization is enforced identically across channels | buf/protoc toolchain fragility: plugin version skew, `managed mode` surprises, and Kratos v3's young plugin ecosystem all break the build in ways unrelated to the product                           |
| Deterministic scaffolding — `blocksctl generate` output is reproducible and CI-verifiable                                           | Onboarding cost is steep. A new hire must learn proto, buf, Ent, Kratos, _and_ the go-blocks annotation vocabulary before shipping a field                                                           |
| Escape hatches are structural, not bolted on: opting an action out is a one-line annotation                                         | Iteration latency: a one-field change means regenerating, rebuilding, and re-running migrations. Fast in absolute terms, slower than editing a resource module in place                              |

## Risks and Mitigations

| Risk                                                         | Likelihood | Impact   | Mitigation                                                                                                                                                                             |
| ------------------------------------------------------------ | ---------- | -------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Plugin maintenance overwhelms product work                   | High       | High     | Cap the plugin set at the MVP five for the first year; every plugin needs golden-file tests and one named owner; prefer stock plugins wherever they exist                              |
| Annotation language grows into an unmaintainable DSL         | High       | Medium   | Hard rule: options declare facts, never behavior. Anything needing an expression beyond the CEL subset moves into a hand-written hook                                                  |
| Kratos v3 plugin ecosystem lags                              | Medium     | Medium   | Generate transport wiring in-house from `google.api.http` rather than depending on contrib plugins; keep a v2 fallback target in CI                                                    |
| Generated code review becomes theatre                        | High       | Medium   | Mark generated files `linguist-generated`, collapse them in review, and gate on generated _diff summaries_ (policy matrix delta, RoPA delta) rather than raw code                      |
| Descriptor breaking changes silently break clients           | Medium     | High     | `buf breaking` against `main` in CI, plus a generated compatibility test per released API version                                                                                      |
| Compiler correctness bug ships a missing authorization check | Low        | Critical | `protoc-gen-blocks-test` emits a denial test per action; a mutation-testing pass on the policy compiler; policy diffs require CODEOWNERS approval                                      |
| Agent-invoked action abused via prompt injection             | Medium     | High     | Agent calls run through the same policy functions with the end user's actor; `DESTROY` and reason-required actions need a human confirmation token; `channel: agent` recorded in audit |
| Team rejects the abstraction and forks around it             | Medium     | High     | Ship escape hatch level 4 from day one and document it prominently; measure adoption by the ratio of annotated to hand-written services                                                |

## Verdict

This is the approach with the highest ceiling and the highest fixed cost. It delivers
the Ash property that matters — declare the resource, derive the layers — without paying
Elixir's runtime-metaprogramming price, and it produces compliance and agent-tooling
artifacts as a byproduct rather than a project. But the honest framing is that go-blocks
becomes a compiler product with a backend built on it, and compilers are unforgiving:
plugin maintenance never ends, the annotation language will strain the moment it needs
an expression, and a bug in the policy generator is a security incident across every
resource at once. It is the right destination if go-blocks is a multi-year platform
investment with a dedicated owner, and the wrong first move if the F&B mini-ERP needs to
ship this year — in which case build the MVP five plugins against a hand-written
blueprint that already works, and let the compiler absorb the blueprint incrementally.
