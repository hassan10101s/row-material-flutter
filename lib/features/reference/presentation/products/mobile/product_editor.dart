import 'package:flutter/material.dart';

import '../../../../../design_system/tokens/app_spacing.dart';
import '../../cubit/products_cubit.dart';
import '../product_editor.dart';

/// The product editor as a full-screen route.
///
/// An 880x680 dialog is unusable on a 400x860 grid — it would either overflow
/// or shrink its rows below a usable height — so the phone gets its own
/// chrome and the compact layout, and the same form and save path underneath.
class MobileProductEditor extends StatelessWidget {
  const MobileProductEditor({
    super.key,
    required this.productsCubit,
    this.product,
  });

  final ProductsCubit productsCubit;
  final Map<String, dynamic>? product;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(productEditorTitle(product == null)),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: ProductEditor(
            productsCubit: productsCubit,
            product: product,
            layout: ProductEditorLayout.compact,
            actions: (_, state) =>
                ProductEditorActions(state: state, compact: true),
          ),
        ),
      ),
    );
  }
}
