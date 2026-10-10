import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../../design_system/feedback/app_error_feedback.dart';
import '../../../../../design_system/tokens/app_colors.dart';
import '../../../../../design_system/tokens/app_spacing.dart';
import '../../../../../design_system/widgets/app_button.dart';
import '../../../../../design_system/widgets/app_skeleton.dart';
import '../../../../../design_system/widgets/app_top_app_bar.dart';
import '../../../../../core/constants/app_strings.dart';
import '../../cubit/inspection_detail_cubit.dart';
import '../../cubit/inspection_detail_state.dart';
import '../widgets/decision_opener.dart';
import '../widgets/detail_parts.dart';

/// Desktop inspection detail: the pre-split pixels (header, info wrap,
/// results tables, lab analyses, history, footer actions).
class DesktopInspectionDetailScreen extends StatelessWidget {
  final int inspectionId;
  const DesktopInspectionDetailScreen({
    super.key,
    required this.inspectionId,
  });

  @override
  Widget build(BuildContext context) {
    final state = context.watch<InspectionDetailCubit>().state;
    final cubit = context.read<InspectionDetailCubit>();
    final inspection = state.inspection;
    Widget body;
    if (state.loading && inspection == null) {
      body = const AppSkeletonList(rows: 6, lines: 3, height: 440);
    } else if (state.error != null) {
      body = Center(
        child: AppButton(
          style: AppButtonStyle.secondary,
          label: AppText.t('إعادة المحاولة', 'Retry'),
          onPressed: cubit.load,
        ),
      );
    } else if (inspection == null) {
      body = Center(child: Text(AppText.t('غير موجود', 'Not found')));
    } else {
      final samples = sampleLabels(inspection);
      body = SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.page),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DetailHeader(
              inspection: inspection,
              state: state,
              onExportPdf: (kind) => exportInspectionPdf(context, kind),
            ),
            const SizedBox(height: AppSpacing.xl),
            DetailInfo(inspection: inspection),
            const SizedBox(height: AppSpacing.xl),
            ResultsTable(
              title: AppText.t('النتائج الفيزيائية', 'Physical results'),
              reference: asMap(inspection['physical_reference']),
              results: asMap(inspection['physical_results']),
              samples: samples,
              numeric: false,
            ),
            const SizedBox(height: AppSpacing.md),
            ResultsTable(
              title: AppText.t('النتائج الكيميائية', 'Chemical results'),
              reference: asMap(inspection['chemical_reference']),
              results: asMap(inspection['chemical_results']),
              samples: samples,
              numeric: true,
            ),
            const SizedBox(height: AppSpacing.md),
            LabAnalysesCard(analyses: state.chemicalAnalyses),
            if (state.history.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.md),
              HistoryCard(history: state.history),
            ],
            const SizedBox(height: AppSpacing.xl),
            DetailFooterActions(
              state: state,
              onEdit: () => openEditForm(context, inspection),
              onUpdateDecision: () => openDecisionDialog(
                context,
                inspectionId,
                inspection,
              ),
              onDelete: () => deleteInspection(context),
            ),
          ],
        ),
      );
    }
    return AppErrorFeedback<InspectionDetailCubit, InspectionDetailState>(
      selector: (s) => s.error,
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppTopAppBar(
          title: AppText.t('تفاصيل الفحص', 'Inspection details'),
        ),
        body: body,
      ),
    );
  }
}
