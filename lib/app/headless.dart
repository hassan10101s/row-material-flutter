/// True inside a workmanager background isolate (no UI).
///
/// Set by the background dispatcher before bootstrapping so per-organization
/// side effects can skip foreground-only work (file backups, scheduler
/// re-registration, refresh timers). Lives in its own leaf file so the app,
/// service-locator and dispatcher layers can all read it without import
/// cycles.
bool isHeadlessBackground = false;
