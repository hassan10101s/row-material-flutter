$ErrorActionPreference = 'Stop'
# This entry point is only for firebase emulators:exec, never a live project.
if ($env:GCLOUD_PROJECT -ne 'demo-materiallab' -or
    $env:FIRESTORE_EMULATOR_HOST -notmatch '^127\.0\.0\.1:\d+$' -or
    $env:FIREBASE_AUTH_EMULATOR_HOST -notmatch '^127\.0\.0\.1:\d+$') {
  throw 'Security tests require demo-materiallab localhost emulators.'
}
flutter test --no-pub test/security --reporter expanded
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
node --test tool/central_migration/test/*.test.js
exit $LASTEXITCODE
