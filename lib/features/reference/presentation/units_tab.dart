import 'package:flutter/widgets.dart';

import '../../../../design_system/widgets/app_adaptive.dart';
import 'desktop/units_tab.dart';
import 'mobile/units_tab.dart';

/// Unit settings.
///
/// A host with no content of its own: it decides the form factor once and hands
/// the work to the experience built for it, so neither variant has to know it
/// is one of a pair.
class UnitsTab extends StatelessWidget {
  const UnitsTab({super.key});

  @override
  Widget build(BuildContext context) => appAdaptiveVariant(
    context,
    desktop: (_) => const DesktopUnitsTab(),
    mobile: (_) => const MobileUnitsTab(),
  );
}
