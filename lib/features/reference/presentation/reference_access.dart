import 'package:flutter/widgets.dart';

class ReferenceAccess extends InheritedWidget {
  const ReferenceAccess({
    super.key,
    required this.canManage,
    required super.child,
  });

  final bool canManage;

  static bool canManageReference(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<ReferenceAccess>()
          ?.canManage ??
      false;

  @override
  bool updateShouldNotify(ReferenceAccess oldWidget) =>
      canManage != oldWidget.canManage;
}
