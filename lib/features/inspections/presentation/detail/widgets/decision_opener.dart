import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../../core/constants/app_strings.dart';
import '../../../../../core/responsive/form_factor.dart';
import '../../../../../design_system/animations/app_animations.dart';
import '../../../../../design_system/feedback/app_feedback.dart';
import '../../../../../design_system/tokens/app_spacing.dart';
import '../../../../../design_system/widgets/app_window.dart';
import '../../../../../di/service_locator.dart';
import '../../../../reference/domain/reference_repository.dart';
import '../../../domain/inspection_repository.dart';
import '../../cubit/inspection_detail_cubit.dart';
import '../../cubit/inspection_form_cubit.dart';
import '../../form/inspection_form_screen.dart';
import 'inspection_widgets.dart';

/// Full-record edit with platform chrome (the detail screen's تعديل button).
///
/// Desktop opens the Windows design-system window ([AppWindow] lg, the same
/// chrome as a new inspection); phones push the stepped wizard route. Both
/// prefill from [inspection] and reload the detail on save.
Future<void> openEditForm(
  BuildContext context,
  Map<String, dynamic> inspection,
) async {
  final detail = context.read<InspectionDetailCubit>();
  Widget form() => BlocProvider(
        create: (_) => InspectionFormCubit(
          repo: getIt<InspectionRepository>(),
          reference: getIt<ReferenceRepository>(),
        )
          // Edit mode: `loadForEdit` loads the right catalog itself
          // (materials vs products by the row's kind) and marks the cubit
          // as editing, so save updates instead of creating.
          ..loadForEdit(inspection),
        child: InspectionFormScreen(
          inspection: inspection,
          wizard: FormFactor.current.isMobile,
        ),
      );
  final saved = FormFactor.current.isDesktop
      ? await showAppWindow<bool>(
          context,
          title: AppText.t('تعديل الفحص', 'Edit inspection'),
          icon: Icons.edit_outlined,
          size: AppWindowSize.lg,
          scrollBody: false,
          child: form(),
        )
      : await Navigator.of(context).push<bool>(
          appMaterialPageRoute<bool>(builder: (_) => form()),
        );
  if (saved == true && context.mounted) {
    await detail.load();
  }
}

/// Decision update with platform chrome: dialog on desktop, full-screen
/// route on phones (a 460px dialog + keyboard never fits the conditional
/// fields). Same [DecisionForm], same save, same reload.
///
/// Lives in its own file (rather than `detail_parts.dart`) because the
/// architecture guard forbids one file from naming the form factor *and*
/// reading the window width: the header in `detail_parts.dart` lays out
/// with a `LayoutBuilder`, so the platform decision lives here.
Future<void> openDecisionDialog(
  BuildContext context,
  int inspectionId,
  Map<String, dynamic> inspection,
) async {
  final cubit = context.read<InspectionDetailCubit>();
  final saved = FormFactor.current.isDesktop
      ? await showDialog<bool>(
          context: context,
          builder: (_) => DecisionForm(
            inspectionId: inspectionId,
            inspection: inspection,
            windowed: true,
          ),
        )
      : await Navigator.of(context).push<bool>(
          appMaterialPageRoute<bool>(
            builder: (_) => BlocProvider.value(
              value: cubit,
              child: Scaffold(
                appBar: AppBar(
                  title: Text(AppText.t('تحديث القرار', 'Update decision')),
                ),
                body: SafeArea(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(AppSpacing.pageMobile),
                    child: DecisionForm(
                      inspectionId: inspectionId,
                      inspection: inspection,
                      windowed: false,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
  if (saved == true) {
    await cubit.load();
    if (context.mounted) {
      AppFeedback.success(
        context,
        AppText.t('تم تحديث القرار', 'Decision updated.'),
      );
    }
  }
}
