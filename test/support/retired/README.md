# Retired send engines — test fixtures only

These sources preserve historical protocol, backup and serialization regression
coverage. They are outside `lib` and must never be imported by production code.
`test/architecture/direct_write_policy_test.dart` enforces that boundary.

Production business writes use `DirectWriteService` on explicit user actions.
Startup, resume and reconnect only refresh reads and look up existing receipts.
Historical tests exercising auto-retry here do not describe the current app policy.
