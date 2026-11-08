# Formulation parameters and shared NIR inclusion

## User decisions

- Do not create another application build.
- NIR Yes/No selection is shared between all devices and users, rather than a local view preference.

## Formulation chart

Analysis settings opens a searchable multi-select surface on desktop and mobile. It reloads the existing analysis catalogue on opening, includes chemical keys already present in historical readings even without a catalogue definition, and preserves the current selection. Analyses without complete points remain selectable with an explicit explanation. Applying refreshes source reads; cancelling keeps the prior set. Selection is stored with the graph's existing local view preferences, independently of business saves. Completed preference writes release the pending queue so later sessions do not retain a completed asynchronous context.

## NIR calibration

- Every matched pair has Yes/No controls. No preserves the visible source row but excludes it from all numeric summaries, fits, scatter points, reliability and correction advice. Yes restores it.
- Selection is calibration-only metadata on the existing lab-result document (`nir_exclusions_json` / `nirExclusionsJson`), requiring the existing `lab_results.update` permission. One toggle is one business effect. No source measurement, test date, chemical consumption, stock balance or horizon changes.
- A selection key contains global inspection and optional product-sample identities plus normalized parameter/sample names. A lab reference shared by multiple product samples can exclude one pair independently. Foreign device SQLite ids are never used to match selection keys.
- The repository revalidates the current pair, reference identity/version and values inside the captured business transaction. Stale screens must refresh rather than overwrite another selection.
- The UI waits for the verified server result before changing the displayed switch or calculations. Drafts keep the approved calculation and require manual review/submission; no automatic sending was introduced.
- Selection changes append actor/point metadata to the audit trail. New reset snapshots also retain the excluded count and global reading/reference identities; existing snapshots remain immutable.
- A new/replacement laboratory reference starts with its own selection state. A No on the current reference does not resurrect an older reference as a substitute.
- Null exclusion metadata is omitted when serializing legacy rows. Rules preserve an established selection field against erasure, limit its size, and keep all existing role, version, receipt and atomicity checks.

## Verification

- `build/formulation_parameter_tests.log`: 47 passing formulation/design-system tests, including search, fresh catalogue, cancel, valid chart values and retained local selection on desktop/mobile.
- `build/nir_selection_tests.log`: 49 passing NIR/UI/math/schema tests, including waiting for approval, No/Yes restoration, stale writes, source preservation, independent product samples and reset evidence.
- `build/nir_selection_integration_tests.log`: 247 passing repository/command/architecture/formulation tests. Includes wire decoding onto different inspection/result ids on a second device.
- `build/nir_selection_security.log`: all 127 Firestore/Auth emulator tests passed against `demo-materiallab` only. The Firebase CLI subsequently reported an error during emulator shutdown after explicitly recording script exit code 0; the test run itself passed.
- Security coverage includes one-effect calibration metadata updates on a result with two chemical deductions, idempotent replay, stale-version rejection, rejection of marker erasure, and unchanged inventory balances.
- `build/nir_selection_rules_diff.json`: compared with the actual published rules source after undoing function aliases. Only `shape_labResult` changes; all other functions and code outside functions are identical.
- Candidate source SHA256: `1199c35dd7651def6fc81f18d6ffd37aae731ce20b42e467ee7db7b1bf5764c8`. Compact source SHA256: `2576b2d834c810698ee2a22aeb89cebdf56de5413f5d1100526116480a38c645`.

No application build was created for these changes. Deployment status must be established from a verified release read-back, never inferred from a deployment attempt.

Deployment verified by a read-only GET of the exact release and its source: `projects/materiallab-63405/rulesets/5d258d69-2051-427b-855d-93c10602a676`, published SHA256 `2576b2d834c810698ee2a22aeb89cebdf56de5413f5d1100526116480a38c645`. Google returned 503 on creation and activation after performing both. The existing prepared ruleset was located by its exact source hash before activation; activation was not resubmitted after the successful read-back. Evidence: `build/nir_selection_live_after.log`, `build/nir_selection_live_after.json`, and `build/nir_selection_rules_diff.json`. `build/nir_selection_final_analyze.log`: complete lib/test analysis, no issues.
