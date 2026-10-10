import 'package:flutter/material.dart';

import '../../../../design_system/widgets/app_adaptive.dart';
import 'desktop/inspections_screen.dart';
import 'mobile/inspections_screen.dart';

/// Inspections ledger host: dispatch only, no UI.
///
/// Both variants share the cubit and the bulk-export sheet, so behaviour
/// can never diverge — only chrome: a selectable paginated table + dialogs
/// on desktop, cards + full-screen routes on phones.
class InspectionsScreen extends StatelessWidget {
  const InspectionsScreen({super.key});

  @override
  Widget build(BuildContext context) => appAdaptiveVariant(
    context,
    desktop: (_) => const DesktopInspectionsScreen(),
    mobile: (_) => const MobileInspectionsScreen(),
  );
}
