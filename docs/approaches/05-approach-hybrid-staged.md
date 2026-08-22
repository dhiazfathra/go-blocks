# Approach 5 — Staged Hybrid (Recommended)

## 1. Thesis in Three Sentences

go-blocks should not choose between a blueprint, a compiler, a runtime engine, and an
Ent-first DSL — it should build them in that order, because each one is the evidence
base for the next. Every stage ships a working product increment and is independently
useful if the next stage never happens, which means the project cannot fail in a way
that leaves nothing behind. The recommendation is therefore: hand-build the first
vertical slice, extract libraries from what repeats, generate only what has proven
identical at three or more call sites, and expose runtime introspection only for the
surfaces that genuinely need it.

## 2. Why Staging Beats Picking One

The four sibling approaches are not really alternatives; they are points on a single
abstraction gradient. `01-approach-kratos-blueprint.md` writes everything by hand and
reuses libraries. `04-approach-ent-schema-first.md` and
`02-approach-proto-compiler.md` move the same knowledge into a declaration compiled to
Go. `03-approach-runtime-resource-engine.md` moves it further, into data interpreted at
runtime. Nothing about the destination is disputed — the dispute is only about _when_
you are allowed to move right along that gradient.

The rule of three answers that. An abstraction built from one example encodes that
example's accidents; from two, it encodes the difference between two accidents; from
three, it starts to encode the shape. go-blocks has zero examples today. Every
generator, annotation, and engine designed now would be designed against an imagined
F&B mini-ERP rather than the real one, and the imagined version is always more regular
than the real one. Stage 0 exists solely to produce those three examples.

Premature abstraction is not merely wasted work — it is _anti-work_. A generator emits
code that then has to be understood by everybody, extended for every case it did not
anticipate, and escape-hatched around when the case is genuinely different. A wrong
library can be ignored; a wrong generator sits astride the build and taxes every
change. The cost is asymmetric, which is why the burden of proof sits on the side of
generating, not the side of hand-writing.

Each stage also de-risks the next in a specific, checkable way:

- Stage 0 produces the concrete code shapes that Stage 1's block interfaces must fit.
  Without it, block APIs are guesses.
- Stage 1 produces usage counts. Stage 2's generators target only what Stage 1 shows is
  copied verbatim, so the generator's output is a mechanical transcription of code that
  already exists and is already tested.
- Stage 2 produces annotations and a build-time model. Stage 3's runtime registry is
  then a second emitter over the same model, not a new source of truth — which is the
  difference between "introspection" and "a second framework".
- Stage 3 produces a stable tool surface, which is what Stage 4's agent tooling, admin
  UI, and `blocksctl` scaffolding consume.

Compare the failure modes. Committing to Approach 2 or 3 on day one means eight months
before the first business feature ships, against a specification nobody has validated.
Committing permanently to Approach 1 means the consistency goal is enforced by code
review forever. Staging gets the Approach 1 value in month four and keeps the option on
the rest.

## 3. Stage-by-Stage Plan

### Stage 0 — Prove It on the Real Problem (weeks 1–4)

**Goal.** Build one F&B mini-ERP vertical slice by hand, on Kratos v3 + Ent + Wire +
buf inside a modular monolith, and earn the right to abstract.

**Deliverables.** Three resources of genuinely different shape — a master-data resource
(Product), a transactional resource (StockMovement), and a workflow resource
(PurchaseOrder with approval states). Each with proto contract, gRPC + HTTP handlers,
Ent schema and migration, tenancy predicate, audit records, Casbin/OPA policy check,
and tests. One deployable binary, in-process module transport, Docker Compose
environment.

**Exit criteria.** All three slices pass integration tests against Postgres; a written
diff analysis identifying, line by line, what was copy-pasted between the three;
`buf breaking` and `golangci-lint` green in CI; p99 read latency under 50 ms locally.

**Team.** Two engineers, one of them the eventual block owner.

**Out of scope.** Any generator, any annotation beyond stock `google.api.http` and
validate, any runtime registry, any admin UI, any second module. Explicitly: do not
factor out shared helpers yet. The duplication is the deliverable.

### Stage 1 — Blueprint and Blocks (months 2–4)

**Goal.** Extract the repetition into versioned block libraries plus a template repo —
Approach 1, informed by Stage 0's diff analysis.

**Deliverables.** `blocks/tenancy`, `blocks/audit`, `blocks/authz`, `blocks/crypto`,
`blocks/jobs`, `blocks/observability`, `blocks/archival`, `blocks/pii`; a template
repository that boots a compliant modular monolith; per-block `usage-rules.md` and
`AGENTS.md`; the GoWind-CMS-equivalent content module (posts, categories, taxonomy,
media, i18n, publish workflow) built entirely on the blocks; a hand-written
`CONTRIBUTING` describing the layering rules.

**Exit criteria.** A new CRUD resource with tenancy, audit, and policy takes under 30
minutes and under 120 hand-written lines of Go excluding proto. The content module
contains zero copies of block internals. Block test coverage at or above 90 %.
Onboarding check: an engineer new to the repo ships a resource unaided in one day.

**Team.** Three engineers plus a fractional reviewer.

**Out of scope.** Codegen beyond what buf already provides. No custom protoc plugins.
No admin UI. No local-first sync yet, though the data-layer interfaces must not assume
Postgres.

### Stage 2 — The Compiler, Seeded by Ent's Machinery (months 4–8)

**Goal.** Generate the plumbing that Stage 1 proved is identical every time — Approach
2 for the transport and service layer, Approach 4's `entc` extensions and `entproto`
for the persistence side.

**Deliverables.** Proto annotations (`resource`, `action`, `tenant_scoped`,
`pii_class`, `audited`, `retention`) and `protoc-gen-blocks` emitting handler
scaffolds, list/filter/sort plumbing, FieldMask update paths, error-code helpers, PII
redactors, and TS clients; `entc` extensions emitting tenancy predicates, audit hooks,
and soft-delete from schema annotations; a generated-code drift check in CI; a
migration of the Stage 1 content module onto the generated layer, as the proof.

**Exit criteria.** The same CRUD resource now takes under 10 minutes and under 40
hand-written lines. Generated code is byte-identical to what Stage 1 wrote by hand for
at least three migrated resources. Every generated file is deletable and replaceable by
hand without touching the module's business code. Drift check green.

**Team.** Two engineers on tooling, two continuing product work on Stage 1 blocks.

**Out of scope.** Generating business logic, validation semantics, or workflow
transitions. **Hard rule: never generate what has fewer than three call sites.** A
pattern with two instances gets a helper function, not a generator.

### Stage 3 — Thin Runtime Introspection (months 8–12)

**Goal.** Add the _narrow_ slice of Approach 3 that pays: a runtime manifest derived
from the Stage 2 annotations.

**Deliverables.** A generated registry describing resources, actions, arguments,
policies, and PII classifications; a set of **generated per-resource data adapters**
registered alongside that metadata, each exposing a fixed, narrow contract — subject
matching, single-record read, relationship traversal, and paged list with filters — so
that DSAR export and the generic list endpoints have a data path instead of only a
description; four consumers of the pair — auto-generated admin UI, MCP-style agent tool
surface, DSAR/erasure/retention reporting, and generic list/filter/sort endpoints; a
`/debug/resources` introspection endpoint.

**Exit criteria.** Admin UI covers 80 % of back-office CRUD with no per-resource
frontend code. A DSAR export for one subject across all modules runs from the registry
and its generated adapters alone, with no per-module DSAR code. Agent tool surface
exposes every annotated action with no hand-written descriptors. Zero business-logic
dispatch goes through the registry or its adapters — the adapters expose reads only,
never actions, and an architecture test asserts that no adapter method invokes a module
use case.

**Team.** Two engineers, one frontend.

**Out of scope.** A general interpreter. No dynamic action definition at runtime, no
resources defined in YAML or the database, no rules engine. Business logic stays static
compiled Go; the registry is metadata plus read-only data adapters, never a substitute
for the business layer — no adapter may write, and no adapter may dispatch an action.

### Stage 4 — Ecosystem (ongoing, month 12+)

**Goal.** Make the thing adoptable beyond the founding team.

**Deliverables.** `blocksctl` scaffolding, Claude/agent skills per block, the shop
module, the local-first SQLite POS with sync, Accurate Online accounting integration,
public documentation, versioning policy enforcement.

**Exit criteria.** Two teams outside the founding one ship production modules; POS
survives a 24-hour network partition with reconciliation; Accurate integration passes
month-end close against real ledger data.

**Team.** Rolling, two to four.

**Out of scope.** Open-sourcing before two internal teams have succeeded.

## 4. The Seam That Makes Staging Safe

One decision makes the whole plan reversible: **business code depends only on
hand-written block interfaces, never on generated types and never on the runtime
registry.** Generation is a producer of implementations and metadata; it is never in the
dependency path of business logic.

```go
// blocks/tenancy/tenancy.go — hand-written, stable across all stages.
type Tenant struct {
	ID   string
	Slug string
}

type Resolver interface {
	FromContext(ctx context.Context) (Tenant, error)
}

// blocks/audit/audit.go — payloads are classified and redacted before they are a
// value of this type; `any` here would be an open invitation to log raw PII.
type Payload struct {
	Fields map[string]Value // redacted per pii.Class at construction time
}

type Value struct {
	Class     pii.Class
	Redacted  string // rendered form, already masked or hashed for PII classes
	Truncated bool
}

type Event struct {
	Actor     Actor  // required
	TenantID  string // required
	Action    string // required
	Resource  string // required
	Entity    string // required for entity-scoped actions
	Outcome   Outcome // required: allowed, denied, or failed
	Reason    string  // required when Outcome is not allowed
	Channel   string  // required: api, admin, job, migration
	RequestID string  // required; correlates to the transport request
	At        time.Time
	Before    *Payload
	After     *Payload
}

// Record fails closed: it returns an error, and writes nothing, if any required
// field is empty or if a Payload contains a field with no pii.Class assigned.
// Callers build Payloads through audit.Redact(classifier, resource, m), which is
// the only exported constructor.
type Recorder interface {
	Record(ctx context.Context, e Event) error
}

// blocks/authz/authz.go — the request is structured, because the adopted policies
// evaluate attributes (input.outlet_id, resource.outlet_id), not just names.
type Attrs map[string]any

type Request struct {
	Actor    Actor  // subject identity, roles, and tenant membership
	Action   string // e.g. "menu_item.update"
	Resource string // resource type, e.g. "menu_item"
	Entity   string // resource instance ID, empty for collection actions
	Input    Attrs  // attributes of the request payload
	Attrs    Attrs  // attributes of the stored resource, when loaded
	Tenant   tenancy.Tenant
}

type Decision struct {
	Allowed bool
	Reason  string
}

type Enforcer interface {
	Check(ctx context.Context, r Request) (Decision, error)
}

// blocks/pii/pii.go
type Class int

const (
	ClassNone Class = iota
	ClassPersonal
	ClassSensitive
)

type Classifier interface {
	ClassOf(resource, field string) Class
}
```

A Stage 1 handler calls `Enforcer.Check` and `Recorder.Record` directly. A Stage 2
generated handler must reach the same methods — but not necessarily by writing the same
call. Approach 2's generated slice calls generated policy functions, Ent clients,
`audit.Emit`, and `privacy.RedactMenuItem` directly, so the guarantee is not free: it
holds only if every such generated symbol is a **thin adapter over a block interface**,
never a parallel implementation of it. Concretely, `protoc-gen-blocks` and the `entc`
extensions must emit adapters whose bodies delegate to `authz.Enforcer`,
`audit.Recorder`, `tenancy.Resolver`, and `pii.Classifier`, and an architecture test in
CI must assert that no generated package performs authorization, audit, tenancy, or
redaction work except through those four interfaces — the same import-graph check that
forbids blocks importing generated code, run in the other direction. Without that
adapter rule and that test, Stage 2 forks the contract instead of implementing it, and
the seam is a claim rather than a guarantee. A Stage 3 registry entry is _derived from_
the annotations that also drove the generator, and the admin UI consumes `Classifier`
and `Enforcer` through the same interfaces. Delete the generator and the hand-written path still compiles. Delete the
registry and business logic is untouched. That is what "independently useful even if the
next stage is never built" means concretely.

Versioning and deprecation policy for blocks:

- Blocks are separate Go modules under one repo, semver-tagged independently.
- Interfaces are additive-only within a major version. New capability arrives as a new
  interface, or an optional interface discovered by type assertion — never as a new
  method on an existing one.
- Deprecation runs two minor versions with `// Deprecated:` plus a `staticcheck`-visible
  marker, then removal in the next major. Minimum six weeks between deprecation and
  removal.
- Generated code may depend on blocks; blocks may never depend on generated code. CI
  enforces this with an import-graph check.
- A block major bump requires an ADR and a migration script or codemod.

## 5. Kill Criteria

| Stage | Signal to stop                                                                                | Action                                                              |
| ----- | --------------------------------------------------------------------------------------------- | ------------------------------------------------------------------- |
| 0     | Fewer than two of the three slices show substantially identical plumbing in the diff analysis | Stay at Approach 1 permanently; ship product, no framework          |
| 0     | Kratos v3 blocks a slice for more than 5 working days                                         | Pin Kratos v2, revisit v3 in 2 quarters                             |
| 1     | New resource still exceeds 45 minutes or 200 lines after 8 weeks of block work                | Block boundaries are wrong; re-cut them before any codegen          |
| 1     | Block churn above 1 breaking change per block per month at week 12                            | Freeze interfaces, defer Stage 2 by a quarter                       |
| 2     | Any generator's output needs hand-editing in more than 20 % of resources                      | Delete that generator, revert to a block helper                     |
| 2     | Generator maintenance exceeds 20 % of one engineer's time for two consecutive months          | Freeze the generator set; no new annotations                        |
| 2     | `buf breaking` violations from annotation changes exceed 3 per quarter                        | Annotation model is unstable; stop and redesign                     |
| 3     | Registry consumers begin requesting business-logic dispatch                                   | Refuse; the request is Approach 3 proper, which is out of scope     |
| 3     | Admin UI needs per-resource overrides for more than 40 % of resources                         | Registry is too thin to pay for itself; keep DSAR only, drop the UI |
| 4     | Fewer than two external teams adopt within 6 months of Stage 3 exit                           | Stop framework investment; maintain blocks only                     |

## 6. Adopted and Rejected, per Sibling Approach

| Source                                   | Adopted                                                                                                                                                        | Rejected                                                                                                                                                                                     |
| ---------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `01-approach-kratos-blueprint.md`        | Hand-written block libraries as the permanent, stable dependency surface; template repo; per-block usage rules                                                 | Relying on code review alone for consistency at scale; accepting permanent copy-paste of plumbing                                                                                            |
| `02-approach-proto-compiler.md`          | Proto as the contract source of truth; annotations for tenancy, audit, PII, retention; generators for transport, list/filter, FieldMask, redactors, TS clients | Generating the whole vertical slice including business logic and workflow semantics; generating anything with fewer than three call sites; a compiler designed before real usage data exists |
| `03-approach-runtime-resource-engine.md` | Runtime manifest for admin UI, agent tools, DSAR, and generic list endpoints; introspectable action metadata                                                   | A generic engine interpreting actions at runtime; runtime-defined resources; dynamic business rules; the debuggability and performance cost of interpretation on the hot path                |
| `04-approach-ent-schema-first.md`        | `entc` extensions for tenancy predicates, audit hooks, soft delete; Ent privacy policies for row-level security; `entproto` where proto and schema align       | Ent schema as the single system-wide DSL; letting persistence shape the API contract; coupling the transport layer's evolution to ORM releases                                               |

## 7. Governance for a Real Team

Staging demands more discipline than a single big design, because the discipline is
recurring rather than one-off. Mechanisms, in order of enforcement strength:

**CI gates, all blocking.** `buf lint` and `buf breaking` against the main branch;
`golangci-lint run` with a shared config; coverage floors (blocks 90 %, modules 75 %);
a generated-code drift check that regenerates everything and fails on a non-empty
`git diff`; an import-graph check enforcing that blocks never import generated code and
that modules never import each other's internals; a `govulncheck` and secrets scan.

**Block ownership.** Each block has exactly one named owner and one backup, recorded in
`CODEOWNERS`. The owner approves every change to that block's public interface and owns
its `usage-rules.md`. No block ships without a second reviewer. Unowned blocks are
deleted at the next quarterly review — an unowned framework component is a liability.

**RFC and ADR process.** An RFC (one page, problem/options/recommendation) is required
for: any new block, any new annotation, any generator, any block major bump. ADRs are
written after the decision, dated, and superseded rather than edited. The Head of
Engineering is the sole approver for stage transitions and for any exception to the
three-call-site rule; those exceptions are logged and reviewed quarterly.

**Release and versioning across teams.** Blocks release independently on semver;
consuming modules pin exact versions and upgrade on their own cadence. A monthly
"blocks train" bundles minor upgrades with a migration note. Breaking changes require a
codemod and a two-week notice on the internal channel. The template repo is versioned
too, and `blocksctl upgrade` diffs a project against its template baseline.

## 8. Compliance and Audit Sequencing

Three controls cannot be retrofitted and must land in Stage 1, because retrofitting
them means backfilling data that was never captured or re-partitioning data that was
never isolated:

- **Audit trail** (ISO 27001 A.8.15). Every mutation writes an immutable event from day
  one. Gaps in an audit log cannot be reconstructed later; an audit log that starts in
  month nine is a log that fails its first audit.
- **Tenancy isolation.** Enforced in the data layer via Ent privacy policies, not in
  handlers. Retrofitting a tenant column across a live schema means a migration plus a
  full re-verification of every query path — an order of magnitude more work than doing
  it first.
- **PII classification.** Every field carries a class at declaration time. Classifying
  fields retroactively across dozens of resources is guesswork, and it is the input to
  DSAR, retention, encryption, and log redaction — all of which are blocked without it.

Deferrable, because they consume the Stage 1 primitives rather than produce them:
consent management and retention _execution_ (Stage 2, once annotations exist); DSAR
tooling, erasure workflows, and access-review reporting (Stage 3, from the registry);
formal ISO 27001 certification, DPIA templates, and breach-notification runbooks (Stage
4). Field-level encryption sits between: the `blocks/crypto` interface must exist in
Stage 1 so call sites are in place, but only sensitive-class fields need it wired then.

## 9. Effort, Timeline, and Cost

| Stage | Calendar      | Headcount | Engineer-weeks | Cumulative capability                                                        |
| ----- | ------------- | --------- | -------------- | ---------------------------------------------------------------------------- |
| 0     | Weeks 1–4     | 2         | 8              | One real vertical slice; evidence for abstraction                            |
| 1     | Months 2–4    | 3 + 0.5   | 42             | Block libraries, template repo, CMS-equivalent module, compliance foundation |
| 2     | Months 4–8    | 4         | 64             | Generated plumbing, Ent extensions, 10-minute resources                      |
| 3     | Months 8–12   | 2 + 1     | 48             | Admin UI, agent tool surface, DSAR reporting                                 |
| 4     | Month 12+     | 2–4       | 32 per quarter | POS, shop, Accurate integration, external adoption                           |
|       | **12 months** |           | **162**        | Stages 0–3 only; Stage 4 is ongoing and excluded                             |

All figures are engineer-weeks from an empty repository, not increments on an existing
blueprint. The **162** total covers Stages 0–3 (8 + 42 + 64 + 48); Stage 4 is excluded
because it is ongoing rather than a one-time build, and adds 32 engineer-weeks per
quarter for as long as it runs.

Stage 0 plus Stage 1 is **50 engineer-weeks delivered by the end of month four** — just
under a third of the 162-week Stages 0–3 figure — and that 50 produces a shippable,
compliant product on a maintainable foundation. Stages 2 and 3 are optional purchases,
112 engineer-weeks between them, made with evidence in hand.

## 10. Tradeoffs

| Strengths                                                                 | Weaknesses                                                                                                                           |
| ------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| Value ships every quarter; no eight-month pre-product framework build     | Staged plans slip, and staging makes slippage easy to hide behind "Stage 1 is fine"                                                  |
| Every abstraction is built from three real examples, not from imagination | Requires sustained discipline from a busy team; the three-call-site rule is only as strong as its enforcer                           |
| Each stage is independently useful; the project cannot fail into nothing  | Migration cost at each boundary is real: Stage 2 rewrites Stage 1's handlers, Stage 3 adds a second consumer of the annotation model |
| The block-interface seam makes generation and runtime layers deletable    | Two mechanisms (hand-written and generated) coexist during transitions, so contributors must know both                               |
| Kill criteria are numeric, so stopping is a decision rather than a drift  | Numeric gates invite gaming; a 30-minute resource can be measured on a favourable resource                                           |
| Compliance foundations land in Stage 1, when they are cheapest            | Stage 1 compliance work delays visible product features by roughly three weeks                                                       |
| Optionality: the expensive stages are bought with evidence                | A framework authored primarily by its Head of Engineering is a bus factor of one                                                     |

Two of these deserve a direct answer rather than a table cell.

**Stage 2 and 3 may never happen.** Once Stage 1 is good enough, the marginal appeal of
building a compiler drops sharply, and organisational attention moves to product. Say
plainly: that outcome is acceptable, and arguably the good one. Stage 1 delivered
compliant blocks, a template, and a shipped module — the whole stated goal minus the
convenience layer. A plan whose most likely stopping point is still a success is a
better plan than one whose value is all at the end. The failure to guard against is the
opposite: reaching Stage 2 by momentum rather than by the exit criteria being met.

**Bus factor.** A solo-authored framework becomes a liability the moment its author is
promoted, distracted, or gone. Mitigations are structural, not motivational: one named
owner _and_ backup per block from Stage 1; the RFC/ADR trail as a decision record
somebody else can read; blocks kept small enough to be independently understood; and a
hard rule that the Head of Engineering owns at most two blocks personally. If, by end of
Stage 2, more than half the block interfaces have a single contributor in `git log`,
that is itself a kill signal for further framework investment.

## 11. Verdict

Build the staged hybrid, and commit only to Stage 0 and Stage 1 now. Four weeks of
deliberate hand-written duplication followed by three months of extraction produces a
compliant, shipped F&B slice and a block library whose interfaces are the permanent
public surface of go-blocks; Stages 2 and 3 are then optional purchases justified by
measured usage counts rather than by architectural taste. A different approach wins only
under specific conditions: if the org must support many near-identical tenant
deployments where per-tenant configuration genuinely varies at runtime, go straight to
Approach 3's engine and accept the debuggability cost; if the team is a single engineer
with no adoption mandate, stop permanently at Approach 1, because block libraries plus
code review are cheaper than any generator one person can maintain; if the domain is
overwhelmingly CRUD over a stable schema with thin business logic, Approach 4's Ent-first
DSL reaches the same place faster. The F&B mini-ERP is none of those — it has real
workflow semantics, a local-first constraint, and a multi-team adoption goal — which is
exactly the profile that rewards staging.
