import 'package:flutter_bloc/flutter_bloc.dart';

/// Base cubit exposing [safeEmit], which ignores emissions after the cubit
/// has been closed (e.g. a screen was popped while an async repo call was
/// still in flight).
abstract class AppCubit<State> extends Cubit<State> {
  AppCubit(super.state);

  void safeEmit(State state) {
    if (!isClosed) emit(state);
  }
}