import 'dart:async';

import 'package:flutter/material.dart';

import '../tokens/app_colors.dart';
import '../../core/utils/app_exceptions.dart';

enum AppFeedbackType { neutral, success, error, info }

/// App-wide feedback banner.
///
/// Rendered through the **root** [Overlay] instead of a [ScaffoldMessenger], so
/// it paints above the current page, any pushed route, any dialog and any
/// menu - it is the topmost thing on screen. It also no longer needs a
/// `Scaffold` ancestor, which is what silently dropped messages raised from
/// dialogs and nested routes.
///
/// An [AppFeedbackType.error] stays until it is dismissed: a failure that
/// disappears after four seconds looks exactly like a save that never
/// happened. Everything else auto-dismisses.
class AppFeedback {
  AppFeedback._();

  static ({OverlayEntry entry, int id})? _current;
  static int _seq = 0;

  static void show(
    BuildContext context,
    String message, {
    bool isError = false,
    AppFeedbackType type = AppFeedbackType.neutral,
    int durationSeconds = 4,
  }) {
    final text = message.trim();
    if (text.isEmpty) return;

    final kind = isError ? AppFeedbackType.error : type;
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) {
      // No overlay (unit test, or a context detached from the tree).
      debugPrint('AppFeedback[$kind]: $text');
      return;
    }

    _dismissCurrent();
    final id = ++_seq;
    final entry = OverlayEntry(
      builder: (context) => _FeedbackBanner(
        message: text,
        type: kind,
        sticky: kind == AppFeedbackType.error,
        duration: Duration(seconds: durationSeconds),
        onDismiss: () => _dismiss(id),
      ),
    );
    _current = (entry: entry, id: id);
    overlay.insert(entry);
  }

  /// Reports a caught [error] in a form a person can act on: a one-line summary
  /// on top, the untouched technical detail underneath it, and the raw error
  /// in the log so nothing is lost.
  static void errorFrom(
    BuildContext context,
    Object error, {
    String? summary,
  }) {
    final detail = describeError(error);
    debugPrint('AppFeedback error: $detail');
    show(
      context,
      summary == null ? detail : '$summary\n$detail',
      isError: true,
    );
  }

  /// Best-effort human text for anything thrown in the app. `AppError` already
  /// carries a message; everything else is flattened so the banner never leads
  /// with a driver wrapper such as
  /// `DatabaseException(SqliteException(1299): …)`.
  static String describeError(Object error) {
    if (error is AppError) {
      final message = error.message.trim();
      return message.isEmpty ? 'حدث خطأ غير متوقع' : message;
    }
    final text = error.toString().trim();
    if (text.isEmpty) return 'حدث خطأ غير متوقع';

    final unwrapped =
        text.replaceFirst(RegExp(r'^(DatabaseException|PlatformException)\s*[:(]\s*'), '');
    if (unwrapped != text) {
      // Drop the `)` that closed the wrapper we just removed.
      return unwrapped.endsWith(')')
          ? unwrapped.substring(0, unwrapped.length - 1).trim()
          : unwrapped.trim();
    }
    return text;
  }

  static void success(BuildContext context, String message) =>
      show(context, message, type: AppFeedbackType.success);

  static void error(BuildContext context, String message) =>
      show(context, message, isError: true, type: AppFeedbackType.error);

  static void info(BuildContext context, String message) =>
      show(context, message, type: AppFeedbackType.info);

  static void _dismissCurrent() {
    final current = _current;
    if (current == null) return;
    _current = null;
    current.entry.remove();
  }

  /// A banner whose timer already fired must never remove a *newer* message.
  static void _dismiss(int id) {
    final current = _current;
    if (current == null || current.id != id) return;
    _current = null;
    current.entry.remove();
  }
}

class _FeedbackBanner extends StatefulWidget {
  const _FeedbackBanner({
    required this.message,
    required this.type,
    required this.sticky,
    required this.duration,
    required this.onDismiss,
  });

  final String message;
  final AppFeedbackType type;
  final bool sticky;
  final Duration duration;
  final VoidCallback onDismiss;

  @override
  State<_FeedbackBanner> createState() => _FeedbackBannerState();
}

class _FeedbackBannerState extends State<_FeedbackBanner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    reverseDuration: const Duration(milliseconds: 180),
  );
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _controller.forward();
    if (!widget.sticky && widget.duration > Duration.zero) {
      _timer = Timer(widget.duration, _close);
    }
  }

  void _close() {
    if (!mounted) return;
    _timer?.cancel();
    _controller.reverse().whenCompleteOrCancel(() {
      if (mounted) widget.onDismiss();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = switch (widget.type) {
      AppFeedbackType.error => AppColors.danger,
      AppFeedbackType.success => AppColors.success,
      AppFeedbackType.info => AppColors.info,
      AppFeedbackType.neutral => AppColors.surfaceDeep,
    };
    final icon = switch (widget.type) {
      AppFeedbackType.error => Icons.error_outline,
      AppFeedbackType.success => Icons.check_circle_outline,
      AppFeedbackType.info => Icons.info_outline,
      AppFeedbackType.neutral => Icons.campaign_outlined,
    };
    final animation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        bottom: false,
        child: FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, -1),
              end: Offset.zero,
            ).animate(animation),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Material(
                key: const ValueKey('app-feedback-banner'),
                color: accent,
                elevation: 12,
                shadowColor: Colors.black54,
                borderRadius: const BorderRadius.vertical(
                  bottom: Radius.circular(14),
                ),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: _close,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(icon, color: Colors.white, size: 22),
                        const SizedBox(width: 12),
                        Expanded(
                          child: ConstrainedBox(
                            // A raw SQLite/Firebase error can be very long; keep
                            // the banner from swallowing the whole screen.
                            constraints: const BoxConstraints(maxHeight: 240),
                            child: SingleChildScrollView(
                              child: SelectableText(
                                widget.message,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13.5,
                                  height: 1.4,
                                ),
                              ),
                            ),
                          ),
                        ),
                        IconButton(
                          onPressed: _close,
                          icon: const Icon(Icons.close, size: 18),
                          color: Colors.white70,
                          tooltip: MaterialLocalizations.of(context)
                              .closeButtonTooltip,
                          visualDensity: VisualDensity.compact,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
