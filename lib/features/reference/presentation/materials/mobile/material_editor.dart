import 'package:flutter/material.dart';

import '../../../../../design_system/tokens/app_spacing.dart';
import '../../../../lab/domain/lab_result_repository.dart';
import '../../../domain/reference_repository.dart';
import '../material_editor.dart';

/// The material editor as a full-screen route.
///
/// An 880x680 dialog is unusable on a 400x860 grid — it would either overflow or
/// shrink its rows below a usable height — so the phone gets its own chrome and
/// the compact layout, and the same form and save path underneath.
class MobileMaterialEditor extends StatelessWidget {
  const MobileMaterialEditor({
    super.key,
    required this.refRepo,
    required this.labConfig,
    this.materialId,
  });

  final ReferenceRepository refRepo;
  final LabConfigurationRepository labConfig;
  final int? materialId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(materialEditorTitle(materialId == null))),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: MaterialEditor(
            refRepo: refRepo,
            labConfig: labConfig,
            materialId: materialId,
            layout: MaterialEditorLayout.compact,
            actions: (_, state) =>
                MaterialEditorActions(state: state, compact: true),
          ),
        ),
      ),
    );
  }
}
