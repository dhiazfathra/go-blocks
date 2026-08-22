# go-blocks — Architecture Approaches: Summary and Comparative Analysis

Five candidate ways to build go-blocks: an opinionated Go ecosystem for
compliance-ready enterprise backends, built on go-kratos v3, inspired by Elixir's Ash
Framework, and forced into reality by a concrete first product — an F&B mini-ERP whose
accounting ledger is delegated to [Accurate Online](https://accurate.id/).

Read [`00-context-and-research.md`](00-context-and-research.md) first for the shared
research baseline (GoWind CMS, GoWind Shop, Ash's package surface, Kratos v3, and the
six non-negotiable constraints). Each approach below has its own deep dive with code,
effort estimates, risks, and an explicit verdict.

## TL;DR

**Recommendation: Approach 5, the staged hybrid** — and specifically, commit only to its
Stage 0 and Stage 1 now. Build one real F&B vertical slice by hand, extract the block
libraries from what repeats, and treat the compiler (Approach 2) and the runtime
registry (Approach 3) as later purchases gated on measured evidence, not as
architecture decided today.

The reasoning is uncomfortable but simple: Approaches 2, 3, and 4 all describe
destinations that are defensible, but each spends between 22 and 59 engineer-weeks on
framework machinery before the first business feature ships. That range is measured from
an empty repository: ~30 for Approach 4, ~22–59 for Approach 3, and ~56 for Approach 2
(its ~16 engineer-weeks of MVP plugins sit on top of Approach 1's ~40-week blueprint,
which it presupposes). Approach 5 reaches the same first-feature point in 50
engineer-weeks (Stage 0 plus Stage 1), and unlike the others that 50 has already shipped
product. Approach 1 is the only one
whose output is never wasted regardless of what comes next, because every other
approach generates code against Approach 1's block interfaces. Stopping permanently at
Stage 1 delivers the stated goals minus convenience — the deep dive argues plainly that
this is an acceptable outcome, not a failure.

The single most important design decision is not which approach wins. It is the **seam**:
business code depends only on stable, hand-written block interfaces
(`tenancy.Resolver`, `audit.Recorder`, `authz.Enforcer`, `pii.Classifier`), enforced by
a CI import-graph rule that blocks may never import generated code. With that seam in
place, generation and runtime layers become deletable rather than load-bearing, and the
choice between approaches stops being a one-way door.

## The five approaches

| #   | Name                    | One-line thesis                                                                                                | Deep dive                                      |
| --- | ----------------------- | -------------------------------------------------------------------------------------------------------------- | ---------------------------------------------- |
| 1   | Kratos Blueprint        | A template repository plus ~20 hand-written reusable block libraries. Leverage from convention, not machinery. | [`01`](01-approach-kratos-blueprint.md)        |
| 2   | Proto Compiler          | Annotated protobuf is the DSL; custom protoc/buf plugins generate the entire vertical slice as static Go.      | [`02`](02-approach-proto-compiler.md)          |
| 3   | Runtime Resource Engine | Ash in Go: resources and actions declared as data, interpreted by a generic runtime engine.                    | [`03`](03-approach-runtime-resource-engine.md) |
| 4   | Ent Schema-First        | Don't invent a DSL — adopt Ent's mature schema-as-Go-code and extend it with `entc` extensions.                | [`04`](04-approach-ent-schema-first.md)        |
| 5   | Staged Hybrid           | Sequence the other four so each stage is independently useful even if the next is never built.                 | [`05`](05-approach-hybrid-staged.md)           |

And one case study of a system that already exists, used to check the five proposals against
something shipped rather than reasoned:

| #   | Case study     | Thesis                                                                                                               | Deep dive                             |
| --- | -------------- | -------------------------------------------------------------------------------------------------------------------- | ------------------------------------- |
| 6   | tx7do / GoWind | What Approach 2's generation half plus Approach 4's data layer actually look like in production, and where it stops. | [`06`](06-case-study-tx7do-gowind.md) |

Supporting references, shared by all five:

| File                                                                       | Contents                                                                                                                                                     |
| -------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| [`10-compliance-blocks.md`](10-compliance-blocks.md)                       | ISO/IEC 27001:2022 Annex A, GDPR, and Indonesian PDP Law (UU 27/2022) mapped to concrete blocks; the erasure problem; the evidence artefacts an auditor gets |
| [`11-fnb-mini-erp-and-accurate.md`](11-fnb-mini-erp-and-accurate.md)       | F&B bounded contexts, POS-to-accounting flows, inventory costing, local-first offline POS, and the Accurate anti-corruption layer                            |
| [`12-bootstrap-tooling-and-skills.md`](12-bootstrap-tooling-and-skills.md) | `blocksctl` CLI, templates, agent skills and MCP surface, and concrete clone plans for GoWind CMS and GoWind Shop                                            |

## Comparative analysis

### Fit against the stated goals

Scoring: ● strong, ◐ partial, ○ weak or absent.

| Stated goal                                 |              1 Blueprint              |            2 Compiler             |                   3 Runtime                   |                4 Ent-first                |          5 Staged          |
| ------------------------------------------- | :-----------------------------------: | :-------------------------------: | :-------------------------------------------: | :---------------------------------------: | :------------------------: |
| Standardized engineering practice           |   ◐ convention only, no enforcement   |    ● generator is the enforcer    |           ● engine is the enforcer            |         ● `entc` is the enforcer          |   ● by Stage 2, ◐ before   |
| Reusable modular solutions                  |     ● blocks are the deliverable      |                 ●                 |                       ●                       |                     ●                     |             ●              |
| Dead consistent and predictable             |         ◐ drifts across teams         |    ● static Go, readable diffs    |       ○ interpreter hides control flow        |                ● static Go                |             ●              |
| Contract-driven via proto                   |    ● proto is hand-authored truth     |       ● proto _is_ the DSL        |     ◐ proto derived from Go declarations      |      ◐ proto derived from Ent schema      |             ●              |
| Cost-driven (modular monolith, local-first) |                   ●                   |                 ●                 |               ◐ engine overhead               | ● Ent's SQLite driver is a real advantage |             ●              |
| Business logic over plumbing                | ○ plumbing is hand-written every time |                 ●                 |                       ●                       |                     ●                     |        ● by Stage 2        |
| Compliance by construction                  |    ◐ enforced only where annotated    |   ● annotations become controls   |            ● one audited pipeline             |          ● Ent privacy policies           |             ●              |
| AI-agent friendly                           | ○ no machine-readable action registry | ● proto + generated tool manifest | ● runtime introspection is the killer feature |   ◐ Go source needs a compiler to parse   | ● registry arrives Stage 3 |

### Cost, risk, and ceiling

| Dimension                               | 1 Blueprint                       | 2 Compiler                                                                                              | 3 Runtime                                                                    | 4 Ent-first                                  | 5 Staged                                                                               |
| --------------------------------------- | --------------------------------- | ------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------- | -------------------------------------------- | -------------------------------------------------------------------------------------- |
| Effort to a usable v1                   | ~40 engineer-weeks                | ~16 ew for the 5 MVP plugins, on top of a working blueprint                                             | ~22 ew minimum credible v1; ~59 ew full                                      | ~30 ew                                       | 50 ew by month 4 (Stages 0–1); 162 ew for Stages 0–3, Stage 4 ongoing at 32 ew/quarter |
| Time before the first F&B feature ships | shortest                          | medium                                                                                                  | longest (3-4 quarters)                                                       | short                                        | shortest                                                                               |
| What you now maintain forever           | libraries                         | a compiler                                                                                              | an interpreter                                                               | an `entc` extension coupled to Ent's roadmap | libraries, then optionally the rest                                                    |
| Primary failure mode                    | copy-paste drift across repos     | review fatigue on 15-30x generated volume; a policy-generator bug is a cross-resource security incident | opaque failures, lost stack traces, a framework only its author can maintain | ORM shape leaking into the domain model      | stages slip; Stage 2/3 never happen                                                    |
| Team-size ceiling                       | ~15 engineers / 1-3 teams         | high                                                                                                    | high, if anyone else can maintain it                                         | high                                         | high                                                                                   |
| Bus-factor exposure                     | low                               | high                                                                                                    | very high                                                                    | medium                                       | medium, mitigated structurally                                                         |
| Escape hatches                          | trivially, it is all hand-written | good, hand-written hooks and overrides                                                                  | poor, you fight the engine                                                   | good, drop to Ent or raw SQL                 | good, the seam guarantees it                                                           |
| Reversibility                           | n/a, it is the floor              | delete the generators, keep the output                                                                  | very hard                                                                    | medium                                       | designed in                                                                            |

### The decisive objections, one per approach

**Approach 1** has no enforcement mechanism. Service, biz, and data plumbing propagates
by copy-paste from a template snapshot, so drift across repositories is the design
working as specified rather than a discipline failure. It also has no machine-readable
action registry, which blocks two charter goals outright: no derived admin UI, no
generated tool surface for runtime agents, and no mechanical proof that every action is
covered by authorization and audit.

**Approach 2** hits a hard expressiveness wall in protobuf options. Options are a data
language, so an `authorize` expression degenerates into a hand-rolled CEL subset and
anything conditional becomes stringly-typed. The workable rule is that options declare
_facts_ while behaviour lives in hand-written hooks. The underrated risk is not the
plugins but review fatigue: at 15-30x generated-to-source volume, reviewers rubber-stamp
`.gen.go`, so CI must gate on generated _diff summaries_ — policy-matrix delta, RoPA
delta — rather than raw code.

**Approach 3** fights the language. Ash works because Elixir has macros; Go has to do
the same work at runtime, trading compile-time safety for an interpreter that eats stack
traces and readability. That directly contradicts stated goal 3, "dead consistent and
predictable." Generics genuinely reduce reflection on the hot path but cannot type the
registry, the expression language, or wire-shaped filter input. Its verdict is the
bluntest of the five: don't build it — steal its introspection contract, its
attribute-level compliance metadata, and its single audited pipeline, and put them in
Approach 5.

**Approach 4** buys generation but not a domain model. An ORM schema is not a domain
resource: persistence shape leaks into the API and the domain, and non-persistent
resources plus cross-aggregate actions (shift close, an Accurate posting run) have no
home in the DSL. `entproto` is also the least-maintained corner of Ent and is CRUD-only,
so action RPCs end up as go-blocks templates anyway. The recommended resolution is
Ent→proto for internal gRPC contracts, guarded by a field-number ledger and
`buf breaking` in CI, with hand-written BFF protos owning the public API shape.

**Approach 5** is a plan, and plans slip. The honest reading is that momentum stops
after Stage 1 in most organisations. The deep dive therefore argues Stage 1 is a
legitimate terminal state and gates Stages 2 and 3 behind numeric exit criteria and a
hard three-call-site rule. Two weaknesses are left unhedged: numeric gates invite gaming
(measuring the 30-minute resource target on a conveniently simple resource), and a
framework authored by the Head of Engineering is a bus factor of one — mitigated
structurally (owner plus backup per block, no more than two blocks personally owned, and
a single-contributor `git log` across more than half the interfaces treated as its own
kill signal), not motivationally.

### What Approach 5 takes from each sibling

| From        | Adopted                                                                                                                 | Rejected                                                |
| ----------- | ----------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------- |
| 1 Blueprint | The block libraries and their interfaces — this is the permanent substrate                                              | Hand-writing plumbing forever                           |
| 2 Compiler  | Annotations as declared facts; generators only for plumbing with 3+ proven call sites                                   | Generating business behaviour; a full compiler up front |
| 3 Runtime   | The introspection contract, attribute-level compliance metadata, one audited action pipeline                            | The general interpreter; runtime-dynamic business logic |
| 4 Ent-first | Ent privacy policies as an independent second authorization layer; `entc`, Atlas, and the SQLite driver for local-first | Ent as the domain source of truth                       |

## Decisions that need a human answer

These are the points where different reasonable answers change the work materially, so
they are surfaced rather than assumed.

1. **Does the F&B mini-ERP have to trade in a real outlet within 12 months?** If yes,
   Approaches 2, 3, and 4 are all excluded as a first move, and only Stage 0/Stage 1 of
   Approach 5 fits. If the framework is the primary goal and the ERP is its proving
   ground, Approach 4 becomes competitive as a direct start.
2. **Is the AI-agent surface a launch requirement or a Stage 3 feature?** A runtime tool
   surface that can invoke privileged actions is a genuine attack surface via prompt
   injection. Treating it as Stage 3 is the recommendation; treating it as launch scope
   raises Approach 2's priority sharply.
3. **Kratos v3 exposure.** v3.0.0 shipped in June 2026 and is young. Confirm whether the
   organisation accepts tracking a young major version, or whether go-blocks should
   pin v2 for the first product and migrate deliberately.
4. **Tenancy isolation model** — shared schema with a tenant predicate, schema-per-tenant,
   or database-per-tenant. This cannot be retrofitted cheaply. See
   [`10-compliance-blocks.md`](10-compliance-blocks.md) for the recommendation and its
   reasoning.
5. **Accurate posting granularity** — per-transaction or daily-summary. This drives the
   integration's entire shape and its failure behaviour during trading hours. See
   [`11-fnb-mini-erp-and-accurate.md`](11-fnb-mini-erp-and-accurate.md).
6. **How much of GoWind CMS and Shop to actually clone.** Both reference systems carry
   scope traps — four front-end variants, mini-program support, OpenSearch on day one,
   five commerce domains built for a single caller. See
   [`12-bootstrap-tooling-and-skills.md`](12-bootstrap-tooling-and-skills.md).

## Status of this document set

These are design proposals, not implemented code. No go-blocks code exists in this
repository yet; the repository currently contains only this analysis. Effort estimates
are engineering judgement, not measurements. Compliance content is engineering guidance,
not legal advice — several Indonesian PDP Law article numbers and penalty figures were
deliberately omitted rather than guessed, and those omissions are flagged inline in
[`10-compliance-blocks.md`](10-compliance-blocks.md). Accurate API details that could not
be verified against published documentation are marked as unverified in
[`11-fnb-mini-erp-and-accurate.md`](11-fnb-mini-erp-and-accurate.md).
