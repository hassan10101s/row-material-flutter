import 'package:flutter/material.dart';

import '../../../../../design_system/widgets/app_window.dart';
import '../../../../lab/domain/lab_result_repository.dart';
import '../../../domain/reference_repository.dart';
import '../material_editor.dart';

/// The material editor as a unified window dialog (880x680).
///
/// The shell is the design-system [AppWindow]; [MaterialEditor] supplies only
/// the form (it manages its own scroll + action row, hence `scrollBody` is
/// off), so the desktop screen keeps its exact layout in the shared chrome.
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
    return AppWindow(
      title: materialEditorTitle(materialId == null),
      icon: Icons.science_outlined,
      size: AppWindowSize.lg,
      height: 680,
      scrollBody: false,
      child: MaterialEditor(
        refRepo: refRepo,
        labConfig: labConfig,
        materialId: materialId,
        actions: (_, state) => MaterialEditorActions(state: state),
      ),
    );
  }
}
