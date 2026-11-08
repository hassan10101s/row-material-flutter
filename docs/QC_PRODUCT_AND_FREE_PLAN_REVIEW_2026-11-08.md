# QC, product references and free-plan review — 2026-11-08

Status: implemented, tested, and verified deployed on 2026-11-09 (Cairo).
The active production ruleset is `ee858067-8cd9-41af-89df-f882087c3dce`, compact
SHA256 `fbaaad23c3ef6a8457341d75bea66b8353ac02f3d650dc075aed01fd825ae8c0`.
It supersedes `a838beb7-e069-4f2b-a3cd-7204c1c76a11`. Final evidence is in
`RELEASE_EVIDENCE_2026-11-09.json` and `FINAL_FIREBASE_REVIEW_2026-11-08.md`.

## Observed failures

The user-authorized, read-only inspection of the application SQLite cache found
that QC operation `40bddb6a-d2b8-4890-8c41-eba9ba0965a1` opened a period sheet;
it was not a template creation. Empty approval/rejection timestamps were treated
as decision signals, and additional paths reached the 1,000-expression ceiling.

The latest unsent protein draft included HCl plus two other inventory items:
one result and four effects per chemical (consumption, duplicate inventory
transaction, lot update, item update), for 13 business effects. Removing display
labels such as `reason` or `lotNo` cannot fix that document/access-call budget.
No user draft or business record was modified or submitted during inspection.

## Reviewed changes

* New lab-result operations use immutable consumption as their movement ledger
  (`protocol.ledgerMode = consumption_v1`). They do not author a duplicate
  `inventoryTransaction`. The approved local projection derives the history
  view with stable `derived_consumption_v1_...` IDs. Bootstrap and replay must
  reconstruct this view without writing back to Firestore. That ID prefix is
  reserved against shared inventory-transaction creates.
* Stock totals and individual lot deltas are still independently checked by
  Firestore Rules, using the same atomic consumption set and receipt. The
  change is not permission to omit lot updates, split operations or save an
  unconfirmed result. Existing explicit-ledger records remain readable.
* Origin SQLite foreign keys and the second lot-id stamp are omitted from the
  new consumption wire image; typed global `parentRefs` remain authoritative.
* Product-range upserts use null-safe comparisons before updating. Unchanged
  product-analysis relationships retain their identity and consume no effects.
  Identical product fields are not rewritten. A scoped candidate extension
  admits one existing product and up to six existing range updates, with the
  same product parent and unchanged uniqueness identities; unrelated/mixed
  operations do not inherit this capacity.
* An unchanged, valid unique reservation is not rewritten. The transport still
  reads/checks it; create, rename and release operations keep their reservations.
* QC period opening stores a header and audit only. Unanswered rows are rendered
  from the template; first interaction creates the response. History totals and
  completion/item filters include unanswered items. Non-routine inspection
  callers keep their existing initialization default.
* Empty decision metadata does not request approval/rejection. Real decisions
  retain their role and actor checks. QC primitive schema checks are distributed
  across the source and its same-transaction event; no field checks are removed.
* Quality list/history/NCR rows use compact mobile rendering, with accessible
  action targets. Routine/custom-table editors and SOP detail use shared app
  surfaces. Mobile SOP totals use an inline summary; desktop presentation keeps
  desktop chrome. Font scaling and both directions are covered by widget tests.
* Automatic foreground refresh defaults to 30 seconds, as explicitly requested
  by the user during final review, with immediate manual
  refresh and post-save receipt/projection processing unchanged. The existing
  reader checks the head before downloading changed records. Reconnect/resume
  never sends business drafts automatically.

## Limits and validation

Firestore's per-write and whole-transaction rules budgets still apply. Native
transactions, immutable operation IDs, expected versions, roles, registered
devices, secure-field rules and server receipts remain required. Free-plan
daily quotas are separate from these structural rule limits; paying would not
remove the 20-access/10-access/1,000-expression rules constraints.

The three-chemical case, reversal, tamper rejection, replay and clean-cache
downloads passed emulator verification. Final validation passed 2,139 general
tests (93 skipped), 135 Flutter security tests and 34 Node contract/migration
tests; static analysis had zero issues. The final follow-up also proved twelve
simple effects with one atomic proof, six unique catalogue creates, and 36 packed
chemical definitions within the reference budget. No application binary was built.

The exact deployed artifact compiled to 255,781/256,000 bytes. Staging was
explicitly waived by the user for this batch; active-release name, source hash
and executable identity/size were read back after activation. Rules API 503
responses were reconciled with actual state and were never treated as success.
