import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../design_system/tokens/app_colors.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../../../lab/domain/lab_result_repository.dart';
import '../../domain/reference_repository.dart';
import '../material_editor.dart';

/// The material editor as the 880x680 dialog it has always been.
///
/// The dialog shell and the title stay here; [MaterialEditor] supplies only the
/// form, so the desktop screen renders exactly as it did before the split.
class DesktopMaterialEditor extends StatelessWidget {
  const DesktopMaterialEditor({
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
    return Dialog(
      insetPadding: const EdgeInsets.all(AppSpacing.lg),
      backgroundColor: AppColors.surface,
      child: SizedBox(
        width: 880.w,
        height: 680.h,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.lg,
                AppSpacing.lg,
                0,
              ),
              child: Text(
                materialEditorTitle(materialId == null),
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Expanded(
              child: MaterialEditor(
                refRepo: refRepo,
                labConfig: labConfig,
                materialId: materialId,
                actions: (_, state) => MaterialEditorActions(state: state),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
