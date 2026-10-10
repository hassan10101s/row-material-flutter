import 'package:flutter/material.dart';

import '../../../../../design_system/widgets/app_window.dart';
import '../../cubit/products_cubit.dart';
import '../product_editor.dart';

/// The product editor as a unified window dialog (880x680).
///
/// The shell is the design-system [AppWindow]; [ProductEditor] supplies only
/// the form (it manages its own scroll + action row, hence `scrollBody` is
/// off), so the desktop screen keeps its exact layout in the shared chrome.
class DesktopProductEditor extends StatelessWidget {
  const DesktopProductEditor({
    super.key,
    required this.productsCubit,
    this.product,
  });

  final ProductsCubit productsCubit;
  final Map<String, dynamic>? product;

  @override
  Widget build(BuildContext context) {
    return AppWindow(
      title: productEditorTitle(product == null),
      icon: Icons.inventory_2_outlined,
      size: AppWindowSize.lg,
      height: 680,
      scrollBody: false,
      child: ProductEditor(
        productsCubit: productsCubit,
        product: product,
        actions: (_, state) => ProductEditorActions(state: state),
      ),
    );
  }
}
