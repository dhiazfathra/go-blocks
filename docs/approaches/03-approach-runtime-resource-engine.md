# Approach 3 — "Ash in Go": a runtime declarative resource engine

## Thesis in three sentences

Declare each domain concept once, in Go, as data: attributes with compliance metadata,
relationships, named actions, policies, aggregates, calculations, state machines, and
retention rules. A single generic engine interprets those declarations at runtime to
produce persistence, validation, authorization, audit, filtering, pagination, pub/sub,
and every API surface, so a new resource is a declaration file and nothing else. This is
the highest-ceiling and highest-risk approach in this set: it buys Ash-grade uniformity
and introspection, and pays for it with an interpreter that the team must own, debug, and
staff forever, in a language whose type system was designed specifically to resist this
kind of DSL.

## The declaration API

The declaration is a value, not a code generator input. Generics carry field types so
changes and validations are checked at compile time; the registry that holds
heterogeneous resources is where type erasure becomes unavoidable.

```go
package menu

// MenuItem is the persisted struct. Plain Go, no tags carrying behaviour.
type MenuItem struct {
	ID          xid.ID
	TenantID    xid.ID
	OutletID    xid.ID
	Name        string
	Price       money.Amount
	Status      string // draft | pending_approval | active | retired
	CreatedBy   xid.ID
	SubmittedAt *time.Time
}

var Resource = res.New[MenuItem]("menu_item").
	Attributes(
		res.Attr[MenuItem, string]("name", func(m *MenuItem) *string { return &m.Name }).
			Required().MaxLen(120).Searchable(),
		res.Attr[MenuItem, money.Amount]("price", func(m *MenuItem) *money.Amount { return &m.Price }).
			Required().Currency("IDR").Sortable(),
		res.Attr[MenuItem, string]("status", func(m *MenuItem) *string { return &m.Status }).
			Default("draft").Filterable().ReadOnly(),
	).
	// Compliance metadata is first-class, not a comment.
	Classify(
		res.PII("created_by", res.Pseudonymous, res.LegalBasis.Contract, res.Retain(5*res.Years)),
	).
	Relationships(
		res.BelongsTo[MenuItem, outlet.Outlet]("outlet", "OutletID"),
		res.HasMany[MenuItem, modifier.Group]("modifier_groups", "MenuItemID"),
	).
	Aggregates(
		res.Count[MenuItem]("orders_30d", "order_lines").
			Where(res.Gt("created_at", res.Rel("now-30d"))),
		res.Sum[MenuItem, money.Amount]("revenue_30d", "order_lines", "line_total"),
	).
	Calculations(
		res.Calc[MenuItem, money.Amount]("price_incl_ppn",
			res.Expr("price * (1 + tenant.tax_rate)")),
	).
	StateMachine(
		res.States("draft", "pending_approval", "active", "retired"),
		res.Transition("submit_for_approval", "draft", "pending_approval"),
		res.Transition("approve", "pending_approval", "active"),
		res.Transition("retire", "active", "retired"),
	).
	Actions(
		res.Create[MenuItem]("create").
			Accept("name", "price", "outlet").
			Change(res.SetActor[MenuItem]("CreatedBy")).
			Validate(res.PriceAbove[MenuItem]("price", money.IDR(1000))),

		res.Read[MenuItem]("list").
			Filterable("status", "outlet").Sortable("price", "name").
			Paginate(res.Keyset(50, 200)),

		res.Update[MenuItem]("update").Accept("name", "price").
			Change(res.Touch[MenuItem]("UpdatedAt")),

		// Custom action: arguments are not attributes.
		res.Action[MenuItem]("submit_for_approval").
			Argument(res.Arg[string]("note").Optional().MaxLen(500)).
			Argument(res.Arg[xid.ID]("approver_id").Required()).
			Change(res.Transitions[MenuItem]("submit_for_approval")).
			Change(res.Set[MenuItem, *time.Time]("SubmittedAt", res.Now)).
			Validate(res.ActorHasRole[MenuItem]("menu.author")).
			Notify(res.Event("menu_item.submitted", res.Include("id", "outlet"))).
			Policy(
				res.Authorize(
					res.And(
						res.SameTenant(),
						res.Or(
							res.ActorAttr("role", res.Eq, "outlet_manager"),
							res.ActorOwns("CreatedBy"),
						),
					),
				),
			),
	).
	Audit(res.AuditAll(res.RedactFields("price"))).
	Retention(res.SoftDelete(res.Days(30)), res.HardDelete(res.Years(7)))
```

What is genuinely type-safe here: attribute accessors (`func(*T) *F` pins the field type,
so `Default`, comparison helpers, and change functions are checked), changes and
validations (`func(context.Context, *Changeset[T]) error`), argument extraction
(`res.ArgOf[string]` on the changeset returns a typed value or a declaration error at
registration), and relationship targets (`res.BelongsTo[MenuItem, outlet.Outlet]`
verifies both ends exist as types).

What cannot be type-safe in Go today, and must be admitted:

- **The registry.** `map[string]ResourceDef` holds resources of different `T`. Go has no
  existentials, so the registry stores an interface with erased methods
  (`Run(ctx, action string, input map[string]any) (any, error)`). Every generic edge
  eventually funnels through it.
- **Expressions.** `res.Expr("price * (1 + tenant.tax_rate)")` is a string parsed at
  registration into an AST. There is no macro system to make it compile-checked. The
  mitigation is a startup-time type-check of every expression against the resource's
  attribute types, failing fast rather than at request time.
- **Filter/sort input.** It arrives as JSON from the wire, so it is `map[string]any`
  before it is validated against declared filterable fields.
- **Builder ordering mistakes.** Nothing prevents `Validate` before `Accept`; only a
  registration-time linter catches it.

## The engine

The engine is a small interpreter with a fixed pipeline and no dynamic dispatch beyond a
resolved plan.

```
Resolve → Authorize (pre) → Cast arguments → Validate → Apply changes →
Authorize (post, on the changeset) → Transact → Audit → Notify
```

Stage detail:

1. **Resolve.** Action name plus resource name looks up a `*CompiledAction` — built once
   at boot from the declaration: ordered validation funcs, change funcs, a compiled
   policy tree, a field allow-list, and a prepared SQL/Ent plan template.
2. **Authorize (pre).** Policy expressions compile into two forms: a **filter form**
   pushed into the query as SQL predicates (so a read of 10k rows is one query, not 10k
   policy evaluations), and a **check form** evaluated in Go for expressions that cannot
   be expressed in SQL. Ash's split between filter and runtime checks is the model.
3. **Cast and validate.** Arguments are cast by declared type; attribute updates are
   restricted to `Accept`ed fields, which is also the FieldMask semantics.
4. **Changes.** Composable middleware, `func(context.Context, *Changeset[T]) error`,
   run in declaration order. `Changeset[T]` is generic; only the pipeline's outer edge is
   not.
5. **Transact.** One transaction per action by default. Notifications are buffered and
   flushed after commit; audit rows are written inside the transaction so no committed
   change can lack an audit record.
6. **Audit and notify.** Audit derives its diff from the changeset, redacting fields
   marked in `Classify`.

**Query translation.** The declared read action plus incoming filter/sort/page input
compiles to a normalized query IR (predicate tree, projection, joins for relationships,
subqueries for aggregates, keyset cursor), then a backend emits Ent predicates for
Postgres and, for the local-first SQLite path, the same IR with a reduced feature set.
The IR is the single place dialect divergence is handled, which matters because the
local-first constraint means two backends forever.

**Tenant injection** happens at the IR level, not in handlers: every table declared
tenant-scoped gets a `tenant_id = $actor.tenant` predicate appended after user filters
are parsed, and the engine refuses to emit a query for a tenant-scoped resource when the
context carries no tenant. Ent privacy policies stay in place as a second, independent
enforcement layer — belt and braces, since the engine is new code.

**Introspection** is the reason to build this at all. `engine.Introspect()` walks the
registry and returns resources, attributes with types and classifications, actions with
arguments, policies in a human-readable reduced form, and relationships. It is the same
data the engine executes, so it cannot drift.

**Generics reduce, not eliminate, reflection.** Accessor closures replace
`reflect.Value.FieldByName` on the hot path — a real win, and the main reason this is
more viable in Go 1.22+ than it was in 2020. Reflection still remains for: scanning DB
rows into `T` (delegated to Ent, which is codegen, so cheap), marshalling `T` to JSON /
protobuf, generic `map[string]any` → typed argument casting, and the introspection walk
(boot-time only). Budget for reflection at the boundaries and closures in the middle.

## Derived surfaces

One declaration yields:

- **gRPC + HTTP (Kratos).** A generic handler per resource: `Run(resource, action,
payload)`, plus per-action typed RPCs where a proto message exists.
- **OpenAPI.** Generated from introspection, per BFF, mirroring the Shop pattern of
  scoped specs.
- **GraphQL.** Resources map to types, read actions to queries with filter/sort/page
  arguments, other actions to mutations.
- **Admin UI.** A generic Vben-style front end that fetches introspection and renders
  list/detail/form views, including which actions the current actor may invoke.
- **TypeScript client.** Emitted from introspection or from proto, depending on the
  reconciliation choice below.

**The protobuf tension.** Constraint 3 says protobuf is the source of truth; this
approach says the Go declaration is. Both cannot be true. Three options:

1. Generate proto **from** declarations.
2. Validate declarations **against** hand-written proto.
3. Runtime-only dynamic surface, no proto per action.

**Pick option 1: proto is generated from declarations and committed to the repo.** The
declaration is richer than proto — it carries policies, retention, legal basis, state
machines — so proto cannot be its superset, and a hand-written proto would have to be
kept in sync by discipline, which is exactly the defect class the project is trying to
delete. Generating and committing keeps proto a real wire contract: `buf breaking` still
gates every change in CI, the generated TS/Dart clients and external consumers are
unaffected, and the mechanical `.pb.go` review remains possible. The cost is a
declaration-to-proto emitter that must produce stable field numbers; the standard fix is
a checked-in field-number lock file per message, with CI failing on reuse or reordering.
Option 3 is rejected outright — a dynamic-only surface breaks every external consumer
contract and makes breaking-change detection impossible.

## AI-agent friendliness

This is where the approach wins decisively. A runtime agent needs three things: the list
of what it may do, typed argument schemas, and one uniform way to invoke them.
Introspection provides all three from the same data the engine executes.

```json
{
  "resource": "menu_item",
  "description": "Sellable item on an outlet menu",
  "actions": [
    {
      "name": "submit_for_approval",
      "type": "update",
      "description": "Send a draft menu item to an outlet manager for approval",
      "arguments": [
        { "name": "id", "type": "id", "required": true },
        { "name": "note", "type": "string", "required": false, "max_len": 500 },
        { "name": "approver_id", "type": "id", "required": true }
      ],
      "state_transition": { "from": ["draft"], "to": "pending_approval" },
      "permitted_for_actor": true,
      "policy_summary": "same tenant AND (role = outlet_manager OR actor owns record)",
      "side_effects": ["audit:menu_item.update", "event:menu_item.submitted"],
      "idempotent": false
    }
  ],
  "attributes": [
    { "name": "price", "type": "money", "currency": "IDR", "sortable": true },
    {
      "name": "created_by",
      "type": "id",
      "pii": "pseudonymous",
      "redacted": true
    }
  ]
}
```

The MCP surface is deliberately tiny — four tools, not one per action:

| Tool                | Purpose                                                     |
| ------------------- | ----------------------------------------------------------- |
| `list_resources`    | Resource names and descriptions the actor may see           |
| `describe_resource` | The JSON above, filtered to the actor's permissions         |
| `run_action`        | `{resource, action, input}` — the only mutation entry point |
| `explain_denial`    | Why the last authorization failed, in policy terms          |

`permitted_for_actor` must be computed per actor, not static: an agent should not see
actions it cannot invoke, because a listed-but-forbidden action invites the model to
retry, escalate, or hallucinate a workaround.

Risks, plainly:

- **Prompt injection.** Any free-text field an agent reads — a customer order note, a
  supplier email — can carry instructions. Mitigation is architectural, not prompt-level:
  the agent's principal is a real actor with real policies, so injection cannot exceed
  that actor's permissions. Beyond that, mark actions `res.RequiresConfirmation()` for
  anything irreversible or financial, and require a human-approved token for those.
- **Uniform endpoint = uniform blast radius.** One `run_action` tool means one bug in
  policy compilation is exploitable across every resource. This deserves fuzzing and a
  policy-decision golden-test corpus.
- **Introspection leakage.** Descriptions and policy summaries are themselves
  information. Filter them by actor, and never include raw expression internals.
- **Rate and cost.** Agents loop. Per-actor action budgets belong in the engine, not the
  agent.

## Compliance posture

Centralized enforcement is the strongest compliance argument for this approach: there is
exactly one code path through which data is read and written, so a control implemented
once is a control implemented everywhere.

| Obligation                          | Engine mechanism                                       | Evidence artefact                                |
| ----------------------------------- | ------------------------------------------------------ | ------------------------------------------------ |
| ISO 27001 A.8.15 logging            | Audit stage inside the action transaction              | Query showing every mutation has an audit row    |
| ISO 27001 A.5.15 access control     | Compiled policy per action                             | Introspection dump of policy per resource/action |
| GDPR Art. 30 records of processing  | `Classify` legal basis per attribute                   | Generated processing register                    |
| GDPR Art. 15/20 access, portability | Generic DSAR export walking relationships              | Export bundle per subject                        |
| GDPR Art. 17 erasure                | Retention declarations + erasure planner               | Erasure job log with per-resource counts         |
| GDPR Art. 32 / PDP Art. 39 security | Field encryption driven by `Classify`                  | Column-level encryption inventory                |
| PDP UU 27/2022 consent              | Consent predicate injected for consent-gated resources | Consent check trace in audit                     |

The practical value is that the processing register, retention schedule, and access
matrix stop being spreadsheets maintained by hand and become generated reports derived
from the code that actually runs — the single hardest part of an audit is proving the
document matches reality, and here they are the same artefact.

**Residual risk, stated bluntly.** One enforcement path is also one failure path. A bug
in policy filter compilation is a cross-tenant data breach across the entire product, not
one endpoint. Mitigations: keep Ent privacy policies as an independent second layer, keep
a cross-tenant leakage test that runs against every registered resource automatically,
and treat the policy compiler as security-critical code with mandatory review and fuzz
coverage.

## Performance

Honest accounting against hand-written Ent:

- **Reflection.** Mostly moved off the hot path by accessor closures; what remains is
  argument casting and serialization. Expect low-single-digit microseconds per action for
  interpretation overhead — irrelevant next to a database round trip, and measurable
  under load.
- **Allocation pressure.** This is the real cost, not CPU. A changeset, a predicate tree,
  a `map[string]any` input, and boxed values per field allocate per request. At high RPS
  this shows up as GC pressure. Mitigations: pool changesets, compile actions once at
  boot rather than per call, and prefer typed slices to maps in the internal IR.
- **Query plan quality.** Generated queries are systematically slightly worse: broader
  projections, joins the hand-written version would have avoided, `OR`-heavy predicates
  from policy trees that defeat index selection. Mitigation is an escape hatch —
  `res.Read("list").CustomQuery(fn)` — used for the handful of endpoints that matter, and
  `EXPLAIN` assertions in tests for those.
- **N+1 with aggregates and calculations.** The default failure mode. An `orders_30d`
  count on a list of 50 items must become one lateral/window query, not 50. The engine
  must batch by construction and a test must fail if query count per request exceeds a
  declared budget.
- **Keyset pagination only** for large lists; offset pagination must be opt-in and
  capped, or it becomes the production incident.

Benchmarks that must exist from week one and run in CI with regression thresholds:
single-action create latency, list-with-two-aggregates query count and latency, policy
compilation time at boot, allocations per action, and interpreted-vs-hand-written Ent for
one identical endpoint. Without that last one, nobody can answer "what did the engine
cost us", and the approach loses its own argument.

## Effort and timeline

Blunt: this is a framework project, not a feature. Rough engineer-weeks for a competent
Go team, assuming one senior engineer owns the engine:

| Component                                             | Weeks |
| ----------------------------------------------------- | ----- |
| Declaration API + registry + registration-time linter | 4     |
| Action pipeline, changesets, transactions             | 5     |
| Query IR + Ent backend + tenant injection             | 7     |
| Policy compiler (filter + check forms)                | 6     |
| Audit, retention, DSAR, field encryption              | 5     |
| Aggregates, calculations, expression engine           | 5     |
| Proto emitter + field-number lock + buf CI            | 4     |
| HTTP/gRPC generic handlers + OpenAPI                  | 3     |
| Introspection + MCP surface                           | 3     |
| Admin UI (generic, introspection-driven)              | 6     |
| SQLite/local-first backend                            | 6     |
| Docs, usage rules, benchmarks, hardening              | 5     |

That is roughly 59 engineer-weeks before the F&B mini-ERP gets its first feature — three
to four quarters at one to two engineers. Anyone quoting less has not written the policy
compiler.

**Minimum credible v1:** declaration API, action pipeline, Postgres-only query IR with
tenant injection, policy compiler with filter form only (runtime checks deferred), audit,
introspection plus the four MCP tools, generic HTTP handlers, and proto emission for one
domain. No GraphQL, no admin UI, no local-first, no aggregates, no expression language —
those become escape-hatch Go code until the core is proven on one real domain end to end.
That v1 is about 22 weeks, and it is still a hard sell against Approach 1 shipping
features in that window.

## Tradeoffs

| Strengths                                                                 | Weaknesses                                                                                                                                   |
| ------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| One declaration yields persistence, API, policy, audit, and docs          | Go has no macros and no compile-time metaprogramming; the DSL fights the language                                                            |
| Runtime introspection is a first-class agent surface nothing else matches | Stack traces run through the interpreter, not the business logic; a failing action shows engine frames                                       |
| Compliance controls enforced in exactly one audited path                  | That path is also a single point of catastrophic failure                                                                                     |
| New resource cost approaches zero after the engine exists                 | Engine cost is enormous and paid up front, before any business value                                                                         |
| Uniform behaviour across every endpoint by construction                   | Debuggability suffers: no single file to read to know what an endpoint does                                                                  |
| Escape hatches keep hand-written code possible per action                 | Escape hatches used often mean the abstraction is not paying for itself                                                                      |
| Policy expressions push into SQL, so authorization scales                 | Failures are opaque: "validation failed" without the declaration line that caused it                                                         |
| Introspection cannot drift from behaviour                                 | Onboarding cost is high; a new hire learns go-blocks, not Go                                                                                 |
| Attractive as portfolio and org-standard work                             | Serious risk of a framework only its author can maintain — a bus factor of one on the critical path                                          |
| Ash proves the model works                                                | Ash works because Elixir macros make it work; the proof does not transfer                                                                    |
| —                                                                         | Directly contradicts stated goal 3, "dead consistent and predictable": consistent yes, predictable no — magic is the opposite of predictable |

## Risks and mitigations

| Risk                                                        | Severity | Mitigation                                                                                                           |
| ----------------------------------------------------------- | -------- | -------------------------------------------------------------------------------------------------------------------- |
| Engine never reaches usable state; sunk cost                | High     | Hard timebox the v1 scope above; kill criterion at week 12 if one domain is not running end to end                   |
| Bus factor of one on the engine                             | High     | Two owners minimum, ADRs for every engine decision, an engine-internals guide as a gate on merging                   |
| Policy compiler bug causes cross-tenant leak                | Critical | Ent privacy as independent second layer; automatic leakage test per registered resource; fuzz the predicate compiler |
| Debuggability rejected by the team                          | High     | Every error carries the declaration source location; a `trace` mode dumping each pipeline stage's input and output   |
| Proto drift or unstable field numbers                       | Medium   | Committed generated proto, field-number lock file, `buf breaking` in CI                                              |
| Expression language becomes an unbounded project            | Medium   | Freeze a minimal grammar; anything harder is a Go calculation function                                               |
| Performance unacceptable at POS scale                       | Medium   | Benchmarks in CI from week one; `CustomQuery` escape hatch; query-count budgets per endpoint                         |
| Kratos v3 churn breaks generic transports                   | Medium   | Confine Kratos contact to one transport adapter package                                                              |
| Hiring and onboarding cost                                  | Medium   | Keep the declaration API small and documented; usage rules per block for both humans and agents                      |
| Framework diverges from what the F&B product actually needs | Medium   | Build the engine only against real mini-ERP requirements; no speculative features                                    |

## Verdict

This is the most intellectually satisfying approach and the one most likely to fail. The
declaration-plus-engine model genuinely delivers what the project wants — compliance by
construction, uniform behaviour, and an introspection surface that makes runtime agents
trivially safe and useful — and no other approach here matches it on those axes. But Ash
is possible because Elixir has macros, and Go deliberately does not; what Elixir does at
compile time, Go must do at runtime through an interpreter that erodes stack traces,
predictability, and the ability of any single engineer to read one file and know what an
endpoint does. Sixty engineer-weeks of framework before the first business feature, on a
critical path with a bus factor of one, against a stated goal of being dead predictable,
is not a trade a Head of Engineering should make as the primary bet. The right use of
this document is not to build Approach 3 now, but to steal its best parts — the
introspection contract, the compliance metadata on attributes, the single audited action
pipeline — and graft them onto a cheaper foundation, which is exactly what Approach 5
proposes.
