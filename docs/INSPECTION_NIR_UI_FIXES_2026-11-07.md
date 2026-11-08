# Inspection editing and NIR refresh follow-up

## Corrected behavior

- Inspection editing restores the stored material/product identity, entry code, reference snapshot and results directly. It does not depend on a fresh catalogue selection, including archived/unavailable catalogue rows. The identity is read-only during editing, matching the repository's existing update contract.
- Desktop and mobile now render the same `InspectionFormSections` and use the same controllers, validation and save callback. Mobile retains its stepped navigation. Result grids choose vertical cards at narrow widths instead of forcing a 780px horizontal canvas.
- Refreshing a new inspection's entry code no longer rebuilds or clears entered results. Only a changed reference revision rebuilds the grids; forms also support selection loaded before their widget listeners attach.
- Mobile entry and detail cards distinguish the analysis title, result field/value and smaller reference range below it. Compact physical fields combine suggestion actions into one menu to leave space for the value.
- NIR refresh computes settings and statistics from the repository's read snapshot. Overlapping loads ignore obsolete successes and failures; a report without settings clears the previous settings.
- The global widget error builder renders a bounded local fallback. It must never place a second MaterialApp/Navigator inside an arbitrary failed widget: in a sliver this produced the infinite-height and repeated layout assertions in the supplied log. Startup errors still use the separate full-screen startup view.

## Evidence and limits

The supplied log begins in a cascade, without the first exception. It establishes the invalid nested navigator/layout, but cannot identify the initial failed widget. The regression suite injects a build failure into the same unbounded sliver position and checks that only the original exception occurs, layout stays finite and adjacent content remains visible.

`build/inspection_ui_tests.log`: 69 passing focused tests. Coverage includes unavailable catalogue during mobile edit, preservation of the saved material/code/results, widths 320/390/760, reference below the input, overlapping NIR refreshes, and NIR loading/empty/error/restored transitions. No Firestore rule changes or deployments are required for these UI fixes.

`build/inspection_ui_analyze.log`: full Flutter analysis, no issues. `build/inspection_ui_final_analyze.log`: the final entry-code preservation change and its regression test, no issues.

`build/inspection_ui_full_tests.log`: 1990 passed, 85 emulator-tagged tests skipped as configured; no failures. `build/inspection_ui_final_tests.log`: all 7 inspection edit/create regressions passed after the final code-refresh fix.

Android release build succeeded using the existing `ven/firebase-android.json` configuration. Artifact: `output/MaterialLab-Android-20261107-Inspection-NIR-Fix.apk` (106247513 bytes). Build log: `build/inspection_nir_android_build.log`. Physical-device verification was not performed in this session.

`apksigner verify --verbose` passed with one signer and APK Signature Scheme v2. SHA256: `5ae78759c22a9a3ba465b5470a87dbdee295529f2425cd0f0bb2bde48641bf8c`.
