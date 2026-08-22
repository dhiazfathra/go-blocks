# Approach 4 — Ent schema as the single DSL

## Thesis in three sentences

go-blocks does not need a new DSL, because Ent already is one: schema-as-Go-code with a
mature extension API (`entc`), field and edge annotations, hooks, interceptors, privacy
policies, mixins, and existing generators that emit protobuf (`entproto`) and GraphQL
(`entgql`). The framework's job is therefore to ship a set of opinionated mixins and
annotation types plus a single `entc` extension that reads them and emits everything
else — Kratos service skeletons, authorization policies, audit hooks, admin metadata,
DSAR export and erase methods, retention jobs, and an agent-readable manifest. The
price is that the source of truth becomes an ORM schema rather than a domain resource,
which is both the cheapest path to a working framework and the approach's deepest
conceptual flaw.

## The DSL

A menu item in the F&B mini-ERP. Everything compliance- and platform-relevant is
declared, not implemented.

```go
package schema

import (
	"entgo.io/ent"
	"entgo.io/ent/schema"
	"entgo.io/ent/schema/field"
	"entgo.io/ent/schema/index"

	"github.com/dhiazfathra/go-blocks/blocks"
)

type MenuItem struct{ ent.Schema }

func (MenuItem) Mixin() []ent.Mixin {
	return []ent.Mixin{
		blocks.Tenant(),     // tenant_id + privacy predicate + index
		blocks.Audited(),    // created/updated/by + audit hooks
		blocks.SoftDelete(), // deleted_at + interceptor + recycle bin
	}
}

func (MenuItem) Fields() []ent.Field {
	return []ent.Field{
		field.String("name").MaxLen(120),
		field.Int64("price_cents").Positive(),
		field.String("currency").Default("IDR").Immutable(),
		field.Enum("state").
			Values("draft", "active", "out_of_stock", "retired").
			Default("draft").
			Annotations(blocks.StateMachine{
				Initial: "draft",
				Transitions: []blocks.Transition{
					{Action: "activate", From: []string{"draft", "out_of_stock"}, To: "active"},
					{Action: "mark_out_of_stock", From: []string{"active"}, To: "out_of_stock"},
					{Action: "retire", From: []string{"draft", "active"}, To: "retired"},
				},
			}),
		field.String("supplier_contact").
			Optional().
			Annotations(blocks.PII("contact", blocks.LegalBasisContract, "P5Y")),
	}
}

func (MenuItem) Annotations() []schema.Annotation {
	return []schema.Annotation{
		blocks.Resource{
			Domain:      "catalog",
			ProtoPackage: "blocks.catalog.v1",
			Admin:       blocks.Admin{ListColumns: []string{"name", "price_cents", "state"}},
		},
		blocks.Actions{
			{Name: "create", Kind: blocks.Create, Permission: "catalog.menu_item:create"},
			{Name: "update", Kind: blocks.Update, FieldMask: true,
				Permission: "catalog.menu_item:update"},
			{Name: "activate", Kind: blocks.Transition, Transition: "activate",
				Permission: "catalog.menu_item:publish", Emits: "MenuItemActivated"},
			{Name: "list", Kind: blocks.List, Paginated: true, Filters: []string{"state", "name"}},
		},
	}
}

func (MenuItem) Indexes() []ent.Index {
	return []ent.Index{index.Fields("tenant_id", "name").Unique()}
}
```

The custom annotation types are ordinary structs implementing Ent's `schema.Annotation`
interface. Ent serialises them into `gen.Type.Annotations` as JSON, which the extension
reads back during codegen.

```go
package blocks

type PIIAnnotation struct {
	Category   string `json:"category"`   // identity | contact | financial | health
	LegalBasis string `json:"legalBasis"` // consent | contract | legitimate_interest
	Retention  string `json:"retention"`  // ISO-8601 duration
	Erasure    string `json:"erasure"`    // null | tombstone | crypto_shred
}

func (PIIAnnotation) Name() string { return "BlocksPII" }

func PII(category, legalBasis, retention string) PIIAnnotation {
	return PIIAnnotation{category, legalBasis, retention, "null"}
}
```

Mixins are where behaviour attaches. `blocks.Tenant()` is a mixin that contributes a
field, an index, a privacy policy, and a hook in one unit:

```go
type tenantMixin struct{ mixin.Schema }

func Tenant() ent.Mixin { return tenantMixin{} }

func (tenantMixin) Fields() []ent.Field {
	return []ent.Field{
		field.String("tenant_id").Immutable().NotEmpty().
			Annotations(entproto.Field(900)),
	}
}

func (tenantMixin) Indexes() []ent.Index { return []ent.Index{index.Fields("tenant_id")} }

func (tenantMixin) Policy() ent.Policy {
	return privacy.Policy{
		Query: privacy.QueryPolicy{rule.FilterTenantRule()},
		Mutation: privacy.MutationPolicy{
			privacy.AlwaysAllowRule(), // after the tenant filter rule stamps tenant_id
		},
	}
}

func (tenantMixin) Hooks() []ent.Hook {
	return []ent.Hook{hooks.StampTenant()}
}
```

`blocks.Audited()` contributes `created_at`, `updated_at`, `created_by`, `updated_by`
and a mutation hook that writes a diff row into the audit table. `blocks.SoftDelete()`
is Ent's documented soft-delete mixin — an interceptor adding `deleted_at IS NULL` to
every query, plus a `SoftDelete` mutation path — wired to the recycle-bin block.

## The extension architecture

`entc` extensions are Go programs, not protoc plugins. An extension implements
`entc.Extension`, supplying templates, template funcs, hooks over the generated graph,
and annotations. The whole generator is one `go generate` entrypoint:

```go
//go:build ignore

package main

import (
	"log"

	"entgo.io/ent/entc"
	"entgo.io/ent/entc/gen"
	"entgo.io/contrib/entproto"
	"entgo.io/contrib/entgql"

	blocksgen "github.com/dhiazfathra/go-blocks/gen"
)

func main() {
	ex, err := blocksgen.NewExtension(
		blocksgen.WithProtoDir("api/protos"),
		blocksgen.WithKratosDir("internal/service"),
		blocksgen.WithManifest("gen/manifest.json"),
	)
	if err != nil {
		log.Fatal(err)
	}
	gqlEx, _ := entgql.NewExtension(entgql.WithSchemaPath("api/graphql/schema.graphql"))

	err = entc.Generate("./ent/schema",
		&gen.Config{Package: "github.com/acme/pos/ent", Features: gen.AllFeatures},
		entc.Extensions(ex, gqlEx),
		entc.TemplateDir("./templates"),
	)
	if err != nil {
		log.Fatal(err)
	}
	if err := entproto.Generate("./ent"); err != nil { // proto emission
		log.Fatal(err)
	}
}
```

The extension's hook walks `gen.Graph.Nodes`, decodes each node's annotations into the
`blocks.Resource` / `Actions` / `StateMachine` structs, validates them (every action
references a declared transition; every PII field has a legal basis and retention), and
then runs template passes:

| Pass      | Output                                                                     | Mechanism                                                    |
| --------- | -------------------------------------------------------------------------- | ------------------------------------------------------------ |
| Proto     | `api/protos/<domain>/v1/*.proto` messages + service                        | `entproto` plus a template for action RPCs it cannot express |
| Service   | Kratos service struct, one method per action, wired to Ent                 | custom template into `internal/service`                      |
| Policy    | Casbin/OPA policy rows and Ent privacy rules per action permission         | template + seeder                                            |
| Audit     | Per-type audit hook registration and diff field lists                      | template into `ent/runtime`                                  |
| Admin     | `admin.json` resource/column/filter/form metadata for the Vben UI          | manifest writer                                              |
| DSAR      | `ExportSubject(ctx, subjectID)` / `EraseSubject(...)` per PII-bearing type | template using PII annotations                               |
| Retention | Asynq/River job definitions with per-field retention windows               | template + cron registry                                     |
| Manifest  | `gen/manifest.json` — resources, actions, args, permissions, transitions   | manifest writer                                              |

State machine annotations generate a transition guard function per action, so an illegal
`retire → active` fails in generated code rather than in a hand-written `switch`.

Escape hatch: every generated file is either `_gen.go` (regenerated, never edited) or a
one-time scaffold the team owns thereafter. Ent's own `Client` remains fully available,
so dropping to raw SQL or a hand-written service is always one function away.

## Contract-driven reconciliation

The constraint says protobuf is the source of truth. This approach makes Ent the source
of truth. That contradiction has to be resolved deliberately, not papered over.

**Ent → proto (`entproto`).** Annotate fields with `entproto.Field(n)` and types with
`entproto.Message()`, and `entproto.Generate` emits messages and a CRUD service. The
appeal is one declaration. The hazards are real:

- Field numbers must be hand-assigned and never reused. A developer renaming a field or
  deleting one in the Ent schema can silently orphan or recycle a number. Reserved-range
  discipline has to be enforced by the extension (emit `reserved` statements for removed
  numbers, persist a number ledger per message).
- The generated proto is a projection of a storage model. Public API shape ends up
  dictated by column layout: join tables surface as edges, internal columns leak unless
  explicitly excluded, and `oneof`/`google.protobuf.Any`/nested value objects are
  awkward to express.
- `entproto` supports only a CRUD service shape. Named actions (`activate`,
  `mark_out_of_stock`) need custom templates — meaning the interesting half of the API
  is generated by go-blocks code, not by `entproto`.
- Breaking-change detection still works: run `buf breaking` against the generated protos
  in CI. But the break is _discovered_ after the schema change, so the feedback loop puts
  API compatibility downstream of a database refactor. That is exactly backwards from
  what contract-driven development is supposed to buy.

**Proto → Ent (converter).** Keep proto authoritative, generate Ent schema Go files from
proto options. This preserves API ownership and buf's breaking checks at the right
boundary, but it throws away the approach's whole advantage: schemas stop being editable
Go, annotations move back into proto options, and go-blocks is now writing the very
compiler that Approach 2 describes — with an extra Ent-shaped code emitter bolted on.

**Recommendation: Ent → proto, with an explicit public-API boundary.** Treat the
generated protos as _internal_ core contracts (gRPC-only, versioned, `buf breaking` gated
in CI, field-number ledger committed to the repo). Hand-write the BFF protos that
external clients consume, exactly as GoWind Shop does — only BFF services carry
`google.api.http` annotations. This keeps one declaration for the 80% of internal
surface, and preserves human ownership of the shape customers depend on. It accepts a
softened reading of constraint 3: proto is the contract of record at the process
boundary, Ent is the contract of record inside the module.

## Local-first

Ent's driver abstraction covers `sqlite3` (via `modernc.org/sqlite` for cgo-free builds)
and PostgreSQL from the same schema, so the identical `ent/schema` package compiles into
the on-device POS binary and the server. Atlas produces the migration set for both;
SQLite's weaker DDL means some migrations must be `ATOMIC`-rewritten, which Atlas handles
but which does constrain schema evolution (no arbitrary column drops on old SQLite).

Sync design:

- **Outbox on device.** Every mutation writes a domain event into a local `outbox` table
  in the same transaction — generated automatically by the audit/event hook, so business
  code does not opt in. A background pusher drains it when connectivity returns.
- **Event log for money, LWW for reference data.** Sales, payments, and stock movements
  are append-only events: replaying them server-side is commutative for totals and needs
  no conflict resolution beyond idempotency keys. Menu items, prices, and staff records
  are server-authoritative and pulled down; a device edit to them is rare enough that
  per-field last-write-wins with a Hybrid Logical Clock column is adequate.
- **Conflict cases that matter.** Two terminals selling the last unit of stock — resolve
  by accepting both sales and letting stock go negative with an exception raised, because
  refusing an offline sale is the worse business outcome. Price changed centrally while a
  terminal was offline — the sale keeps the price captured at sale time; the event carries
  the price, so it is not a conflict at all.

The per-field HLC column and outbox table both come from mixins (`blocks.Syncable()`),
which is the strongest argument for this approach: local-first support is a mixin, not a
framework rewrite.

## AI-agent friendliness

For coding agents this is the best-positioned approach in the set. The declaration is
ordinary Go: `gopls` gives completion, go-to-definition, and type errors on annotations;
`go build` rejects a malformed schema before any generator runs; a wrong field type is a
compile error rather than a codegen surprise. Agents already handle Go far better than
they handle proto custom options, and every mistake surfaces through a toolchain they can
run themselves.

For runtime agents, the extension emits `gen/manifest.json`: resources, actions, argument
types, permissions, state transitions, and PII classes. That file is the tool catalogue —
an MCP or function-calling server reads it and exposes each action as a tool, with the
generated permission string driving authorization so an agent cannot exceed the caller's
rights.

The weakness is genuine: Go schema code is not machine-parseable without compiling it.
Static analysis of an annotation's value requires `go/packages` and constant evaluation,
and any value computed at runtime (`os.Getenv`, a helper function) is invisible to a
parser. Proto is declarative data; Ent schemas are programs that happen to describe data.
The mitigation is that the manifest is generated, so anything downstream reads the
manifest, never the schema — but that makes the compiler a mandatory step in every
introspection path.

## Compliance posture

| Requirement                                          | Mechanism                                                                                                                                                     |
| ---------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Access control (ISO 27001 A.5.15, A.8.3)             | Ent privacy policies — query and mutation rules enforced in the data layer, so a forgotten handler check cannot leak rows                                     |
| Tenant isolation                                     | `blocks.Tenant()` privacy predicate injected into every query                                                                                                 |
| Audit logging (A.8.15)                               | `blocks.Audited()` mutation hooks writing actor, action, before/after diff — the spine, because hooks cannot be bypassed by application code using the client |
| Data inventory / ROPA (GDPR Art. 30)                 | `blocks.PII` annotations aggregated by the extension into a generated inventory report per deployment                                                         |
| Lawful basis (GDPR Art. 6; PDP UU 27/2022 Art. 20)   | `legalBasis` on every PII field, validated at codegen — a PII field without one fails the build                                                               |
| Right of access / erasure (Art. 15/17; PDP Art. 8–9) | generated `ExportSubject` / `EraseSubject` per type, driven by annotations                                                                                    |
| Retention (Art. 5(1)(e); PDP Art. 30)                | retention duration per field, compiled into scheduled purge jobs                                                                                              |
| Encryption (Art. 32)                                 | field-level crypto via an Ent value scanner on `crypto_shred` fields                                                                                          |
| Breach notification (PDP Art. 46, 3×24h)             | audit spine plus event log gives the timeline evidence; process, not code                                                                                     |

Codegen-time validation is the substantive win: a non-compliant schema does not compile,
so the control is preventive rather than a periodic audit finding.

## Effort and timeline

Estimates in engineer-weeks for one senior Go engineer, assuming Ent and Kratos
familiarity.

| Work item                                                                     | Weeks   |
| ----------------------------------------------------------------------------- | ------- |
| Annotation types, mixin library (tenant, audited, soft delete, PII, syncable) | 3       |
| `entc` extension skeleton, graph walk, annotation decoding, validation        | 2       |
| Proto emission: `entproto` wiring, field-number ledger, action RPC templates  | 4       |
| Kratos service templates + Wire wiring                                        | 3       |
| Policy, audit, DSAR, retention generators                                     | 4       |
| Manifest + agent tool server                                                  | 2       |
| SQLite/local-first: outbox, HLC, sync worker                                  | 5       |
| Admin metadata + Vben-style generated UI (first pass)                         | 4       |
| Docs, `usage-rules.md` per block, example F&B module                          | 3       |
| **Total to a usable framework**                                               | **~30** |

This is the cheapest of the five routes by a wide margin. Ent already owns the parser,
the graph model, the template engine, the migration tooling, the multi-driver layer, and
two working downstream generators. go-blocks writes annotations, mixins, and templates —
not a compiler.

## Tradeoffs

| Strengths                                                                     | Weaknesses                                                                                                                                     |
| ----------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| Codegen machinery already exists and is production-proven                     | Deep coupling to Ent's roadmap; an upstream breaking change in `entc/gen` internals breaks every template                                      |
| Declaration is type-checked Go — best coding-agent ergonomics of any approach | Schema is not machine-parseable without compiling it                                                                                           |
| Privacy policies give real row-level enforcement, not advisory checks         | `entproto` is the least-maintained corner of Ent; CRUD-only, sparse docs, cautious release cadence                                             |
| Same schema on SQLite and Postgres — local-first is a mixin                   | Ent's own learning curve is steep (codegen loop, edge semantics, `entc` internals)                                                             |
| Hooks and interceptors make audit and soft delete unbypassable                | Annotation ergonomics are poor: untyped JSON round-trip, errors appear at generate time, no IDE validation of annotation _semantics_           |
| Atlas migrations are a solved, versioned story                                | **An ORM schema is not a domain resource.** Persistence shape drives API and domain shape — the opposite of the Ash model this project admires |
| Fastest path to a demonstrable framework                                      | Non-persistent resources (a payment-gateway call, a report, an integration with Accurate) have no natural home                                 |
| entgql gives GraphQL nearly free if needed                                    | Actions spanning aggregates (close a shift: settle orders, reconcile cash, post to Accurate) do not belong to any one Ent type                 |

The conceptual objection deserves restating plainly: Ash's power comes from resources
being _domain_ declarations that happen to have a data layer. Here the declaration _is_
the data layer. Every domain concept without a table — a saga, a policy decision, a
projection, an external integration — falls outside the DSL and must be hand-written,
which erodes the "one declaration" claim precisely where business complexity lives.

## Risks and mitigations

| Risk                                            | Likelihood | Impact | Mitigation                                                                                                                                       |
| ----------------------------------------------- | ---------- | ------ | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| `entc/gen` internal API change breaks templates | Medium     | High   | Pin Ent minor version; keep template surface narrow; contract tests that generate and compile the example module in CI                           |
| `entproto` stagnates or is deprecated           | Medium     | High   | Own a fork-ready vendored copy; keep the proto emitter behind a go-blocks interface so it can be replaced by a direct `gen.Graph` → proto writer |
| Field-number drift breaks wire compatibility    | Medium     | High   | Commit a per-message number ledger; extension fails the build on reuse; `buf breaking` gate in CI                                                |
| Storage model leaks into public API             | High       | Medium | Hand-written BFF protos as the public boundary; internal protos never exposed                                                                    |
| Cross-aggregate actions outgrow the DSL         | High       | Medium | Explicit `blocks/workflow` (saga) block outside Ent from day one; do not attempt to model it as annotations                                      |
| Kratos v3 plugin ecosystem lag                  | Medium     | Medium | Generate Kratos wiring from own templates rather than depending on Kratos-specific protoc plugins                                                |
| Team cannot hire for Ent + entc expertise       | Medium     | Medium | Keep the extension small and documented; ensure business code needs Ent basics only                                                              |
| SQLite migration limits block schema evolution  | Low        | Medium | Atlas-managed migrations, tested against the oldest supported SQLite build in CI                                                                 |

## Verdict

This is the pragmatic answer and, on cost alone, the strongest candidate for getting a
real framework in front of a real F&B deployment inside two quarters: roughly thirty
engineer-weeks buys schema-as-code, generated protos, generated Kratos services, enforced
row-level security, an unbypassable audit spine, annotation-driven compliance artefacts,
and local-first SQLite from one declaration — because Ent already carries the generation
machinery that Approaches 2 and 3 would have to build. What it does not buy is a domain
model. Making an ORM schema the single DSL means the persistence shape drives the API and
the domain, non-persistent resources and cross-aggregate actions have nowhere to live, and
the project's most valuable inheritance from Ash — resources and named actions as
first-class domain declarations — is compromised at the foundation. Adopt it as the
generation _engine_ and the data-layer contract, not as the whole DSL: pair it with a
hand-owned public proto boundary and a workflow block for everything that does not fit a
table, which is what the staged hybrid in `05-approach-hybrid-staged.md` sets out to do.
