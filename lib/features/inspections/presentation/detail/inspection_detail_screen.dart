import 'package:flutter/material.dart';

import '../../../../design_system/widgets/app_adaptive.dart';
import 'desktop/inspection_detail_screen.dart';
import 'mobile/inspection_detail_screen.dart';

/// Inspection detail host: dispatch only, no UI.
///
/// Both variants share the cubit and the decision/edit openers, so
/// behaviour can never diverge — only chrome: results tables on desktop,
/// per-parameter cards + full-screen decision route on phones.
class InspectionDetailScreen extends StatelessWidget {
  final int inspectionId;
  const InspectionDetailScreen({super.key, required this.inspectionId});

  @override
  Widget build(BuildContext context) => appAdaptiveVariant(
    context,
    desktop: (_) => DesktopInspectionDetailScreen(inspectionId: inspectionId),
    mobile: (_) => MobileInspectionDetailScreen(inspectionId: inspectionId),
  );
}
