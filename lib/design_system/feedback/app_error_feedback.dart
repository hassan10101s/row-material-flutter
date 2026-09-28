import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'app_feedback.dart';

/// Routes a cubit state's `error` into the top [AppFeedback] banner so no
/// screen has to render it inside its own layout.
///
/// Screens used to print `state.error` as a red [Text] in the middle of the
/// page, which put the message wherever the content happened to be and made
/// it easy to miss. This wraps a subtree, watches the state and raises the
/// banner once per distinct error.
///
/// The banner is scheduled after the frame: inserting an [OverlayEntry] while
/// the tree is building is illegal. `_shown` resets when the error clears, so
/// the same failure happening again is reported again instead of being
/// swallowed as "already displayed".
class AppErrorFeedback<C extends StateStreamable<S>, S> extends StatefulWidget {
  const AppErrorFeedback({
    super.key,
    required this.selector,
    required this.child,
  });

  final String? Function(S state) selector;
  final Widget child;

  @override
  State<AppErrorFeedback<C, S>> createState() => _AppErrorFeedbackState<C, S>();
}

class _AppErrorFeedbackState<C extends StateStreamable<S>, S>
    extends State<AppErrorFeedback<C, S>> {
  String? _shown;

  void _raise(String? error) {
    if (error == null) {
      _shown = null;
      return;
    }
    if (error == _shown) return;
    _shown = error;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      AppFeedback.error(context, error);
    });
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<C, S>(
      builder: (context, state) {
        _raise(widget.selector(state));
        return widget.child;
      },
    );
  }
}
