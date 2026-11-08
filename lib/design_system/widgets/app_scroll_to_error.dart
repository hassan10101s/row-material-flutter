import 'package:flutter/material.dart';

import '../tokens/app_motion.dart';

/// Field registry for "scroll the first invalid field into view".
///
/// Wrap the outer widget of each scrollable form field with an
/// [AppErrorAnchor], then after validation fails call `scrollToError` with
/// the map of errors keyed by the same field name. Fields scroll into view
/// under the nearest `Scrollable` ancestor (the unified window's scroll body
/// or the editor's own list), so it works identically inside a shared window
/// on desktop and a full pushed page on phones.
class AppFieldScrollRegistry {
  final Map<String, GlobalKey> _keys = {};

  /// The anchor key for [field]; stable per field name.
  GlobalKey keyFor(String field) => _keys.putIfAbsent(field, GlobalKey.new);

  /// Scrolls the first field present in [errors] into view. Returns the
  /// field name that was scrolled (or `null` when no anchor matched — e.g.
  /// a banner-level error with no field target, no scrolling happens).
  Future<String?> scrollToError(
    BuildContext context,
    Map<String, dynamic> errors,
  ) async {
    for (final field in errors.keys) {
      final key = _keys[field];
      final boundary = key?.currentContext;
      if (boundary == null) continue;
      await Scrollable.ensureVisible(
        boundary,
        duration: AppMotion.normal,
        curve: Curves.easeOutCubic,
        alignment: 0.12,
      );
      return field;
    }
    return null;
  }
}

/// Registers the wrapped widget's position as [field]'s error anchor.
class AppErrorAnchor extends StatelessWidget {
  const AppErrorAnchor({
    super.key,
    required this.registry,
    required this.field,
    required this.child,
  });

  final AppFieldScrollRegistry registry;
  final String field;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      KeyedSubtree(key: registry.keyFor(field), child: child);
}
