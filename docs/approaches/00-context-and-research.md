# go-blocks — Context and Research Baseline

Shared research baseline for every approach document in this directory. Written first
so each deep-dive can assume the same facts instead of restating them.

## 1. What go-blocks is meant to be

An opinionated Go ecosystem — libraries, code generators, protobuf conventions, and
project skills — that lets a product team build compliant enterprise backends by
writing business logic only. Everything already solved (identity, permissions, audit,
multi-tenancy, media, jobs, search, i18n, observability, consent, retention) ships as a
reusable block.

Stated goals:

1. Standardized engineering practice.
2. Reusable modular solutions.
3. Dead consistent and predictable.
4. Contract-driven development using protobuf.
5. Cost-driven development: modular monolith, local-first architecture.
6. Developers spend their time on business logic, not re-solving solved problems.
7. Compliance by construction: ISO/IEC 27001, GDPR, Indonesian PDP Law (UU 27/2022).
8. AI-agent friendly: the system must be legible to and drivable by coding agents and
   runtime LLM agents.

Motivation: ownership, end-to-end learning, adoption by the author's engineering org
(the author is Head of Engineering), and portfolio value.

Immediate business driver: an **F&B mini-ERP** — full ERP scope minus the accounting
ledger, which is delegated to [Accurate Online](https://accurate.id/) via integration.

## 2. Reference system A — GoWind CMS (`gowind.cloud/cms`)

Enterprise-grade Go headless content platform. Multi-tenant, multi-site,
multi-language, multi-channel (web, app, mini-program).

Architecture: three services.

| Service | Transport            | Role                         |
| ------- | -------------------- | ---------------------------- |
| Admin   | HTTP/SSE (6600/6601) | Back-office BFF              |
| App     | HTTP/SSE (6700/6701) | Public/consumer BFF          |
| Core    | gRPC                 | Business logic + persistence |

Admin and App are API gateways; both call Core over gRPC. Interface concerns are
separated from business logic at the process boundary.

Stack: Go 1.25+, go-kratos, Ent ORM, PostgreSQL (default) or MySQL, Redis, MinIO
(S3-compatible), OpenSearch, Protobuf + buf, Asynq task queue, Jaeger +
OpenTelemetry, Casbin/OPA authorization, etcd service discovery, Docker Compose
deployment.

Frontends: Vue 3 + TypeScript + Ant Design Vue on Vben Admin (monorepo, Vite +
Turbo) for admin; four consumer variants — Nuxt + shadcn-vue, Next.js + shadcn/ui,
Taro + React for mini-programs/H5, and Flutter + BLoC.

Feature surface: posts, categories, tags, comments, pages, publish/unpublish,
ordering, batch ops, recycle bin; tenants, users, role and department trees,
menu/API/data/button-level permissions; sites, translations, navigation, SEO, global
params; media library on local or MinIO storage; dictionaries, API logs, scheduled
tasks, notifications, in-app messages, cache admin, login/operation/API audit logs.

Layout: `api/protos/` (41 admin + 11 app protos), `app/admin/service/`,
`app/app/service/`, `app/core/service/`, `pkg/` (auth, crypto, eventbus, JWT,
middleware, OSS), `frontend/admin/`, `frontend/app/`.

## 3. Reference system B — GoWind Shop (tx7do)

Enterprise e-commerce backend scaffold whose thesis is a genuine contract-driven
closure: **one `buf generate` produces six output classes** — gRPC stubs, HTTP stubs,
error helpers, request validators, PII redactors, and TypeScript clients — plus
OpenAPI.

Three tiers: BFF (admin, app — REST), Core (16 gRPC-only domain services), Data (Ent
with privacy policies enforcing row-level security).

The architectural boundary is encoded in the protos themselves: only BFF services
carry `google.api.http` annotations; core domains stay gRPC-only.

Domains: catalog, order, payment, identity, permission, authentication, audit, dict,
cart, shipping, storage, messaging, task, address, plus the two BFFs.

Stack: Kratos, buf + protoc plugins, Ent, Google Wire (compile-time DI), Gnostic for
OpenAPI, protoc-gen-validate, protoc-gen-go-errors, generated TypeScript HTTP clients,
etcd discovery, containerized deployment, external migration tooling (no auto-DDL in
production).

Notable practices worth stealing:

- Typed error codes declared in proto, mapped to HTTP status at definition time.
- FieldMask-driven partial updates to prevent accidental overwrites.
- Per-BFF scoped OpenAPI so one surface cannot leak another's schema.
- Ent privacy policies injecting tenant/row predicates in the data layer, not handlers.
- Wire catching missing dependencies at compile time; buf catching schema breakage.

## 4. Inspiration — Ash Framework (Elixir)

Philosophy: **model your domain, derive the rest.** Resources (User, Post, Order) plus
named Actions (`:publish_post`, `:approve_order`) are the single source of truth.
Database schema, API endpoints, authorization, and state machines are derived from that
declaration rather than hand-written per layer.

Properties go-blocks should copy:

- Actions encapsulate business meaning, validation, and authorization — not raw CRUD.
- Type-safe and introspectable: arguments validated automatically, actions discoverable
  at runtime by other tooling (this is precisely what makes it AI-agent friendly).
- Escape hatches: drop to Ecto or raw SQL anytime; no lock-in.
- Multi-tiered configurability: strong defaults for 80%, options for 15%, custom code
  for the last 5%.

Ash's package surface, as the checklist of blocks go-blocks eventually needs:

| Ash package                                 | Purpose              | go-blocks analogue                                |
| ------------------------------------------- | -------------------- | ------------------------------------------------- |
| Ash                                         | Core framework       | `blocks/core` resource + action runtime           |
| AshPostgres / AshSqlite / AshCsv / AshCubDB | Data layers          | Ent (Postgres) + SQLite local-first               |
| AshPhoenix                                  | Web integration      | Kratos HTTP/gRPC transports                       |
| AshGraphQL / AshJsonApi                     | Derived APIs         | derived REST/gRPC/OpenAPI/GraphQL from proto      |
| Reactor                                     | Workflows and sagas  | `blocks/workflow`                                 |
| AshAuthentication                           | Authentication       | `blocks/authn`                                    |
| AshAdmin                                    | Admin interface      | generated admin UI (Vben-style)                   |
| AshOban                                     | Background jobs      | `blocks/jobs` (Asynq / River)                     |
| AshStateMachine                             | State machines       | `blocks/statemachine`                             |
| AshArchival                                 | Soft deletion        | `blocks/archival` (recycle bin)                   |
| AshPaperTrail                               | Audit logs           | `blocks/audit` (ISO 27001 A.8.15)                 |
| AshRateLimiter                              | Rate limiting        | `blocks/ratelimit`                                |
| AshMoney / AshDoubleEntry                   | Money, double-entry  | `blocks/money`; ledger delegated to Accurate      |
| AshCloak                                    | Encryption           | `blocks/crypto` (field-level, GDPR Art. 32)       |
| AshGeo                                      | Geospatial           | `blocks/geo` (delivery zones)                     |
| AshAi                                       | LLM features         | `blocks/ai` (tool exposure of actions)            |
| AshEvents                                   | Event sourcing       | `blocks/events` (outbox + CDC)                    |
| AshTypescript                               | TS generation        | generated TS clients from proto                   |
| UsageRules                                  | Agent usage guidance | `AGENTS.md` + skills + `usage-rules.md` per block |
| AshAppSignal / OpentelemetryAsh             | APM, tracing         | `blocks/observability` (OTel)                     |

## 5. Platform baseline: go-kratos v3

Kratos v3.0.0 shipped in June 2026. Headline change: fewer core dependencies and
previously implicit behavior made explicit. A v2→v3 migration guide exists. Practical
consequences for go-blocks:

- Fewer transitive dependencies in core means go-blocks supplies more of the opinion
  layer itself (middleware chains, config, registry wiring) — which is the point of
  this project, but it means more surface to own and version.
- "Explicit over implicit" aligns with the predictability goal, and makes generated
  wiring easier to read for both humans and agents.
- v3 is young. Every approach below must state its exposure to Kratos churn and its
  fallback if v3 ecosystem plugins (Kratos-specific protoc plugins, contrib registries)
  lag behind.

## 6. Non-negotiable constraints all approaches must satisfy

1. **Modular monolith first.** One deployable binary hosting many modules, with
   in-process transport that can be swapped for gRPC without changing business code.
   Microservices are a deployment decision made later, not an architecture tax paid now.
2. **Local-first.** SQLite (or embedded Postgres) plus sync must be a supported data
   layer, because F&B point-of-sale must keep selling when the network drops.
3. **Contract-driven.** Protobuf is the source of truth; hand-written duplicate
   contracts are a defect.
4. **Compliance by construction.** Audit trail, consent, retention, data-subject
   rights, encryption, access control, and PII classification are framework features,
   not per-project checklists.
5. **AI-agent friendly.** Machine-readable introspection of resources and actions,
   deterministic scaffolding, per-block usage rules, and a stable tool surface for
   runtime agents.
6. **Escape hatches everywhere.** Any generated or derived layer must be replaceable
   by hand-written code without abandoning the framework.

## 7. Document map

| File                                     | Contents                                                     |
| ---------------------------------------- | ------------------------------------------------------------ |
| `README.md`                              | Executive summary and comparative analysis across approaches |
| `00-context-and-research.md`             | This file                                                    |
| `01-approach-kratos-blueprint.md`        | Approach 1 — curated blueprint and library set               |
| `02-approach-proto-compiler.md`          | Approach 2 — proto-as-DSL generation compiler                |
| `03-approach-runtime-resource-engine.md` | Approach 3 — Ash-style runtime resource engine               |
| `04-approach-ent-schema-first.md`        | Approach 4 — Ent schema as the single DSL                    |
| `05-approach-hybrid-staged.md`           | Approach 5 — staged hybrid (recommended)                     |
| `06-case-study-tx7do-gowind.md`          | Case study 6 — what tx7do actually shipped for GoWind        |
| `10-compliance-blocks.md`                | ISO 27001 / GDPR / PDP control-to-block mapping              |
| `11-fnb-mini-erp-and-accurate.md`        | F&B mini-ERP domain model and Accurate integration           |
| `12-bootstrap-tooling-and-skills.md`     | CLI, generators, skills, CMS and Shop clone plans            |
