import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import '../sync/sync_data_changes.dart';

/// Base cubit exposing [safeEmit], which ignores emissions after the cubit
/// has been closed (e.g. a screen was popped while an async repo call was
/// still in flight).
abstract class AppCubit<State> extends Cubit<State> {
  AppCubit(super.state);
  StreamSubscription<void>? _syncChanges;
  bool _syncRefreshing = false;
  bool _syncDirty = false;

  /// Register only read models, never a form with unsaved fields.
  void refreshOnSync(Future<void> Function() refresh) {
    _syncChanges = SyncDataChanges.stream.listen((_) async {
      _syncDirty = true;
      if (isClosed || _syncRefreshing) return;
      _syncRefreshing = true;
      try {
        while (_syncDirty && !isClosed) {
          _syncDirty = false;
          await refresh();
        }
      } catch (error, trace) {
        if (!isClosed) addError(error, trace);
      } finally {
        _syncRefreshing = false;
      }
    });
  }

  @override
  Future<void> close() async {
    await _syncChanges?.cancel();
    return super.close();
  }

  void safeEmit(State state) {
    if (!isClosed) emit(state);
  }
}
