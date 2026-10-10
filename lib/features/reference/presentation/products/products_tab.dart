import 'package:flutter/widgets.dart';

import '../../../../design_system/widgets/app_adaptive.dart';
import 'desktop/products_tab.dart';
import 'mobile/products_tab.dart';

/// Reference products (search + add/edit/delete).
///
/// A host with no content of its own: it decides the form factor once and
/// hands the work to the experience built for the platform (mirrors
/// `MaterialsTab`). Neither variant knows it is one of a pair.
class ProductsTab extends StatelessWidget {
  const ProductsTab({super.key});

  @override
  Widget build(BuildContext context) => appAdaptiveVariant(
    context,
    desktop: (_) => const DesktopProductsTab(),
    mobile: (_) => const MobileProductsTab(),
  );
}
