/// Running the periodic backup on a schedule.
///
/// ## Why this is a port
///
/// `BackupManager.autoBackup()` runs **once**, when an organization is bound.
/// That is enough on Windows, where the app is normally left running. It is not
/// enough on Android: the OS kills a backgrounded process without warning, so a
/// device that is locked in a pocket takes **no backups at all** until it is
/// opened again. That is silent data loss, and it is the single most important
/// platform gap in the app.
///
/// The fix is platform-specific (a background task on Android, nothing on
/// desktop), so it is a port with two implementations and a no-op default.
///
/// The Android implementation lives in `lib/app/auto_backup_task.dart` rather
/// than beside this file: workmanager's dispatcher runs in a **separate
/// isolate** that never executed `main()`, so it has to re-bootstrap before it
/// can resolve anything from `getIt`. Reaching up into the app layer from
/// `core/` to do that would invert the dependency direction, so the port
/// declares the capability here and the adapter lives where the bootstrap is
/// visible.
abstract interface class AutoBackupScheduler {
  /// Whether periodic backups actually run on this platform.
  ///
  /// Screens use this to tell the truth in the UI: a device that reports
  /// `true` can say when its last automatic backup ran, and one that reports
  /// `false` must not imply it ever will.
  bool get isScheduled;

  /// Registers the recurring backup. Safe to call more than once.
  Future<void> schedule();

  /// Cancels the recurring backup.
  Future<void> cancel();
}

/// Desktop: nothing to register. The app is assumed to be running, and
/// `BackupManager.autoBackup()` at organization bind time is the safety net.
class NoopBackupScheduler implements AutoBackupScheduler {
  const NoopBackupScheduler();

  @override
  bool get isScheduled => false;

  @override
  Future<void> schedule() async {}

  @override
  Future<void> cancel() async {}
}
