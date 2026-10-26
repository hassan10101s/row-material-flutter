import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../../design_system/feedback/app_error_feedback.dart';
import '../../../../../design_system/animations/app_animations.dart';
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
import '../../../../lab/presentation/batch/product_batch_section.dart';

/// Mobile inspection detail: same header, facts, lab analyses, history
/// and footer; the results tables become per-parameter cards (a
/// four-column flex table at 400dp squeezes reference and result past
/// readability), and the decision form becomes a full-screen route.
class MobileInspectionDetailScreen extends StatelessWidget {
  final int inspectionId;
  const MobileInspectionDetailScreen({super.key, required this.inspectionId});

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
        padding: const EdgeInsets.all(AppSpacing.pageMobile),
        // One-shot page entrance: header + facts slide in together, the
        // scrolling content underneath stays static thereafter.
        child: AppEntrance(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DetailHeader(
                inspection: inspection,
                state: state,
                onExportPdf: (kind) => exportInspectionPdf(context, kind),
              ),
              const SizedBox(height: AppSpacing.lg),
              DetailInfo(inspection: inspection),
              // Header result cards are raw-only: product batches keep no
              // header values (always empty) — their results live inside the
              // batch samples below, one expandable card per sample.
              if ('${inspection['inspection_kind'] ?? 'raw'}' != 'product') ...[
                const SizedBox(height: AppSpacing.lg),
                ResultsCards(
                  title: AppText.t('النتائج الفيزيائية', 'Physical results'),
                  reference: asMap(inspection['physical_reference']),
                  results: asMap(inspection['physical_results']),
                  samples: samples,
                  numeric: false,
                ),
                const SizedBox(height: AppSpacing.md),
                ResultsCards(
                  title: AppText.t('النتائج الكيميائية', 'Chemical results'),
                  reference: asMap(inspection['chemical_reference']),
                  results: asMap(inspection['chemical_results']),
                  samples: samples,
                  numeric: true,
                ),
                const SizedBox(height: AppSpacing.md),
              ] else ...[
                const SizedBox(height: AppSpacing.md),
              ],
              LabAnalysesCard(analyses: state.chemicalAnalyses),
              // Product batches only (محضر التشغيلة): the sample table inside
              // the report. Raw-material detail is untouched.
              if ('${inspection['inspection_kind'] ?? 'raw'}' == 'product') ...[
                const SizedBox(height: AppSpacing.md),
                ProductBatchSection(
                  batchId: inspectionId,
                  productId: (inspection['product_id'] as num?)?.toInt() ?? 0,
                  productName: '${inspection['material_name'] ?? ''}',
                  entryCode: '${inspection['entry_code'] ?? ''}',
                ),
              ],
              // Decision history is raw-only; products decide per sample.
              if ('${inspection['inspection_kind'] ?? 'raw'}' != 'product' &&
                  state.history.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.md),
                HistoryCard(history: state.history),
              ],
              const SizedBox(height: AppSpacing.lg),
              DetailFooterActions(
                state: state,
                isProduct:
                    '${inspection['inspection_kind'] ?? 'raw'}' == 'product',
                onEdit: () => openEditForm(context, inspection),
                onUpdateDecision: () =>
                    openDecisionDialog(context, inspectionId, inspection),
                onDelete: () => deleteInspection(context),
              ),
              const SizedBox(height: AppSpacing.xl),
            ],
          ),
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
