import 'package:flutter/widgets.dart';

import '../../../design_system/widgets/app_adaptive.dart';
import '../../lab/domain/lab_result_repository.dart';
import '../domain/reference_repository.dart';
import 'desktop/materials_tab.dart';
import 'mobile/materials_tab.dart';

/// Reference materials (search + add/edit/delete).
///
/// A host with no content of its own: it decides the form factor once, injects
/// the repositories the editor needs, and hands the work to the experience built
/// for the platform. Neither variant resolves a repository or knows it is one of
/// a pair.
class MaterialsTab extends StatelessWidget {
  const MaterialsTab({
    super.key,
    required this.refRepo,
    required this.labConfig,
  });

  final ReferenceRepository refRepo;

  /// Owns the per-material acceptance bounds the editor writes.
  final LabConfigurationRepository labConfig;

  @override
  Widget build(BuildContext context) => appAdaptiveVariant(
    context,
    desktop: (_) => DesktopMaterialsTab(refRepo: refRepo, labConfig: labConfig),
    mobile: (_) => MobileMaterialsTab(refRepo: refRepo, labConfig: labConfig),
  );
}
