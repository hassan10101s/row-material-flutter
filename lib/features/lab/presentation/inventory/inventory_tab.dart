import 'package:flutter/material.dart';

import '../../../../design_system/widgets/app_adaptive.dart';
import 'desktop/inventory_tab.dart';
import 'mobile/inventory_tab.dart';

/// Inventory host: dispatch only, no UI.
///
/// Both variants share the cubit and the inventory forms, so behaviour can
/// never diverge — only chrome: a DataTable + dialogs on desktop, cards +
/// full-screen editor routes on phones.
class InventoryTab extends StatelessWidget {
  const InventoryTab({super.key});

  @override
  Widget build(BuildContext context) => appAdaptiveVariant(
    context,
    desktop: (_) => const DesktopInventoryTab(),
    mobile: (_) => const MobileInventoryTab(),
  );
}
