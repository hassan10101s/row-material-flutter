import 'dart:async';

/// Invalidates read models only after a remote batch has committed. Forms opt
/// out so a sync never discards a user's unsaved input.
abstract final class SyncDataChanges {
  static final _controller = StreamController<void>.broadcast();
  static final _statusController = StreamController<void>.broadcast();
  static Stream<void> get stream => _controller.stream;
  /// Status updates must not reload business forms or trigger remote reads.
  static Stream<void> get statusStream => _statusController.stream;
  static void notifyStatus() => _statusController.add(null);
  static void notify() => _controller.add(null);
}
