# Core Prototype — Technical Specification v1.1 (CORE-02)

## 1. Status and scope

This document records approved CORE-02 architecture decisions and requirements. It is a specification, not evidence that any requirement is implemented. Section 10 separates approved acceptance criteria from unresolved implementation choices. Implementation must proceed in small, independently testable stages.

- Genre: high-fantasy MMORPG / Action RPG with supplementary roleplay.
- Platform for prototype: PC; third-person camera.
- One continuous world in one Roblox Place. Regions are physical travel, not teleport transfers.
- Death does not permanently remove characters, inventory, or progression.
- The server is authoritative over critical gameplay and persistent data. Clients may display state and request actions, but cannot write persistent state.

## 2. Persistence model and data contracts

Use exactly two DataStore names:

| DataStore | Record and key | Authority |
|---|---|---|
| `Aetheria_AccountRoster_v1` | One roster per Roblox account, key `User_<UserId>` | Account membership, character slots, lifecycle workflow state and account lock/fencing state |
| `Aetheria_CharacterProfiles_v1` | One profile per character, key `Character_<UUID>` | That character's persistent gameplay state and character lock/fencing state |

There is exactly one account roster record per Roblox account and one separate profile record per character. An account may have at most three active characters. Character names are unique within an account; the same name may be used by another account. Race and class become immutable when character creation is committed.

The roster is authoritative for account-to-character membership and slot count. Roster entries may cache display summaries; cached data is not authoritative gameplay state. The profile is authoritative for its character. `activeCharacterId` is session state unless a future decision adds a validated last-selected preference.

The logical roster fields include independent schema version, revision/generation, up to three active character entries, durable lifecycle operation state, and account lock ownership/fencing state. The logical profile fields include schema version, character ID, name, immutable race and class IDs, level/experience, attributes, inventory, equipment, location, timestamps, and character lock ownership/fencing state. Exact field bounds, summary contents, UUID generation procedure, lock encoding, and operation encodings beyond the approved creation intent below remain unresolved implementation details. Values must be serializable; do not persist Instances, userdata, functions, or cyclic tables. Validate all loaded records before use.

## 3. Session locking and authority

- Acquire the account lock first, then the selected-character lock. Hold both throughout the gameplay session. Release in reverse order after final save. Any operation touching both keys uses this same order.
- One Roblox account may have only one active gameplay session at a time, including across servers.
- Each session uses a unique `SessionToken` and monotonically increasing `LockGeneration`. Every persistent write validates current token ownership and fencing generation atomically inside the key update. A stale server must never overwrite data owned by a newer session.
- Schema validation checks lock field types and ranges only. Semantic validation of token/lease combinations is deferred until the session-lock implementation defines and approves the persisted lock representation. This does not alter the approved lock protocol or fencing requirements.
- Heartbeat interval: 30 seconds. Lease duration: 120 seconds. Takeover margin: 30 seconds. Maximum retry attempts for lock operations: 5. Heartbeats should be staggered/jittered to avoid synchronized request bursts.
- Lease expiration alone does not authorize writes or safely fence an old owner. Takeover must atomically advance the generation; every write checks token and generation.
- If acquisition fails, do not admit the player to writable gameplay. If renewal ultimately fails, stop persistent mutations and disconnect the player. A failed save is never reported as successful.
- Lock release is conditional on current ownership and follows final-save handling. A crash or failed release can leave a lease to expire; a later owner takes over only through generation-fenced acquisition.

## 4. Character lifecycle

Creation, deletion, and recovery span separate keys and therefore use durable, idempotent workflows. Every lifecycle operation has a stable `OperationId`; creation also reserves and reuses a stable `CharacterId`. An uncertain DataStore response must not cause duplicate operations or blind replacement.

### Creation

1. Validate the request and acquire the account lock; recheck the slot limit and account-local name uniqueness while holding it.
2. Build a creation intent with `OperationId`, reserved `CharacterId`, `CreationIdentity` (`Name`, `Race`, `Class`), and `InitialLocation` (`RegionId` and `Position`). The server supplies `InitialLocation` from world configuration. Persist the complete intent in the roster before profile creation begins; do not default or hard-code a starting location.
3. Create or validate the profile under `Character_<UUID>` without resetting existing data.
4. Commit roster membership and clear/complete the intent only after profile validity is confirmed.
5. On interruption, inspect durable intent and profile state and idempotently resume or complete. When reconstructing a profile for an existing operation, use that operation's persisted `InitialLocation`; never re-read current world configuration. Preserve ambiguous data and isolate it for administrative review rather than discarding it.

Race and class are fixed by the committed creation data and cannot be changed by later gameplay requests.

### Selection

Before entering the world, selection validates roster membership and entry integrity, profile existence and ownership, schema version, profile integrity, and successful selected-character lock acquisition. Missing, corrupt, orphaned, or future-version records are isolated from normal load/save. They are never replaced with an empty profile, and orphan profiles are never automatically deleted.

### Deletion and restoration

- Deletion is soft deletion. Persist an idempotent deletion intent/tombstone, then mark the profile deleted and finalize roster state using durable steps.
- Retain deleted character data for 30 days. Free the active slot only after deletion is successfully committed.
- Restoration is allowed during that retention period if an active slot is available and the name is not occupied by another active character in the same account. Recovery is idempotent.
- Physically delete the profile after the retention period through an idempotent workflow. Do not expose a pending-deletion character for selection.
- The precise durable marker layout and how the retention clock is represented are unresolved implementation details.

## 5. Data integrity, recovery, and migrations

- Never replace a missing or corrupt profile with an empty profile automatically. Never automatically delete orphaned profiles.
- Isolate problematic records from normal loading and saving. Preserve available original data before any recovery action.
- Recovery is an administrative operation only. Log action, reason, timestamp, and outcome. Do not perform automatic repairs during ordinary player loading.
- Never automatically downgrade a schema. Refuse to load records with unknown future schema versions.
- Support sequential, idempotent forward migrations. Validate after each migration step and after the final transformation. Preserve the original value or an available version before a recovery/migration operation that could alter it.
- Exact administrative tooling, authorization model, backup/export procedure, and migration support window remain implementation/operations details.

## 6. Saving, queues, and shutdown

- Autosave interval: 90 seconds. Use a separate save queue per DataStore key, with only one in-flight write per key and at most 10 pending operations per key.
- Coalesce ordinary state changes into the latest valid snapshot when safe. Never silently discard critical lifecycle, lock, or recovery operations.
- Track `DirtyGeneration` or an equivalent monotonically increasing revision. A successful older snapshot may mark only its captured generation saved; changes made during the write remain dirty.
- Save/update operations validate `SessionToken` and `LockGeneration` inside the atomic update.
- Retry transient failures at most 5 times using bounded backoff and jitter while preserving per-key order. Invalid records and unsupported schemas are not retryable as ordinary saves. Failed requests can have uncertain outcomes; verify or safely retry through idempotent operations.
- Departure and shutdown saves use the same fencing and queue rules. Shutdown saving is best-effort with a bounded deadline; the deadline value is an unresolved implementation detail.

## 7. Roblox DataStore and concurrency requirements

DataStore updates are atomic per key; cross-key operations are not transactional. Creation, deletion, and recovery therefore require durable, idempotent workflows that reconcile temporary disagreement between roster and profile.

`UpdateAsync` callbacks must be deterministic, fast, and non-yielding because they may be invoked more than once. They must not perform external side effects. A failed request may have an uncertain outcome; do not assume that the write did not happen. Lock acquisition and release follow the account-then-character order (release in reverse). Saves validate the current session token and generation inside the atomic update. Lease expiry alone is not stale-writer protection.

Respect DataStore budgets, throttling, key/value size limits, and throughput limits. Queueing and retry behavior must not create unbounded pressure. Consult current Roblox Creator documentation at implementation time and monitor actual budgets rather than hard-coding assumptions about platform capacity.

## 8. Testing requirements

Use a separate test Roblox Experience and an isolated test DataStore namespace. Never test against production player data. The test harness/tooling is unresolved; the scenarios are required:

- Concurrent sessions competing for one account; only one becomes active.
- Lock expiration and takeover, generation advance, and stale server writes/heartbeats after takeover.
- Heartbeat/renewal failure, eventual retry exhaustion, mutation stop, and player disconnect.
- Account lock succeeds but character lock fails; gameplay does not begin and release/recovery remains safe.
- Interrupted creation and deletion after every durable workflow stage, including uncertain responses.
- Recovery after server crashes at every workflow stage, including restore and physical deletion.
- DataStore throttling and uncertain write outcomes.
- Corrupt, missing, orphaned, and unknown future-version records; verify isolation and no automatic replacement/deletion.
- Per-key queue overflow, ordering, coalescing, retry exhaustion, and dirty-generation changes during an in-flight save.
- Shutdown while saves are pending and bounded-deadline behavior.
- Forward migration and administrative restoration procedures, including idempotent repeated execution.
- Concurrent creation racing for the final slot and duplicate names within one account versus across accounts.

## 9. CORE-02 v1.1 acceptance checklist

- [ ] Exactly the two approved DataStore names and key formats are used, with one roster per account and one profile per character.
- [ ] Three active character maximum and account-local name uniqueness are enforced; race/class are immutable after creation.
- [ ] Server authority and account-first, character-second dual locking are enforced for the full session.
- [ ] Unique session tokens, increasing fencing generations, 30-second heartbeat, 120-second lease, 30-second takeover margin, and five lock-operation attempts are honored.
- [ ] All persistent writes atomically validate token and generation; renewal failure stops mutations and disconnects.
- [ ] Creation, selection, soft deletion, restoration, and retention cleanup satisfy the durable/idempotent rules and 30-day retention.
- [ ] Corrupt/missing/orphan/future-schema data is isolated; recovery is administrative, preserves available source data, and is logged.
- [ ] Forward migrations are sequential and idempotent; no automatic downgrade occurs.
- [ ] Autosave is 90 seconds; each key has one in-flight write, no more than 10 pending operations, bounded five-attempt retry, and correct dirty-generation tracking.
- [ ] Critical operations are not silently discarded; shutdown saving has a bounded deadline.
- [ ] DataStore cross-key limits, callback behavior, uncertain outcomes, budgets, throttling, and size limits are handled as specified.
- [ ] Required tests run in a separate Experience and isolated namespace; passing documentation review alone does not satisfy implementation acceptance.

## 10. Approved decisions and unresolved implementation details

**Approved:** all normative values and behaviors in Sections 1–9, including store/key names, slot/name rules, lock timing and retries, lifecycle retention/restoration, recovery posture, save queue limits, and required test coverage.

**Unresolved:** serialized record field types and nested bounds; UUID generation mechanism; exact lifecycle state representation; lock timestamp/clock representation; retry delay/backoff bounds and jitter distribution; queue overflow handling beyond never silently dropping critical operations; bounded shutdown deadline value; coalescing eligibility rules; administrative access/tooling and source-preservation mechanism; operational migration window; test harness/tool choice; current platform budget/size values at implementation time. These choices must be documented and tested before relying on them; they must not contradict approved requirements.

## 11. Implementation roadmap

Each stage is independently testable. Documentation approval does not imply any stage is implemented.

1. **Record contracts and key mapping:** define typed roster/profile shapes, validation bounds, UUID and serialization decisions; test valid/invalid fixtures and exact key mapping.
2. **DataStore adapter and isolated test setup:** create the separate test Experience/namespace and per-key queue shell; test key isolation, serialization, budgets, and deterministic non-yielding update transforms.
3. **Lock protocol:** implement acquisition, renewal, takeover, release, token/generation fencing and failure behavior; test concurrent accounts, expiration, stale writes, and heartbeat failure.
4. **Roster loading and integrity gate:** implement schema detection, validation, isolation and forward migration; test corrupt, missing, orphaned, and future-version cases without ordinary auto-repair.
5. **Character creation:** implement operation intent, profile creation, roster commit and retry/recovery; test crashes and uncertain outcomes after each step, capacity and name races.
6. **Selection and session admission:** enforce roster/profile/schema/integrity checks and both locks before world entry; test lock failure and invalid records.
7. **Save pipeline:** implement 90-second autosave, per-key queues, coalescing, dirty generations, bounded retry and shutdown deadline; test queue pressure, retry exhaustion and shutdown.
8. **Deletion, restoration, and retention cleanup:** implement soft delete, slot release on commit, restoration checks, 30-day retention and physical cleanup; test interruption at each step and repeated operations.
9. **Administrative recovery and release verification:** implement authorized, logged preservation/recovery and migration procedures; test restore, migration, and crash recovery stages, then evaluate the acceptance checklist in the isolated Experience.

## 12. Death and out of scope

- Death triggers normal character respawn. No slot, experience, level, inventory, or equipment is removed. Temporary combat state may reset under later combat design.
- Full combat, spells, quests/narrative, player housing, guild politics/government, auction house/advanced economy, final lore, and final map art are out of scope for this core prototype.
