# V1 acceptance checklist — §42

Manual acceptance matrix for the offline-first + Firebase port
(`PLAN_V2_ORG_FIREBASE_OFFLINE_FIRST.md`).

Every row states **what is verified**, **how** (automated test file or manual
procedure), and leaves **result / timestamp / device / account** for the person
who ran it. An automated row is green only when the named test passes; a manual
row is green only when the procedure was executed end to end.

> The V2 plan references the original plan's `§42` items (1‑10) without
> reproducing their text. The wording below is reconstructed from those
> references (§14‑P3, §14‑P4, §14‑P7, §14‑P8). Items **3, 4 and 7** are marked
> *reconstructed* — confirm them against the original plan before signing the
> matrix off.

## Environment to record

| Item | Value |
| --- | --- |
| Date / tester | |
| Build (`flutter --version`, git rev) | |
| Platform(s) used | |
| Firebase project (staging) | `demo-materiallab` |
| Rules deployed (staging) | ☐ `firebase deploy --only firestore:rules` |
| Emulator suite run | [X] `firebase emulators:exec --only firestore,auth --project demo-materiallab "flutter test test/security"` |
| `flutter analyze` | [X] 0 issues |
| `flutter test` | [X] all green (270 passed, 12 skipped) |

Accounts used (email → role):

| Email | Role | Device id |
| --- | --- | --- |
|  | owner / admin | |
|  |  |  |
|  |  |  |

## The matrix

| §42 | Scenario | Verified by | How | Result | Timestamp | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | First Google account ⇒ organization created, user becomes its `admin` | manual | Sign in with an account that has no `users/{uid}`. Expect the *create organization* screen, create it, land on the dashboard as admin with the full permission set. Check `users/{uid}.role = admin` and that `organizations/{orgId}` is new. | ☐ pass ☐ fail | | |
| 2 | Add an employee (invite) | manual | *Settings → Members → Add* with the employee email + role. Expect the member to appear as `invited` and the instructions text to state the employee signs in with the same email. | ☐ pass ☐ fail | | |
| 3 | Employee signs in ⇒ "waiting for activation" *(reconstructed)* | manual | Sign in on a second device with the invited email. Expect the *waiting for activation* screen, no data. | ☐ pass ☐ fail | | |
| 4 | Activation ⇒ the employee gets in with exactly the role matrix *(reconstructed)* | manual + automated | *Members → Activate*. Expect the employee to reach the dashboard; the write affordances must match the role matrix (`test/security/permissions_parity_test.dart`, `test/security/read_only_device_test.dart`). | ☐ pass ☐ fail | | |
| 5 | A `viewer` cannot create or edit anything | automated | `test/security/firestore_rules_test.dart` ("closed to viewers") + `test/security/read_only_device_test.dart` (route guard + no write affordance) + `test/sync/two_device_test.dart` (write refused). | [X] pass | 2026-09-26 | emulator run |
| 6 | Internet OFF ⇒ an inspection is created, appears instantly, and syncs when the network returns | automated | `test/sync/offline_roundtrip_test.dart` — "§42-6/7 offline create is visible at once and syncs when back online". | [X] pass | 2026-09-26 | `flutter test` |
| 7 | A deletion made offline replicates as a tombstone *(reconstructed)* | automated | `test/sync/offline_roundtrip_test.dart` — "§42-6 a tombstone made offline replicates once the network returns". | [X] pass | 2026-09-26 | `flutter test` |
| 8 | A change made on device 1 shows up on device 2 | automated | `test/sync/two_device_test.dart` — "§42-8 a sample created offline on device 1 shows up on device 2" and "§42-9 an edit made offline on device 1 reaches device 2, both ways". | [X] pass | 2026-09-26 | `flutter test` |
| 9 | Device 2 offline still shows the last synced data | automated | `test/sync/two_device_test.dart` — a pulled row stays readable with `offline = true`; the badge reads *Offline* (`test/features/sync/sync_badge_test.dart`). | [X] pass | 2026-09-26 | `flutter test` |
| 10 | A member of another organization reads/writes nothing | automated | `test/security/firestore_rules_test.dart` — cross-organization isolation, forged `organizationId`, path juggling. | [X] pass | 2026-09-26 | emulator run |

## Additional gates of the same release

| Gate | Verified by | How | Result | Timestamp |
| --- | --- | --- | --- | --- |
| No write leaves a transaction without a queue + audit row | automated | `test/sync/atomicity_test.dart` (rollback on queue/audit/QC failure) | [X] pass | 2026-09-26 |
| Append-only audit trail, attributed to the live session | automated | `test/sync/audit_logger_test.dart` + `test/sync/device_audit_test.dart` | [X] pass | 2026-09-26 |
| The audit trail of device 1 is readable on device 2, with filters | automated | `test/sync/device_audit_test.dart` ("a second device sees the trail of the first one") + `test/features/audit/audit_screen_test.dart` | [X] pass | 2026-09-26 |
| Audit retention: only server-confirmed rows are pruned | automated | `test/sync/device_audit_test.dart` (retention group) | [X] pass | 2026-09-26 |
| Device registry + "sign out of this device only" keeps the member active | automated | `test/sync/device_audit_test.dart` (device registry group) | [X] pass | 2026-09-26 |
| Lab result written offline reaches the other device | manual | Write a sample test result offline on device 1, sync, read it on device 2. | ☐ pass ☐ fail | |
| QC approval requires the network (online-only) | automated | `test/sync/atomicity_test.dart` + `test/sync/two_device_test.dart` (offline QC refusal) | [X] pass | 2026-09-26 |
| Backup + restore + `reconcileAfterRestore()` | automated | `test/backup/backup_manager_test.dart` (export/validate/restore) + `test/backup/restore_sync_test.dart` (P11.2: the next write lands in the restored file, an orphaned queue entry becomes a conflict, the restored device id is replaced) | [X] pass | 2026-09-26 |
| `integrity_check = ok` on the restored database | automated | `test/backup/restore_sync_test.dart` ("a restore of an old backup keeps the schema") | [X] pass | 2026-09-26 |
| Release build | automated | `flutter build windows --release` → `build/windows/x64/runner/Release/material_lab.exe` (15.2 MB, 12 bundled files). Required updating VS 2022 to 17.14 / MSVC 14.44 — see `tool/firebase/README.md` §7. | [X] pass | 2026-09-27 |

## Sign-off

- [ ] All ten §42 rows recorded with a result and a timestamp.
- [ ] The manual rows were executed on a real build, not only in tests.
- [ ] Staging deploy verified, production deploy still pending (needs credentials).
- [ ] Known failures listed in `Notes` with a follow-up owner.
