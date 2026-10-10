import 'package:flutter/material.dart';

import '../../../../design_system/widgets/app_adaptive.dart';
import 'desktop/analyses_tab.dart';
import 'mobile/analyses_tab.dart';

/// Analyses host: dispatch only, no UI.
///
/// Both variants share the cubit and the analysis editor, so behaviour can
/// never diverge — only chrome: a table + 720px dialog on desktop, cards +
/// full-screen editor route on phones.
class AnalysesTab extends StatelessWidget {
  const AnalysesTab({super.key});

  @override
  Widget build(BuildContext context) => appAdaptiveVariant(
    context,
    desktop: (_) => const DesktopAnalysesTab(),
    mobile: (_) => const MobileAnalysesTab(),
  );
}
