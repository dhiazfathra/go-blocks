# go-blocks — Compliance Blocks

Reference mapping from ISO/IEC 27001:2022, the GDPR, and Indonesian Law No. 27 of
2022 on Personal Data Protection (UU PDP) to concrete go-blocks components. Other
approach documents point here instead of restating control mappings.

## Scope and disclaimer

This is engineering guidance, not legal advice. A framework can deliver technical
measures and some organisational scaffolding; it cannot deliver certification or
compliance. ISO/IEC 27001 certification requires an ISMS — scope statement,
leadership commitment, risk assessment and treatment plan, Statement of
Applicability, internal audit, management review — and a certification audit by an
accredited body. GDPR and UU PDP compliance likewise depend on lawful-basis
decisions, records, contracts, and accountability processes that live outside any
codebase. Where the table below says "supports", the framework produces evidence or
enforces a mechanism; a human still owns the control.

## The three regimes in one table

| Regime                         | What it governs                                                                                         | A framework can implement                                                                                                                    | A framework cannot                                                                                                              |
| ------------------------------ | ------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| ISO/IEC 27001:2022             | An information security management system, with Annex A as a control reference set                      | Technical Annex A controls: access control, logging, cryptography, deletion, masking, environment separation                                 | Clauses 4–10 (ISMS itself), risk assessment, SoA, internal audit, management review, certification                              |
| GDPR (EU 2016/679)             | Processing of personal data of people in the EU/EEA                                                     | Data-subject-right mechanics, consent records, retention, security of processing, RoPA generation, breach detection inputs                   | Lawful-basis selection, DPIAs, DPO appointment, controller/processor contracts, transfer impact assessments, regulator dealings |
| UU PDP No. 27/2022 (Indonesia) | Processing of personal data by Indonesian controllers and processors, and of Indonesian subjects abroad | Same technical surface, plus a breach-notification pipeline fast enough for the 3×24-hour deadline and Indonesian-language consent artefacts | DPO appointment, agency registration and correspondence, sanction exposure, sectoral licensing                                  |

## ISO/IEC 27001:2022 Annex A control mapping

Only controls a backend framework can genuinely act on are listed. "Satisfies"
means the block enforces the control for code built on it; "supports" means the
block supplies mechanism or evidence but the control still depends on policy,
process, or infrastructure outside the framework.

| Control | Name                                                        | go-blocks component                                                                                            | Level                                            |
| ------- | ----------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- | ------------------------------------------------ |
| A.5.15  | Access control                                              | `blocks/authz` — RBAC + ABAC policy evaluated in a mandatory interceptor                                       | Satisfies (technical enforcement)                |
| A.5.16  | Identity management                                         | `blocks/authn` — user/service identity lifecycle, unique subject IDs, deactivation                             | Supports                                         |
| A.5.17  | Authentication information                                  | `blocks/authn` — Argon2id credential storage, token issuance/rotation, secret handling via `blocks/crypto`     | Supports                                         |
| A.5.18  | Access rights                                               | `blocks/authz` role and grant model, generated access-control matrix, revocation on role change                | Supports (provisioning/review is a process)      |
| A.5.33  | Protection of records                                       | `blocks/audit` append-only hash-chained log plus `blocks/retention` legal-hold                                 | Supports                                         |
| A.5.34  | Privacy and protection of PII                               | `blocks/pii` classification taxonomy, `blocks/consent`, `blocks/dsar`                                          | Supports                                         |
| A.8.2   | Privileged access rights                                    | `blocks/authz` privileged-action marking, break-glass grants with expiry, mandatory audit entry                | Supports                                         |
| A.8.3   | Information access restriction                              | `blocks/authz` row-level and field-level filters pushed into the data layer (Ent privacy policies)             | Satisfies (technical enforcement)                |
| A.8.5   | Secure authentication                                       | `blocks/authn` — MFA hooks, rate limiting via `blocks/ratelimit`, session invalidation                         | Supports                                         |
| A.8.10  | Information deletion                                        | `blocks/retention` scheduled erasure, `blocks/dsar` erasure action, crypto-shredding in `blocks/crypto`        | Satisfies for framework-managed stores only      |
| A.8.11  | Data masking                                                | `blocks/pii` redaction of classified fields in logs, traces, errors, and generated exports                     | Satisfies for framework-managed output paths     |
| A.8.12  | Data leakage prevention                                     | `blocks/pii` + generated proto redactors; per-BFF scoped OpenAPI so one surface cannot expose another's schema | Supports                                         |
| A.8.15  | Logging                                                     | `blocks/audit` for business events, `blocks/observability` for technical logs, both with PII redaction         | Satisfies                                        |
| A.8.16  | Monitoring activities                                       | `blocks/observability` — OTel traces/metrics, anomaly hooks on audit stream                                    | Supports (alerting and response are operational) |
| A.8.24  | Use of cryptography                                         | `blocks/crypto` — envelope encryption, KMS-backed keys, rotation, TLS defaults                                 | Supports (key policy is organisational)          |
| A.8.28  | Secure coding                                               | Generated transport/validation layers, `protoc-gen-validate` contracts, CI gates, per-block usage rules        | Supports                                         |
| A.8.31  | Separation of development, test and production environments | Framework config profiles, seeded synthetic data, refusal to run auto-DDL under a production profile           | Supports (infrastructure decides)                |
| A.8.32  | Change management                                           | Buf breaking-change detection, versioned migrations, `blocks/audit` on configuration changes                   | Supports                                         |

Deliberately not claimed: physical controls (A.7.x), supplier relationships,
HR security, business continuity, and threat intelligence. A library cannot touch
them.

## GDPR article mapping

| Article     | Obligation                                                                                        | go-blocks component or generated artefact                                                                                                                                                     |
| ----------- | ------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Art. 5      | Principles: lawfulness, purpose limitation, minimisation, accuracy, storage limitation, integrity | `blocks/pii` (minimisation via classification), `blocks/consent` (purpose binding), `blocks/retention` (storage limitation), `blocks/crypto` + `blocks/authz` (integrity/confidentiality)     |
| Art. 6      | Lawful basis for processing                                                                       | `blocks/consent` records a `LegalBasis` per purpose; the resource action declares which basis it relies on and refuses to run without one                                                     |
| Art. 7      | Conditions for consent, including withdrawal                                                      | `blocks/consent` — versioned policy text, timestamp, actor, evidence, `Withdraw` action as easy as `Grant`                                                                                    |
| Arts. 12–14 | Transparency and information duties                                                               | Generated privacy-notice fragments from `blocks/pii` field annotations plus purpose registry; versioned policy text served by `blocks/consent`                                                |
| Art. 15     | Right of access (DSAR)                                                                            | `blocks/dsar` `Export` — machine-assembled from PII annotations across all resources                                                                                                          |
| Art. 16     | Rectification                                                                                     | `blocks/dsar` `Rectify` mapped onto resource update actions with an audit entry                                                                                                               |
| Art. 17     | Erasure                                                                                           | `blocks/dsar` `Erase` with per-resource strategy (hard delete, anonymise, crypto-shred); see "Erasure is the hard part"                                                                       |
| Art. 18     | Restriction of processing                                                                         | `blocks/dsar` restriction flag enforced as an `blocks/authz` predicate that blocks non-storage processing                                                                                     |
| Art. 20     | Data portability                                                                                  | `blocks/dsar` structured export (JSON, and CSV per resource) derived from proto schemas                                                                                                       |
| Art. 21     | Objection                                                                                         | `blocks/consent` objection record; marketing and profiling purposes check it before use                                                                                                       |
| Art. 25     | Data protection by design and by default                                                          | The framework's defaults: deny-by-default authz, encryption on `sensitive` fields, redacted logs, retention required per resource, CI gate on unclassified fields                             |
| Art. 30     | Records of processing activities                                                                  | Generated RoPA from PII annotations, purpose registry, retention policies, and declared processors                                                                                            |
| Art. 32     | Security of processing                                                                            | `blocks/crypto`, `blocks/authz`, `blocks/audit`, `blocks/observability`, plus the Annex A table above                                                                                         |
| Arts. 33–34 | Breach notification (72 h to the authority)                                                       | `blocks/audit` anomaly detection and an incident workflow in `blocks/workflow` that computes affected subjects from PII inventory and drafts notifications                                    |
| Art. 35     | DPIA                                                                                              | Framework supplies inputs only: data-flow inventory, PII categories, processor list. The assessment itself is human work                                                                      |
| Arts. 44–49 | International transfers                                                                           | Processor registry records each destination, mechanism (SCCs, adequacy), and data categories; `blocks/pii` can pin a residency tag per field and refuse egress to a non-permitted destination |

## Indonesian PDP Law (UU 27/2022) mapping

| Obligation                                                                                                                                                                                      | Statutory anchor                 | go-blocks component                                                                                                                                                                         |
| ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Data subject rights: information, access, correction, deletion, withdrawal of consent, objection to automated decision-making, portability, redress                                             | Arts. 5–13                       | `blocks/dsar` (access, rectify, erase, export), `blocks/consent` (withdrawal, objection), automated-decision registry in `blocks/authz` policy metadata                                     |
| Lawful bases for processing (consent, contract, legal obligation, vital interests, public interest, legitimate interests)                                                                       | Ch. V                            | `blocks/consent` `LegalBasis` enum; every action declares its basis                                                                                                                         |
| Distinction between general and specific (sensitive) personal data                                                                                                                              | Art. 4                           | `blocks/pii` categories: health, biometrics, genetics, sexual life, political views, criminal records, children's data, personal finance                                                    |
| Controller and processor duties, processing agreements                                                                                                                                          | Ch. V                            | Processor registry; `blocks/audit` records processor handoffs                                                                                                                               |
| DPO appointment for large-scale or sensitive processing                                                                                                                                         | Art. 53                          | Not a framework capability. The framework records who the DPO is and routes DSAR queues to them                                                                                             |
| Breach notification within 3×24 hours to the PDP agency and affected subjects, with public notice where public services are disrupted                                                           | Art. 46                          | Incident workflow with a 72-hour-clock SLA timer, affected-subject computation, and a notification template carrying the three statutory contents: what data, when and how, and remediation |
| Retention and deletion when purpose is fulfilled or consent withdrawn                                                                                                                           | Ch. V                            | `blocks/retention` policies keyed to purpose, not just age                                                                                                                                  |
| Cross-border transfer conditions (adequate protection in the destination, or binding safeguards, or consent)                                                                                    | Ch. VIII                         | Residency tags per field; egress policy enforced in `blocks/pii`                                                                                                                            |
| Consent recording — explicit, informed, in Indonesian, per purpose                                                                                                                              | Ch. V                            | `blocks/consent` stores the exact Indonesian-language policy version shown, per purpose, with evidence                                                                                      |
| Sanction exposure: administrative sanctions including fines up to 2% of annual revenue; separate criminal provisions for unlawful obtaining, disclosure, use, or falsification of personal data | Art. 57 and the criminal chapter | Not mitigable by code alone; the audit trail is the primary defensive evidence                                                                                                              |

### How UU PDP differs from the GDPR, and what that means for defaults

Structurally the two are close: the same lawful-basis architecture, the same rights
catalogue, the same controller/processor split, similar security obligations. Three
differences change the framework's defaults.

1. **Breach notification is 3×24 hours, not 72 hours from awareness, and it runs to
   the data subjects as well as the agency.** GDPR Art. 34 requires subject
   notification only for high-risk breaches; UU PDP Art. 46 requires it as the
   normal case. So the notification pipeline cannot be a manual runbook: the
   framework must be able to compute "which subjects had which fields in this
   affected store" from the PII inventory quickly. That is a design requirement on
   `blocks/pii`, not an afterthought.
2. **Consent formalities are heavier in practice.** Consent must be explicit,
   per-purpose, and presented in Indonesian. The default in `blocks/consent` is
   therefore versioned localised policy text stored with the consent record, not a
   boolean plus a policy URL.
3. **Localisation expectations.** UU PDP itself sets transfer conditions rather than
   a hard localisation mandate, but Indonesian sectoral rules (notably financial
   services and public electronic systems) do impose residency requirements, and an
   F&B business taking card payments will meet them through its payment provider.
   The framework's default is therefore data-resident-by-default: Indonesian region
   storage, with explicit per-field opt-in required to route anything to a foreign
   processor.

For the F&B mini-ERP this yields concrete defaults: customer and employee PII in an
Indonesian region; consent captured per purpose in Indonesian with the policy
version retained; loyalty and marketing profiling gated on a separate purpose;
Accurate Online declared as a processor with financial-record retention documented
as a statutory override of erasure.

## The compliance blocks

### `blocks/audit`

Tamper-evident append-only log. Each entry stores the hash of the previous entry,
making retroactive edits detectable without making them impossible — which is the
honest claim for a database-backed log.

```go
type Entry struct {
    ID        uuid.UUID
    Seq       uint64    // monotonic per tenant
    TenantID  uuid.UUID
    ActorID   string    // user, service, or job identity
    ActorType ActorType // user | service | job | system
    Action    string    // "order.void", "customer.export"
    Resource  string    // "order"
    ResID     string
    Purpose   string    // links to the consent purpose registry
    Outcome   Outcome   // allow | deny | error
    Metadata  json.RawMessage // PII-redacted diff
    At        time.Time
    PrevHash  []byte
    Hash      []byte // H(PrevHash || canonical(entry))
}

type Log interface {
    Append(ctx context.Context, e Entry) error
    Verify(ctx context.Context, tenant uuid.UUID, from, to uint64) (Report, error)
}
```

Enforcement point: a Kratos middleware after authorization, plus an Ent hook so
data mutations cannot bypass the transport layer. Metadata passes through
`blocks/pii` redaction before write. Retention is independent of, and usually
longer than, the retention of the records it describes — audit entries reference
subjects by pseudonymous ID so the log survives erasure of the subject.

### `blocks/consent`

```go
type Record struct {
    ID            uuid.UUID
    SubjectID     string
    Purpose       string // registry key: "marketing.email", "loyalty.profiling"
    LegalBasis    LegalBasis
    PolicyVersion string // exact versioned text shown
    Locale        string // "id-ID"
    Granted       bool
    Evidence      json.RawMessage // channel, IP, UA, form ID
    GrantedAt     time.Time
    WithdrawnAt   *time.Time
}

type Store interface {
    Grant(ctx context.Context, r Record) error
    Withdraw(ctx context.Context, subject, purpose string) error
    Check(ctx context.Context, subject, purpose string) (Decision, error)
    History(ctx context.Context, subject string) ([]Record, error)
}
```

Records are never updated in place; withdrawal appends. Enforcement point: an
action declares `purpose` in its proto options, and the action runtime calls
`Check` before executing. A missing purpose declaration is a build failure, not a
runtime default.

### `blocks/pii`

Classification is the keystone: nearly every other block derives its behaviour from
it. Fields are annotated in proto and the annotation flows into Ent, logs, exports,
and generated documents.

```go
type Class uint8 // None, Pseudonymous, Personal, Sensitive, Financial, Credential

type Field struct {
    Resource  string
    Name      string
    Class     Class
    Category  string   // "health", "biometric", "contact", "location"
    Purposes  []string
    Residency string   // "id-ID" | "any"
    Encrypt   bool
}

type Redactor interface {
    Redact(ctx context.Context, resource string, v any) any
}
```

Enforcement points: a log/trace processor that redacts before emission; an error
middleware that strips PII from messages returned to clients and from stack traces;
generated proto redactors on every outbound message. `Sensitive`, `Financial`, and
`Credential` default to encrypted-at-rest via `blocks/crypto` and to full masking
in logs; `Personal` defaults to partial masking.

### `blocks/retention`

```go
type Policy struct {
    Resource  string
    Basis     Basis         // purpose_fulfilled | fixed_period | statutory
    Duration  time.Duration // for fixed_period
    Statute   string        // e.g. "ID tax records, 10 years"
    OnExpiry  Strategy      // hard_delete | anonymise | crypto_shred
}

type Hold struct {
    Resource, ResID, Reason string
    RequestedBy             string
    Until                   *time.Time
}
```

Every resource must declare a policy; an unregistered resource fails the build.
A scheduled job in `blocks/jobs` sweeps expired records per policy, writing one
audit entry per batch. Legal holds override expiry and are themselves auditable —
a hold with no expiry and no review date is a finding, not a feature.

### `blocks/dsar`

```go
type Service interface {
    Export(ctx context.Context, subject string, f Format) (Bundle, error)
    Rectify(ctx context.Context, subject string, patch Patch) error
    Erase(ctx context.Context, subject string, scope Scope) (Result, error)
    Restrict(ctx context.Context, subject string, on bool) error
}
```

`Export` walks the PII field inventory, so a new annotated field appears in exports
without new code. Portability format: JSON as the canonical structured output, with
a per-resource CSV rendering for readability; both include a manifest of resources,
purposes, and legal bases.

Erasure needs a referential-integrity strategy per resource, declared alongside the
retention policy. Three options, in order of preference: **anonymise in place**
(replace PII fields with tombstones, keep the row so orders and invoices still
balance), **crypto-shred** (destroy the per-subject data key, leaving ciphertext),
and **hard delete** (only for leaf records with no financial or audit significance).
For the F&B ERP, orders anonymise, marketing profiles hard-delete, and free-text
notes crypto-shred.

### `blocks/crypto`

```go
type Keyring interface {
    DataKey(ctx context.Context, subject string) (DataKey, error) // envelope
    Rotate(ctx context.Context, keyID string) error
    Destroy(ctx context.Context, subject string) error // crypto-shred
}
```

Envelope encryption: a KMS-held root key wraps per-tenant keys, which wrap
per-subject data keys. Field-level encryption is applied by an Ent value
transformer driven by the `Encrypt` flag in `blocks/pii`, so no business code calls
crypto directly. Rotation re-wraps rather than re-encrypts payloads where possible.
`Destroy` is the crypto-shredding path: it makes a subject's ciphertext
unrecoverable everywhere at once, including in backups — which is precisely why it
is the most useful erasure primitive available.

### `blocks/authz`

RBAC for coarse decisions (roles, permissions, menu/API scope), ABAC for the rest
(tenant, ownership, restriction flag, purpose, time of day, store location).

```go
type Request struct {
    Subject  Principal
    Action   string
    Resource string
    ResID    string
    Attrs    map[string]any
}

type Engine interface {
    Decide(ctx context.Context, r Request) (Decision, error)
    RowFilter(ctx context.Context, p Principal, resource string) (Predicate, error)
    FieldMask(ctx context.Context, p Principal, resource string) (Mask, error)
}
```

Three enforcement points, all mandatory: a transport interceptor for the action
decision, an Ent privacy policy for row-level predicates (tenant isolation lives
here, not in handlers), and a field mask applied on serialisation for field-level
restriction. Default deny. A resource with no policy is unreachable.

### `blocks/tenancy`

| Model                            | Isolation                                         | Cost    | Migration                 | Noisy neighbour |
| -------------------------------- | ------------------------------------------------- | ------- | ------------------------- | --------------- |
| Shared schema + tenant predicate | Logical only; one missing predicate leaks data    | Lowest  | One migration for all     | Yes             |
| Schema per tenant                | Strong logical; search path errors still possible | Medium  | N schemas per migration   | Partially       |
| Database per tenant              | Strongest; separate credentials and backups       | Highest | N databases per migration | No              |

**Recommendation: shared schema with a tenant predicate enforced in the data
layer**, with schema-per-tenant available as a per-tenant escalation for customers
with contractual isolation requirements. Reasoning: the predicate approach's only
real weakness is developer error, and that weakness is removable — the predicate is
injected by an Ent privacy policy that no query can opt out of, and a test harness
asserts cross-tenant queries return empty for every resource. Paying
database-per-tenant operational cost to defend against a bug you can make
structurally impossible is the wrong trade for a modular monolith serving F&B SMEs.
Database-per-tenant remains the answer for a tenant that requires separate backup
and key custody, and the isolation model must be a configuration decision, not a
rewrite.

## Erasure is the hard part

Erasure rights read like a delete statement and behave like a distributed systems
problem. The places a subject's data lives after you delete the row:

- **Backups and PITR snapshots.** You cannot surgically edit a backup without
  destroying its integrity, and rewriting backups to honour erasure is worse than
  the disease. Crypto-shredding is the only clean answer here.
- **Read replicas and CDC streams.** Deletes propagate, but lag and replay windows
  mean "deleted" is eventually true, not immediately true. Document the window.
- **Audit logs you are required to retain.** A.5.33 and the notification duties
  require records that describe processing of the very subject demanding erasure.
  Resolve this by making audit entries reference pseudonymous subject IDs with the
  identifying map held in an encrypted, separately shreddable store.
- **Search indices and caches.** OpenSearch documents and Redis entries are copies.
  Erasure must fan out to them; the sweep job needs an explicit per-index handler,
  and cache TTLs need to be short enough that "erased" is honest.
- **Analytics warehouses.** Usually the largest unmanaged copy. Either exclude PII
  at ingestion (preferred) or accept an erasure fan-out to the warehouse.
- **Third-party processors.** Each needs a documented erasure route. The Accurate
  Online integration is the important case: once a transaction becomes an
  accounting entry, Indonesian bookkeeping and tax retention obligations apply, and
  those override the erasure right for that record. That is a legitimate override,
  not a gap — but it has to be written down.

Decision framework per resource:

| Condition                                                                         | Strategy                                                    |
| --------------------------------------------------------------------------------- | ----------------------------------------------------------- |
| Leaf record, no statutory retention, no referential dependants                    | Hard delete                                                 |
| Record needed for financial or operational integrity, but not for identity        | Anonymise in place (tombstone the PII fields, keep the row) |
| Data in backups, immutable stores, or free-text fields you cannot reliably locate | Crypto-shred the per-subject key                            |
| Statutory retention applies (accounting, tax, employment)                         | Retain, restrict processing, log the override               |

Document each conflict as a row in the retention matrix: resource, erasure request
outcome, the retention obligation that overrides it, the statute, the expiry date
after which erasure will proceed, and who decided. This document is what turns
"we did not delete it" from a violation into a defensible, disclosed position — and
Arts. 12 and 17(3) require you to tell the subject which it is.

## Evidence and automation

The framework should emit audit evidence as build artefacts, not as documents
someone maintains by hand:

- **RoPA** — generated from PII annotations, the purpose registry, retention
  policies, and the processor list. Stale by construction is impossible.
- **Retention matrix** — every resource, its policy, expiry strategy, statutory
  overrides, and active legal holds.
- **Access-control matrix** — roles × resources × actions, with row and field
  restrictions, rendered from the authz policy set.
- **Audit-log integrity report** — periodic hash-chain verification per tenant,
  with the last verified sequence and any break recorded.
- **Data-flow inventory** — resources, fields, classifications, residency tags, and
  every egress destination, as a DPIA and transfer-assessment input.
- **SBOM** — CycloneDX from the Go module graph, per release, with vulnerability
  scan results attached.
- **CI gates** — a build fails when a new field lacks a PII classification, a
  resource lacks a retention policy, an action lacks a declared legal basis or
  purpose, a resource lacks an authz policy, or proto changes break the contract.
  This is where "compliance by construction" is either real or marketing.

## What this does not give you

- An ISMS: scope, policies, objectives, leadership commitment, management review
- A risk register, risk assessment methodology, or Statement of Applicability
- Security policies, standards, and procedures anyone has actually approved
- Security awareness training and HR security processes
- Vendor and processor due diligence, contracts, DPAs, and transfer mechanisms
- Physical and environmental security
- Business continuity and disaster recovery plans, and evidence they were tested
- Penetration testing, red teaming, and vulnerability management as a process
- A DPO appointment, or anyone at all accountable for privacy
- DPIAs, legitimate interest assessments, and transfer impact assessments
- Incident response as an exercised capability rather than a code path
- The certification audit itself, and the surveillance audits after it

The framework's honest claim is narrower and still worth a lot: it removes the
technical-measure work from every project built on it, and it generates the evidence
an auditor asks for first.
