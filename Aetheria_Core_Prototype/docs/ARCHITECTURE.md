# Architecture Notes v1.1 (CORE-02)

This document describes approved CORE-02 responsibilities and contracts. It does not claim that they are implemented or authorize project structure changes. Keep it aligned with `docs/CORE_SPEC.md`.

## Runtime responsibilities

- `ReplicatedStorage/Shared`: shared constants, schemas, type definitions, and non-secret configuration.
- `ServerScriptService/Server`: authoritative server systems and bootstrap.
- `StarterPlayer/StarterPlayerScripts/Client`: UI and input controllers. Client code never accesses DataStores.

These names describe conceptual responsibilities only; they do not request a new folder structure. Server systems own critical gameplay and persistent state. Later systems such as Combat, Magic, Inventory, Progression, Factions, and Economy use explicit server APIs instead of directly changing arbitrary profile tables.

## Persistence stores and key ownership

Use exactly these two DataStore names:

| DataStore | Key | Record responsibility |
|---|---|---|
| `Aetheria_AccountRoster_v1` | `User_<UserId>` | One roster per Roblox account; membership, active slots, lifecycle operations, schema/revision, account lock/fencing |
| `Aetheria_CharacterProfiles_v1` | `Character_<UUID>` | One separate profile per character; gameplay data, schema, character lock/fencing |

Maximum three active characters per account. Names are unique within one account and may repeat across accounts. Race and class are immutable after creation is committed. The roster controls membership and slot count; profile data controls character gameplay state. Roster summaries are cached display metadata only. `activeCharacterId` is session state unless a later decision adds a validated preference.

Exact serialized field types, nested bounds, summary shape, UUID generation mechanism, lock encoding, and lifecycle encoding beyond the approved creation intent are unresolved implementation details. Records must be serializable and validated; do not persist Instances, userdata, functions, or cyclic values.

## Server boundaries

- **Startup/admission:** do not admit writable gameplay until persistence readiness, roster/profile validation, and required locks are established.
- **Persistence:** own key construction, DataStore calls, one queue per key, migrations, dirty tracking, locks/fencing, retries, and bounded shutdown coordination.
- **Lifecycle:** validate and serialize roster changes, creation, selection, deletion, restoration, retention cleanup, and interrupted-operation recovery.
- **Networking:** validate every request on the server. Clients cannot choose arbitrary keys or submit authoritative profile values.
- **Integrity/recovery:** isolate invalid records from ordinary loading/saving; administrative recovery preserves available original data and records action, reason, timestamp, and outcome.

## Session lock protocol

- Acquire account lock before selected-character lock and hold both for the full gameplay session. Release character first, then account after final-save handling. All multi-key operations follow this order.
- One account has at most one active gameplay session across servers.
- Use a unique `SessionToken` and monotonically increasing `LockGeneration`. Acquisition, renewal, release, and every persistent write conditionally validate ownership/fencing atomically at the relevant key. Takeover advances the generation.
- Schema validation checks lock field types and ranges only. Semantic token/lease consistency checks are deferred until the session-lock implementation defines and approves the persisted lock representation. The approved lock policy and fencing requirements remain in force.
- Heartbeat every 30 seconds; lease lasts 120 seconds; takeover margin is 30 seconds; maximum 5 lock-operation attempts. Stagger/jitter heartbeat scheduling.
- Lease expiration alone is insufficient to protect against a stale server. Stale token/generation writes must be rejected even if the stale server resumes.
- Failed acquisition prevents writable loading. If renewal ultimately fails, stop persistent mutations and disconnect the player. Never report an unconfirmed save as successful.
- Crash or failed release is resolved by lease-based takeover that advances the generation, not by trusting expiration as write authorization.

## Durable character workflows

Cross-key lifecycle operations require a durable account-roster operation record and idempotency keys. Creation uses stable `OperationId` and reserved `CharacterId`. DataStore responses may be uncertain, so retries inspect durable state and never blindly repeat a non-idempotent action.

### Creation

`validate -> account lock -> slot/name recheck -> persist intent (OperationId, CharacterId, CreationIdentity, InitialLocation) -> create or validate profile -> commit roster membership -> complete intent`

`CreationIdentity` contains `Name`, `Race`, and `Class`. The server supplies `InitialLocation` (`RegionId` and `Position`) from world configuration when beginning the operation. Persist the complete intent before profile creation. Recovery of an existing operation uses its persisted `InitialLocation`, never current world configuration; no starting region or default location is specified here. The maximum-three and account-local name uniqueness checks occur while holding the account lock. A repeated operation cannot create a second character or reset an existing profile. Race and class are fixed at committed creation. On interruption, recovery resumes from intent and reconciles profile state; ambiguous records are isolated for administrative review.

### Selection

Before world admission, validate roster entry, profile ownership, schema version, and profile integrity, then acquire the character lock. Missing, corrupt, orphaned, or unknown future-version records are isolated from ordinary loading and saving. Never synthesize an empty profile or automatically delete an orphan.

### Deletion, restoration, and retention

Deletion uses a soft-delete marker/tombstone and durable idempotent steps. Retain deleted data for 30 days; free the active slot only once deletion is successfully committed. Restoration is permitted during that period if an active slot is available and the name is not occupied within the account. Physically delete the profile only after retention expires, through an idempotent workflow. Pending deletion is never selectable. Exact record encoding and retention timestamp representation remain unresolved.

### Recovery and migrations

Recovery is administrative only. Preserve available source data before recovery; log action, reason, timestamp, and outcome. No ordinary load path repairs missing/corrupt data, deletes orphans, or downgrades schema. Refuse unknown future versions. Supported migrations run sequentially, are deterministic/idempotent, and validate each result. Administrative authorization/tooling and source-preservation mechanism remain implementation/operations details.

## Save and retry model

- Autosave every 90 seconds.
- Maintain an independent serialized queue per DataStore key. Only one write may be in flight per key; at most 10 operations may be pending for that key.
- Coalesce ordinary changes into the latest valid snapshot only where safe. Never silently discard critical operations.
- Increment `DirtyGeneration` or equivalent on each persistent mutation. A save can clear only the generation it captured; newer changes remain dirty.
- Every persistent write validates the currently stored session token and lock generation inside the atomic update.
- Retry at most 5 times with bounded backoff and jitter, preserving key order. Invalid payloads and unsupported versions are not ordinary retry cases. Failed calls may have uncertain outcomes; verify state or use idempotent operations.
- Departure and shutdown follow the same fencing rules. Shutdown saving is best-effort and ends at a bounded deadline; the numeric deadline, backoff bounds, jitter distribution, and queue overflow behavior remain unresolved choices, constrained by approved limits.

## DataStore concurrency and limits

Roblox DataStore operations are atomic at one key, not across roster and profile keys. Creation, deletion, and recovery can leave temporary cross-key disagreement and must reconcile through durable idempotent workflows.

`UpdateAsync` callbacks are deterministic, fast, and non-yielding; callbacks may run more than once and must have no external side effects. A failed request may have an uncertain outcome, so do not assume a write did not happen. All locks use a consistent account-first acquisition order. Saves validate token and generation within the atomic update. Lease expiry alone is not a fence.

Respect DataStore budgets, throttling, value/key-size limits, and throughput. Queue and retry design must remain bounded. Verify current platform limits from Roblox Creator documentation when implementing; exact platform capacity values are not architectural constants in this document.

## CORE-02 verification plan

Tests run in a separate test Roblox Experience and isolated test DataStore namespace, never against production data. Test harness/tooling remains unresolved. Required scenarios:

- Competing account sessions and account-first lock order; character-lock failure.
- Lease expiration/takeover, generation advance, stale server writes, and stale heartbeat.
- Heartbeat failure through retry exhaustion, mutation stop, and disconnect.
- Creation and deletion interrupted after every durable stage; crashes during recovery at every stage; idempotent repeat.
- Final-slot creation races and account-local versus cross-account duplicate names.
- Restoration eligibility, occupied name/slot rejection, 30-day retention, and physical deletion after retention.
- DataStore throttling and uncertain write outcomes.
- Corrupt, missing, orphaned, and future-version records remain isolated and unchanged by ordinary paths.
- Per-key ordering, queue overflow at 10 pending operations, safe coalescing, retry exhaustion, and dirty-generation changes during a write.
- Shutdown during pending saves and bounded deadline behavior.
- Sequential migration and administrative restoration/preservation procedures.

## CORE-02 v1.1 acceptance checklist

- [ ] This document and `docs/CORE_SPEC.md` agree on the two stores, exact keys, ownership, slot/name rules, and immutable race/class.
- [ ] Sessions hold both account and selected-character locks in the approved order; only one active session per account.
- [ ] All writes validate unique token and increasing generation atomically; the approved timing/retry values and renewal failure response are enforced.
- [ ] Lifecycle operations use durable idempotent workflows and satisfy creation, selection, deletion, restore, and retention rules.
- [ ] Integrity incidents are isolated, source data preserved where available, and recovery is administrative and logged.
- [ ] Forward migrations are sequential and idempotent; future versions are refused and no automatic downgrade occurs.
- [ ] Per-key queue, autosave, coalescing, dirty-generation, retry, and shutdown constraints are enforced.
- [ ] DataStore cross-key, callback, uncertain-outcome, budget, throttle, and size requirements are addressed.
- [ ] Required failure tests run in isolated non-production Roblox data. Documentation does not count as implementation evidence.

## Approved decisions versus unresolved details

Approved decisions are the normative requirements in this document and `docs/CORE_SPEC.md`: two named stores and key formats; account/character separation; slot/name/race/class rules; dual locks and exact timing/retry values; lifecycle and 30-day retention/restoration; integrity/recovery posture; save cadence and limits; DataStore concurrency requirements; and test scenarios.

Unresolved implementation choices include concrete record field types/bounds and encodings, UUID generation, operation/lock timestamp representation, retry backoff bounds and jitter distribution, safe coalescing criteria, non-silent queue overflow handling for critical work, numeric shutdown deadline, administrative tooling/authorization and source preservation, migration support window, test harness, and platform limits at implementation time. Resolve and document these before the dependent implementation stage; do not change approved behavior implicitly.

## Implementation roadmap

Stages should be small and independently testable. Completion must be demonstrated by implementation and tests, not by this roadmap being documented.

1. **Contracts and keys:** define serialized roster/profile schemas and validation bounds, UUID mechanism, and exact key mapping. Test fixtures and key derivation.
2. **Test isolation and DataStore adapter:** provision separate Experience/namespace; test serialization, isolated writes, callback determinism, budget handling, and one-key queue behavior.
3. **Session locks:** implement account/character acquisition, heartbeat, takeover, fencing, release, and failure response. Test concurrency, expiry, stale writes, renewal failure.
4. **Integrity and schema loading:** implement validation, isolation, forward migrations, and preservation hooks. Test corrupt/missing/orphan/future-version records.
5. **Creation and selection:** build idempotent creation workflow and the selection/admission integrity gate. Test each interruption, name/slot races, invalid profile, and character lock failure.
6. **Save pipeline:** implement 90-second autosaves, per-key queues, safe coalescing, dirty generations, bounded retries and shutdown deadline. Test overflow, throttling, unknown outcomes, and pending shutdown saves.
7. **Deletion, restore, and retention:** implement soft deletion, commit-time slot release, restoration checks, 30-day retention and physical cleanup. Test crashes and repeated operations at each stage.
8. **Administrative recovery and acceptance run:** implement logged/preserved recovery and operational migration/restore procedure. Run all required scenarios in isolation and evaluate both acceptance checklists.

## Security and change control

1. Server owns persistent and gameplay-critical state.
2. Validate every client request, including create/select/delete and gameplay mutations.
3. Never expose DataStore access to LocalScripts or accept client-supplied authoritative profile data.
4. Record data-contract or architecture changes in this document and `docs/CORE_SPEC.md`.
5. Document third-party packages before adding them.
