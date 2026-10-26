import 'dart:async';

/// Invalidates read models only after a remote batch has committed. Forms opt
/// out so a sync never discards a user's unsaved input.
abstract final class SyncDataChanges {
  static final _controller = StreamController<void>.broadcast();
  static Stream<void> get stream => _controller.stream;
  static void notify() => _controller.add(null);
}
