# Bootstrap Tooling, Skills, and Clone Plans

Builds on `00-context-and-research.md`. Where that document establishes what go-blocks
is and which two systems it must be able to reproduce, this one covers the surface a
developer or agent actually touches on day one, and what it takes to clone GoWind CMS
and GoWind Shop with it.

## 1. Thesis — the bootstrap surface is the product

A framework is adopted or rejected in the first thirty minutes. Nobody evaluates the
audit block's ISO 27001 alignment before they have a service running locally. If
`blocksctl new project` to a green test run takes longer than a coffee, the evaluation
ends there and the team writes another bespoke Kratos skeleton — which is precisely the
outcome go-blocks exists to prevent.

This has a sharper consequence than "good DX matters". Every constraint in section 6 of
the baseline — modular monolith, local-first, contract-driven, compliance by
construction, agent-friendly, escape hatches — is only real if the generator emits it by
default. Compliance by construction means the audit table, the PII classification, and
the retention policy exist in the scaffold before anyone writes a handler, because
anything a developer must remember to add is a control that will be missing in
production. The generator is where the opinions live; the libraries are just where they
are implemented.

The corollary is uncomfortable: the CLI and skill toolchain are not deferred to phase
three after the blocks are done. They are co-developed, because they are the only thing
that forces the blocks to have a coherent, composable shape. A block that the generator
cannot wire is a block with a bad interface.

## 2. `blocksctl` — the CLI

One binary, `go install`-able, no plugin system, no config file required for the happy
path. Every command is deterministic on **stdout**: same inputs, byte-identical stdout, so
`verify` in CI is meaningful. Run-dependent values — elapsed times, rebuild durations —
go to stderr and are explicitly non-contractual; the transcripts below show them as
`# stderr:` lines so it is clear they are not part of the compared output.

| Command             | Purpose                                                                                 | Output                                                                                                      |
| ------------------- | --------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| `new project`       | Scaffold a modular-monolith repo with one example module                                | Full repo tree, `go.mod`, Compose file, CI workflow, `AGENTS.md`, passing tests                             |
| `new module`        | Add a bounded context to an existing project                                            | `internal/modules/<name>/`, proto package, Ent schema dir, wire provider, tests                             |
| `new resource`      | Declare a resource: proto message, Ent schema, CRUD actions, policies                   | Proto + schema + service + policy + PII classification + table-driven tests                                 |
| `new action`        | Add a named non-CRUD action (Ash-style) to a resource                                   | Proto RPC, action handler, authorization hook, audit entry, state-machine edge                              |
| `generate`          | buf + entc + wire in one ordered pass, at the pinned tool versions                      | All generated code — `gen/`, `ent/`, `internal/bootstrap/wire_gen.go`; no partial states on failure         |
| `migrate`           | Create/apply/verify schema migrations (Atlas-backed, no auto-DDL in prod)               | Versioned SQL files, lint report, drift check against target DB                                             |
| `doctor`            | Check the toolchain against the versions pinned in `configs/tools.yaml`                 | Pass/fail table with exact install commands for each mismatch or omission                                   |
| `verify`            | Re-run `generate` at the pinned versions into a temp dir, diff against committed output | Exit 1 with a diff on drift across the full generated scope; the CI gate against hand-edited generated code |
| `dev`               | Hot-reload server plus seeded local stack                                               | Running binary, watched rebuilds, printed URLs for API/UI/Jaeger                                            |
| `seed`              | Apply deterministic fixture sets                                                        | Seeded DB; fixed UUIDs and timestamps so assertions are stable                                              |
| `compliance report` | Emit the control-to-block mapping for this project's actual code                        | Markdown + JSON: PII inventory, retention policies, unaudited actions                                       |
| `introspect`        | Machine-readable manifest of resources, actions, args, policies                         | JSON on stdout; the substrate for the MCP server and agent skills                                           |
| `upgrade`           | Migrate a project across block versions via codemods                                    | Applied AST rewrites, a report of manual TODOs, updated version pin                                         |

### `blocksctl new project`

```console
$ blocksctl new project fnb-erp --module github.com/dhiazfathra/fnb-erp \
    --blocks authn,authz,audit,tenancy,media,jobs \
    --data-layer postgres+sqlite
resolved block set (6 blocks, go-blocks v0.4.2)
scaffolding                                   ok    41 files
buf generate                                  ok    18 files
entc generate                                 ok    27 files
wire                                          ok     1 file
go build ./...                                ok
go test ./...                                 ok    14 tests, 0 skipped
# stderr: 14 tests in 1.9s; project ready in 38s

  blocksctl dev            start the local stack
  blocksctl new module     add a bounded context
```

```text
fnb-erp/
├── AGENTS.md
├── Makefile
├── api/                      # proto is the contract root
│   ├── buf.yaml
│   └── example/v1/example.proto
├── cmd/server/main.go
├── configs/{config.yaml,config.local.yaml,tools.yaml}   # tools.yaml pins buf/entc/wire/protoc plugin versions
├── deploy/compose.yaml
├── docs/adr/0001-record-architecture-decisions.md
├── gen/                      # generated: go, grpc, http, errors, validate, openapi, ts
├── internal/
│   ├── bootstrap/            # wire_gen.go, block registration
│   └── modules/example/
│       ├── ent/schema/example.go
│       ├── service.go
│       ├── policy.go
│       ├── service_test.go
│       └── usage-rules.md
├── migrations/
└── .github/workflows/ci.yaml
```

### `blocksctl new resource`

```console
$ blocksctl new resource MenuItem --module catalog \
    --field name:string:required --field price:money \
    --field allergens:[]string --field photo:media_ref \
    --actions crud,publish --soft-delete --tenant-scoped
api/catalog/v1/menu_item.proto                       created
internal/modules/catalog/ent/schema/menuitem.go      created
internal/modules/catalog/menu_item_service.go        created
internal/modules/catalog/menu_item_policy.go         created
internal/modules/catalog/menu_item_test.go           created
internal/modules/catalog/usage-rules.md              updated
generate                                             ok
go test ./internal/modules/catalog/...               ok  9 tests  0.4s

warning: no PII classification on field "name"; annotate or mark pii:none
         (CI gate `compliance-check` will fail until resolved)
```

Two things matter in that transcript. The generated tests are real assertions against
the tenant predicate and the soft-delete filter, not placeholders — a scaffold whose
tests pass vacuously teaches the team that green means nothing. And the PII warning is a
warning locally and a hard failure in CI, which is the only ordering that works: fast
locally, strict at the boundary.

### `blocksctl new action`

```console
$ blocksctl new action ConfirmOrder --module order --resource Order \
    --transition 'pending->confirmed' --requires order:confirm --audited \
    --arg confirmed_by:actor_ref --arg note:string:optional
api/order/v1/order.proto                    +1 rpc, +2 messages
internal/modules/order/action_confirm.go    created  (business logic: TODO)
internal/modules/order/statemachine.go      +1 edge  pending -> confirmed
internal/modules/order/action_confirm_test.go        created  4 tests
generate                                    ok
go test ./internal/modules/order/...        ok  22 tests  0.6s

generated tests cover: unauthorized actor, illegal source state, audit row
written, idempotent replay. business assertion left as TODO(you).
```

The framework generates everything that is mechanically derivable — transport,
validation, authorization check, state guard, audit write, and the four tests that
protect those — and leaves exactly one hole with a `TODO` the linter flags. That ratio,
one hand-written function per business action, is the number section 10 measures.

## 3. Templates and layering

Templates rot in three predictable ways: they multiply into variants, they drift from
the framework they scaffold, and the projects generated from them can never pull forward
an upgrade.

**One canonical layout, no variants.** There is a single project shape; feature
selection is additive block registration, not a different tree. Every "we need a
slightly different layout for X" request is answered by a block or a config key. The
moment there are two layouts, every generator change costs double and one of the two
silently rots.

**Embedded templates, not a template repo.** Templates live in the `blocksctl` binary
via `embed.FS`, which makes the template version and the block version the same version
by construction. A separate template repo introduces a compatibility matrix nobody
maintains, and offline scaffolding stops working. The cost is that a template change
requires a `blocksctl` release; that is an acceptable trade because releases are cheap
and version skew is not.

**Upgrades are codemods, not merges.** Three-way merging generated scaffolds against
edited project code is a known failure mode — it produces conflicts in files the
developer has legitimately rewritten. Instead, each block version ships an ordered set
of migrations under `upgrades/<from>-<to>/`, written as `go/ast` rewrites or `gofmt -r`
patterns, and `blocksctl upgrade` applies them transactionally with a report of what it
could not do automatically. A migration must be idempotent and must fail loudly rather
than guess. This is the same discipline as database migrations, applied to source.

**Preventing drift across many repos.** Three mechanisms. First, `blocksctl verify` in
every project's CI: generated code is committed for reviewability but any hand edit
fails the build. Second, a pinned `blocks.version` in `configs/` plus a scheduled CI job
that opens a PR when a newer version exists — drift becomes a visible open PR rather
than invisible decay. Third, `blocksctl doctor --strict` asserts the project's layout
still matches the canonical shape, so a repo that has quietly grown a `pkg/utils/` shows
up in a report. None of these prevent drift; they make it observable, which is the
achievable goal.

## 4. Local development stack

`blocksctl dev` is the only command a new engineer needs.

```console
$ blocksctl dev
sqlite mode (no docker) — use --stack full for postgres/redis/minio/otel
migrations   applied 7                                       ok
seed         tenant=acme users=3 menu_items=24 orders=12      ok
serving      grpc :9000  http :8000  admin :8080
watching     internal/ api/
# stderr: incremental rebuild ~1.1s
```

```console
$ blocksctl dev --stack full
docker  postgres:17  redis:7  minio  jaeger  (opensearch: --with-search)   4 up
...
jaeger   http://localhost:16686
minio    http://localhost:9001
```

Testcontainers is the right tool for integration tests that need a real Postgres, and
Compose is the right tool for a stack a human wants to poke at with a UI. Using
Testcontainers for the interactive dev stack means containers die with the test process;
using Compose for tests means shared mutable state across CI jobs. Use both, for the
thing each is good at.

OpenSearch and Jaeger are opt-in even in full mode. They are the two heaviest
containers, and neither is needed to write a handler. Defaults should be cheap; the
first developer whose laptop fans spin up at `blocksctl dev` tells everyone else the
framework is heavy.

**Seed data and fixtures.** Seeds are Go code, not SQL dumps, so they typecheck against
the schema and break at compile time when a field changes. Fixtures use fixed UUIDs
(derived deterministically from a name, e.g. UUIDv5 of `"tenant:acme"`) and a frozen
clock, so assertions can name entities directly and golden files stay stable.

**The golden rule: `go test ./...` must pass with Docker not installed.** The default
data layer for unit tests is SQLite in-memory; anything needing a real Postgres lives
behind a `//go:build integration` tag and a separate `make test-integration`. This is
not purity — it is the difference between a contributor running tests in the first
minute and a contributor giving up. It also forces the data layer to be genuinely
swappable, which is what makes the local-first constraint from the baseline achievable
rather than aspirational.

## 5. Agent skills and the AI-facing toolchain

The baseline lists AI-agent friendliness as a non-negotiable constraint. Concretely that
means four artifacts, and one honest accounting of risk.

**`AGENTS.md`, root and per module.** The root file carries what never changes: the
layout, the invariants (generated code is never hand-edited; proto is the contract; no
new dependencies without an ADR), the commands (`blocksctl generate`, `blocksctl verify`, `go test ./...`),
and the escalation rule — if a change requires editing anything under `gen/`, stop and
report. Per-module files carry the domain: the resources, the state machines, the
invariants that are business rules rather than framework rules. Keep both short. An
`AGENTS.md` that has grown to 800 lines is a file agents skim and humans ignore.

**`usage-rules.md` per block.** Directly stealing Ash's UsageRules pattern: every block
ships a terse file describing how to use it correctly, and `blocksctl` concatenates the
rules for the blocks a project actually depends on into the agent's context. This is
strictly better than expecting an agent to infer usage from godoc, because it can state
the negative rules — "never call `audit.Write` directly; audit rows are emitted by the
action runtime" — which no amount of reading the public API reveals.

**Claude Code skills shipped with the framework.**

| Skill                      | Does                                                            | Guardrails enforced                                                                          |
| -------------------------- | --------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| `/blocks-new-resource`     | Interviews for fields, then drives `blocksctl new resource`     | Refuses to write proto/Ent by hand; requires PII class per field; requires tenant decision   |
| `/blocks-add-action`       | Adds a named action with transition, permission, audit          | Refuses raw CRUD-shaped actions; requires a source→target state pair and a permission        |
| `/blocks-compliance-check` | Runs `compliance report`, explains each finding, proposes fixes | Never edits the report; will not mark a field `pii:none` without explicit human confirmation |
| `/blocks-review`           | Reviews a diff against framework invariants                     | Flags hand-edited generated code, bypassed policy layers, new deps, missing tests            |
| `/blocks-migrate`          | Runs `blocksctl upgrade`, then triages the manual-TODO report   | One version step at a time; stops on any non-idempotent migration                            |

The pattern in all five: the skill drives the deterministic generator instead of writing
the code itself. An agent that calls `blocksctl new resource` produces output identical
to a human's; an agent that hand-writes the same six files produces something plausible
and subtly inconsistent. Generators are the mechanism by which agent output becomes
reviewable.

**MCP server.** `blocksctl mcp` exposes the introspection and scaffolding surface as
tools: `list_resources`, `describe_action`, `run_generate`, `new_resource`,
`compliance_report`. Read tools are unrestricted. Write tools always leave changes in the
working tree for human review, never committed — but "in the working tree" is not by
itself a boundary, because a working-tree write can still be executed or exfiltrated
before anyone reviews it. The write boundary is therefore defined positively:

- **Canonical-path containment.** Every target path is resolved to its canonical form
  (symlinks followed, `..` collapsed) and rejected unless the result is still inside the
  project root. Resolving after joining, not before, is the point — otherwise a symlink
  planted inside the root escapes it.
- **No symlink traversal.** A write whose path passes through a symlink at any component
  is refused outright rather than followed.
- **Denied regardless of containment**: `.git/` in its entirety (hooks execute on the next
  local git command), CI and workflow definitions, anything matching the ignore rules for
  secrets (`.env*`, key material, credential files), and the tool's own configuration.
- **Allowlist for what write tools may touch at all**: generated output directories,
  `api/`, `internal/modules/`, and test files. Anything outside that set requires an
  explicit human-approved path, not a write-tool call.

Both the containment check and the deny list are enforced in the MCP server, not in the
agent prompt — a prompt-level rule is a suggestion to something that may be under an
injection attack.

### Risks, stated plainly

Agents generate plausible-but-wrong domain logic with total confidence, and the
framework's own consistency makes the wrong code look right — it has the correct shape,
the correct imports, the correct test scaffolding, and an inverted business rule.
Scaffolding is the safe part precisely because it is mechanical; the one hand-written
function per action is exactly where agents are least trustworthy, which is why the
generated tests must cover authorization, state legality, audit, and idempotency, and
the business assertion must be a `TODO` a human fills or explicitly reviews. Do not
let `/blocks-add-action` write business logic unattended.

The second risk is worse because it is a security boundary. `blocks/ai` exposing actions
as LLM tools means a runtime agent can call privileged actions, and any untrusted text
that agent reads — a customer's order note, a review, a support email — is a potential
instruction. Mitigations, all required together: the agent gets its own principal with
its own permission set, never the caller's; only actions explicitly annotated
`ai_exposed = true` are visible; every mutating action invoked via the agent surface is
rate-limited, audited with the prompt hash, and gated on a human approval for
anything financial or destructive. That approval is bound to the agent principal, the
action, the target, and a hash of the canonicalized arguments, and it is single-use and
expiring — a generic "a human clicked yes" is not a control, because the agent can change
the payload after approval or replay one approval against another destructive request. Treat the tool surface as a public API exposed to an
attacker who controls part of the input, because that is what it is.

## 6. Documentation as a deliverable

Docs drift for one reason: nothing fails when they lie. So make things fail.

**Examples are tests.** Every documented usage lives in an `Example*` function in a
`_test.go` file with an `// Output:` comment, compiled and run by `go test`. The docs
site includes those files by reference rather than by copy-paste. A stale example is a
red build.

**The reference is generated.** Resource, action, field, error-code, and PII-class
documentation comes from `blocksctl introspect` plus proto comments and Ent annotations,
rendered at release time. Nobody hand-maintains an API table. Hand-written prose is
reserved for guides, concepts, and ADRs — the things generation cannot produce.

**ADRs.** `docs/adr/` in the scaffold from file one, with the record-architecture-decisions
ADR pre-populated. Every block boundary, every dependency, and every deviation from the
canonical layout gets one. Superseded, never rewritten.

**Per-block README template**, with mandatory sections: what it does, what it does not
do, the compliance controls it implements, config keys, a compiled example, and its
`usage-rules.md`. **The rule: an undocumented block is unreleased.** Not "documentation
is tracked as follow-up work" — the release gate checks for the required sections and
the compiled example, and a block missing either is not published. This is enforceable
in CI, which is the only reason it will hold.

## 7. Clone plan A — GoWind CMS equivalent

The point of this clone is not to have a CMS. It is to prove the block set can produce
one, and to shake out the generator against a broad, shallow domain — many resources,
simple logic, heavy multi-tenancy and i18n. That makes it a better first target than the
Shop, whose logic is deeper.

**Modules and resources.**

| Module     | Resources                                                          | Notes                                                                          |
| ---------- | ------------------------------------------------------------------ | ------------------------------------------------------------------------------ |
| `identity` | Tenant, User, Role, Department, Permission                         | `blocks/authn` + `authz`; role/department trees                                |
| `content`  | Post, Page, Category, Tag, Comment                                 | Publish/unpublish via `blocks/statemachine`; recycle bin via `blocks/archival` |
| `site`     | Site, Navigation, Translation, SeoMeta, GlobalParam                | Multi-site scoping is a second predicate dimension beyond tenant               |
| `media`    | MediaItem, Folder                                                  | `blocks/media`, local or MinIO                                                 |
| `platform` | Dictionary, ScheduledTask, Notification, Message, ApiLog, AuditLog | Mostly `blocks/audit`, `jobs`, `dict` config                                   |

Roughly 22 resources. `blocksctl introspect` should report a comparable action count to
GoWind's 52 protos with a fraction of the hand-written surface, because the CRUD,
list/filter, batch, and ordering actions are all derived.

**Contract surface.** Core domains stay gRPC-only; the admin and app BFFs carry the
`google.api.http` annotations. This is the GoWind Shop discipline applied to the CMS,
and it is the right rule for both — see section 8.

**Admin UI.** Three options: adopt Vben Admin and hand-build screens, generate an admin
from `introspect`, or buy a commercial shell. Recommendation: **generate a functional
admin from introspection, and do not try to make it beautiful.** A generated admin that
covers list/filter/detail/edit/action-invocation for every resource is achievable because
the manifest already contains field types, PII classes, permissions, and available
actions. Its value is that it is free for every new resource forever. When a specific
screen needs real design, hand-write that one screen in the same Vben monorepo — the
escape hatch. Hand-building 22 resources' worth of admin screens is six weeks nobody
should spend on a proof.

**Consumer front-ends: build one.** Nuxt + shadcn-vue, and only that. Four variants exist
in GoWind as a sales surface, not an engineering need; each additional variant multiplies
the cost of every contract change while proving nothing new after the first one. The
generated TypeScript clients are the actual proof that the contract is consumable.

**Deliberately not cloned:**

- **Three of the four front-end variants.** Taro, Flutter, and Next.js add zero
  architectural information after the Nuxt client works, and each is a permanent
  maintenance obligation.
- **Mini-program support.** A platform-specific channel with its own auth, payment, and
  review constraints. Irrelevant to the F&B driver and a large sunk cost.
- **OpenSearch on day one.** Postgres full-text search covers a CMS at realistic content
  volumes. Adding OpenSearch is a `blocks/search` driver swap later; adding it now buys a
  container and an ops burden in exchange for nothing measurable.
- **MySQL as a second supported database.** Two dialects double the migration and
  privacy-policy test matrix. Postgres plus SQLite is already two.
- **etcd service discovery.** A modular monolith has nothing to discover.

**Effort: 9–13 engineer-weeks**, assuming the block set from the recommended staged
approach exists at roughly beta quality. Most of that is not the CMS.

| Phase | Weeks | Scope                                                     | Exit criterion                                              |
| ----- | ----- | --------------------------------------------------------- | ----------------------------------------------------------- |
| C0    | 1     | `blocksctl new project`, identity module, auth end to end | Login, tenant scoping enforced in the data layer            |
| C1    | 2     | Content module, publish state machine, recycle bin        | Post lifecycle audited; soft delete and restore work        |
| C2    | 2     | Site, i18n, navigation, SEO, global params                | Two sites, two locales, no cross-site leakage               |
| C3    | 1.5   | Media, dictionaries, scheduled tasks, notifications       | Upload to MinIO and local; jobs retried and observable      |
| C4    | 2     | Generated admin over introspection                        | Every resource fully operable without a hand-written screen |
| C5    | 1.5   | Nuxt consumer front-end on generated TS clients           | Public site renders from the app BFF only                   |
| C6    | 1–3   | Hardening, compliance report, docs, load test             | `compliance report` clean; docs gate passes                 |

## 8. Clone plan B — GoWind Shop equivalent

The Shop is the more valuable clone because its domains overlap the F&B mini-ERP
directly. Building it is not a detour from the business driver; it is how the F&B modules
get exercised by a second consumer before they calcify around one caller.

**Framework blocks versus application domains.** Of the 16 domains, most are not
e-commerce at all.

| Reusable go-blocks blocks                                                            | Application-specific (ship as the shop app) |
| ------------------------------------------------------------------------------------ | ------------------------------------------- |
| identity, permission, authentication, audit, dict, storage, messaging, task, address | catalog, order, payment, cart, shipping     |

The nine on the left were never shop-specific; GoWind bundles them because it has no
framework to put them in. That split is the load-bearing decision of this plan: it says
the shop clone is five domains of real work on top of blocks that CMS already paid for.

**The overlap with F&B is the point.** Catalog, order, payment, cart, and shipping are
the same five modules the mini-ERP needs, with different vocabulary — menu items are
catalog products with modifiers, a table order is a cart with a location, delivery is
shipping with a zone. Build them once, parameterized, and validate them against two
callers. Two consumers is the minimum for a module interface to be trustworthy; one
caller produces an interface shaped like that caller. Concretely: payment must abstract
gateway and settlement so both online checkout and in-store POS work; order must support
both a linear web flow and the F&B mutate-until-closed flow; catalog must handle variants
and modifier groups from the start, because retrofitting modifiers is a schema break.

**The BFF pattern, enforced.** Only BFF protos carry `google.api.http` annotations; the
five core domains are gRPC-only. This is checkable — a buf lint rule, or a `blocksctl
verify` check, that fails when an HTTP annotation appears in a core package. Encoding the
architectural boundary in the contract and enforcing it in CI is the single most
transferable practice in GoWind Shop, and it costs one lint rule. Per-BFF scoped OpenAPI
follows for free and stops the admin surface leaking into the consumer schema.

**Deliberately not cloned:** the full promotions and coupon engine (a combinatorial
domain that deserves its own project), multi-vendor marketplace mechanics, and the
double-entry ledger — accounting is delegated to Accurate Online per the baseline, and
`blocks/money` handles amounts, not books.

**Effort: 11–15 engineer-weeks** after the CMS clone, of which roughly nine are the five
shared domains that F&B needs anyway.

| Phase | Weeks | Scope                                                     | Exit criterion                                                                |
| ----- | ----- | --------------------------------------------------------- | ----------------------------------------------------------------------------- |
| S0    | 0.5   | Project from existing blocks; BFF boundary lint           | HTTP annotation in a core proto fails CI                                      |
| S1    | 2.5   | Catalog: products, variants, modifier groups, inventory   | Same schema serves shop SKUs and F&B menu items                               |
| S2    | 2     | Cart and pricing                                          | Cart survives a session; pricing is a pure, tested function                   |
| S3    | 2.5   | Order lifecycle as an audited state machine               | Every transition permission-checked and audited; illegal transitions rejected |
| S4    | 2     | Payment: gateway abstraction, idempotency, reconciliation | Duplicate webhooks provably safe; one real gateway integrated                 |
| S5    | 1.5   | Shipping and address, delivery zones via `blocks/geo`     | Zone-based fee calculation tested                                             |
| S6    | 1.5   | Admin and consumer BFFs, generated TS clients             | Scoped OpenAPI per BFF; no cross-surface schema leakage                       |
| S7    | 1–2.5 | Hardening, load test on order and payment paths           | p99 within budget; compliance report clean                                    |

## 9. Sequencing all three priorities

The ordering is CMS, then Shop, then F&B — but the phases interleave, because the shared
modules must be built with their second consumer already in view. Building catalog for
the shop alone and then "generalizing" it for F&B is the expensive path.

| Quarter | CMS         | Shop                       | F&B mini-ERP                                | Modules shared into the next column                                     |
| ------- | ----------- | -------------------------- | ------------------------------------------- | ----------------------------------------------------------------------- |
| Q1      | C0–C2       | —                          | —                                           | `blocks/{authn,authz,audit,tenancy,statemachine,archival}`, `blocksctl` |
| Q2      | C3–C6       | S0–S1 (catalog, F&B-aware) | domain modelling only                       | `blocks/{media,jobs,dict,search}`, generated admin, TS clients          |
| Q3      | maintenance | S2–S5                      | POS shell on catalog + order                | catalog, cart, order, payment, shipping, address, `blocks/geo`          |
| Q4      | —           | S6–S7                      | inventory, purchasing, Accurate integration | payment (settlement), reporting, local-first sync                       |

Explicitly shared, and the reason each clone makes the next cheaper:

- **Framework-wide:** `authn`, `authz`, `audit`, `tenancy`, `archival`, `statemachine`,
  `jobs`, `media`, `dict`, `observability`, `crypto`, `consent`, `retention` — built for
  CMS, consumed unchanged by Shop and F&B.
- **Tooling:** `blocksctl`, the generated admin, the TS client pipeline, the skills, the
  MCP server — amortized across all three and the largest single leverage point.
- **Commerce core:** catalog, cart, order, payment, shipping, address — built during Shop
  with F&B as a declared second consumer, not retrofitted.
- **Local-first sync:** built for F&B POS, and the reason the SQLite data layer must be a
  first-class test target from Q1 rather than an afterthought in Q4.

The risk in this plan is that the CMS is a proof of concept that turns into a product
someone wants shipped. Fix the CMS scope in writing at C6 and refuse additions; its job
is to harden the blocks and then stop changing.

## 10. Measuring bootstrap efficiency

If these are not measured, the bootstrap surface regresses quietly — a generator that
took 40 seconds takes four minutes eighteen months later and nobody notices the day it
happened.

| Metric                                          | Target             | Fail threshold | How measured                                              |
| ----------------------------------------------- | ------------------ | -------------- | --------------------------------------------------------- |
| `blocksctl new project` to first passing test   | < 60 s             | > 3 min        | Timed CI job on a clean cache, every release              |
| Hand-written lines per CRUD resource            | 0                  | > 20           | `blocksctl new resource` output, diff excluding generated |
| Hand-written lines per audited state transition | ~15 (one function) | > 60           | Same, for `new action`                                    |
| Time to add an audited state transition         | < 15 min           | > 1 h          | Recorded on real tasks, not a demo                        |
| CI wall-clock, unit tests                       | < 3 min            | > 6 min        | CI, p50 over the last 20 runs                             |
| CI wall-clock, full including integration       | < 12 min           | > 20 min       | Same                                                      |
| New engineer to first merged PR                 | < 2 days           | > 5 days       | Tracked per hire, honestly                                |
| `go test ./...` without Docker                  | passes             | any failure    | A CI job with no Docker daemon available                  |

The zero-hand-written-lines-per-CRUD-resource target is the one that matters most,
because it is the one that decides whether developers spend their time on business logic
— goal six of the baseline. Every line a developer writes to get plain CRUD working is a
line the framework failed to derive.

Two of these are load-bearing gates rather than dashboards: the timed `new project` job
and the no-Docker test job. Both fail the build. The rest are reported per release and
reviewed, because a target nobody looks at is a target nobody meets.
