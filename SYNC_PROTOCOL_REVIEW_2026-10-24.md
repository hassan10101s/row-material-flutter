# Sync protocol review — 2026-10-24

Scope: correct cross-device transport and recovery without changing laboratory calculations, report content, or the existing role matrix. The phone was deliberately left untouched.

Update, 2026-10-25: the user selected server-authoritative final approval with offline drafts, and instructed that legacy local-only data must not be uploaded during migration. The target architecture and cutover gates are specified in `SYNC_ARCHITECTURE_PLAN_2026-10-25.md`. The protocol fixes below describe the existing implementation, not a completed migration to that architecture.

## Changes

- Mutable Firestore writes use a transaction for the read/version check/write. Original `localId`, creator and creation timestamp remain owned by the published record; receiver SQLite IDs never replace them.
- A genuinely missing remote record receives a complete version-1 creation envelope, even when the local copy previously acknowledged a higher version.
- Identical retries after a lost commit response acknowledge the existing version. Different content still follows the existing conflict-resolution policy.
- Append-only writes atomically save a private delivery fingerprint with the business record. A retry can acknowledge that fingerprint without granting audit-read access or overwriting a ledger entry. Receipt writes are immutable, user-private and contain no result values.
- Tombstones use the same optimistic write path. Server rules and client policy refuse resurrection through a normal update.
- Settlement remains conditional on the claimed outbox revision. A late response cannot delete a newer queued edit. Successful delivery resolves the corresponding previous push rejection and aligns transport versions.
- Old envelope permission failures are reconsidered once. Real permission failures remain visible; the upgrade does not grant roles or bypass server checks.
- Operational sample links use the product header's shared identity/entry code. Local integer IDs are remapped on the receiving device. Legacy origin-device recovery requires one unique matching product header, never a guessed match with a raw-material inspection.
- Server writes require an active owned writing device. Revoked, foreign and read-only devices are rejected. A non-admin member cannot turn off its own read-only restriction. Cached restrictive device flags remain restrictive.
- Custom quality-table audit actions now match the server allow-list. A parity test checks every emitted action.

## Validation

- Firestore/Auth emulators use only `demo-materiallab`; no test records were written to the real project.
- The final security/recovery gate passed 83 tests, including atomic append plus receipt for a laboratory role without audit-read permission, tombstone protection and read-only restriction enforcement.
- Rules were reviewed and deployed successfully to the previously approved staging project `materiallab-63405`.
- The full project suite passed 1543 tests (46 emulator-dependent skips, covered separately). Static analysis reported no issues. Android and Windows debug builds succeeded at that checkpoint.
- Subsequently, two narrowly scoped sample fixes prevent reuse of deleted sample numbers and replacement of a different sample on a unique-key collision; new samples are also refused under deleted product headers. The related 34 tests passed and targeted static analysis reported no issues. Those latest source changes were not rebuilt into the earlier debug binaries.

## Operational limits

No implementation can guarantee zero future failures or simultaneous edits forever. Real authorization denials, ambiguous legacy parents, oversized records, unavailable networks and conflicting business changes must remain observable rather than being discarded to produce a green badge. Existing row-level race resolution remains in use; this is not a new field-by-field business merge policy.

The corrected clients must be used on the participating devices. A new phone installation can retrieve only data that reached the server; clearing local data does not upload pending edits. This review does not claim a fresh physical-phone end-to-end test, because phone interaction was explicitly excluded.

Private diagnostic files and logs are under the ignored `.dart_tool/` directory. No passwords, Firebase tokens or laboratory results are included in this document.
