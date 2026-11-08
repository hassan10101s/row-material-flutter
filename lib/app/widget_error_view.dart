import 'package:flutter/material.dart';

/// A failed subtree can be inside a sliver, a row, or a tiny control. Never
/// insert an app, navigator, scaffold or expanding page into that position:
/// doing so turns the original build error into an infinite layout cascade.
Widget buildAppWidgetError(FlutterErrorDetails details) =>
    const AppWidgetErrorView();

class AppWidgetErrorView extends StatelessWidget {
  const AppWidgetErrorView({super.key});

  @override
  Widget build(BuildContext context) => LimitedBox(
    maxWidth: 480,
    maxHeight: 120,
    child: ColoredBox(
      color: const Color(0xFFFFF1F2),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Directionality(
          textDirection: TextDirection.rtl,
          child: Text(
            'تعذر عرض هذا الجزء من الشاشة. حاول فتحه مجددًا.\nUnable to display this part of the screen.',
            style: const TextStyle(
              color: Color(0xFF991B1B),
              fontSize: 14,
              height: 1.4,
            ),
          ),
        ),
      ),
    ),
  );
}
