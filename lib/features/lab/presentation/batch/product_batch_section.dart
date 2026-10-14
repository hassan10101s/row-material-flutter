import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../../app/auth_gate.dart';
import '../../../../../core/constants/app_strings.dart';
import '../../../../../core/utils/app_dates.dart';
import '../../../../../core/utils/app_format.dart';
import '../../../../../design_system/feedback/app_error_feedback.dart';
import '../../../../../design_system/feedback/app_feedback.dart';
import '../../../../../design_system/tokens/app_colors.dart';
import '../../../../../design_system/tokens/app_spacing.dart';
import '../../../../../design_system/widgets/app_button.dart';
import '../../../../../design_system/widgets/app_card.dart';
import '../../../../../design_system/widgets/app_delete_confirm.dart';
import '../../../../../design_system/widgets/app_dropdown.dart';
import '../../../../../design_system/widgets/app_empty_state.dart';
import '../../../../../design_system/widgets/app_field.dart';
import '../../../../../design_system/widgets/app_history_autocomplete.dart';
import '../../../../../design_system/widgets/app_skeleton.dart';
import '../../../../../design_system/widgets/app_status_badge.dart';
import '../../../../../design_system/widgets/app_window.dart';
import '../../../../../di/service_locator.dart';
import '../../../inspections/domain/inspection_repository.dart';
import '../../../inspections/presentation/cubit/inspection_detail_cubit.dart';
import '../../../reference/domain/reference_repository.dart';
import '../../domain/lab_result_repository.dart';
import '../../domain/product_batch_repository.dart';
import '../cubit/product_batch_cubit.dart';
import '../cubit/product_batch_state.dart';

const _batchDecisions = [
  'APPROVED',
  'CONDITIONAL_APPROVAL',
  'PARTIAL_REJECTION',
  'FULL_REJECTION',
];

/// "Table inside the report" for a product batch (محضر التشغيلة).
///
/// Mounted inside the product inspection detail (both chrome variants),
/// gated by the caller on `inspection_kind == 'product'`. Raw-material
/// reports never mount this. Samples are batch-traceability rows with
/// their own taker, time and results — fully independent of lab chemistry;
/// tapping a sample expands its own tables, editing reopens its form.
class ProductBatchSection extends StatelessWidget {
  const ProductBatchSection({
    super.key,
    required this.batchId,
    required this.productId,
    required this.productName,
    required this.entryCode,
  });

  final int batchId;
  final int productId;
  final String productName;
  final String entryCode;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => ProductBatchCubit(
        batchId: batchId,
        repo: getIt<ProductBatchRepository>(),
        currentUser: () {
          final u = getIt<AuthGate>().currentUser;
          if (u == null) return null;
          return UserContext(
            id: u.id,
            uid: u.uid,
            fullName: u.fullName,
            role: u.role,
          );
        },
      )..load(),
      child: _BatchSectionBody(
        batchId: batchId,
        productId: productId,
        productName: productName,
        entryCode: entryCode,
      ),
    );
  }
}

/// Formats `tested_at` ISO as date + hour so the sequential table shows
/// when each sample was entered (الساعة والتاريخ).
String _fmtSampleDateTime(String raw) {
  final t = raw.trim();
  if (t.isEmpty) return '-';
  // Stored as `yyyy-MM-dd HH:mm:ss` (see nowIso); display dd/MM/yyyy HH:mm.
  final m = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})',
  ).firstMatch(t);
  if (m != null) {
    return '${m[3]}/${m[2]}/${m[1]} ${m[4]}:${m[5]}';
  }
  return parseIsoToDisplay(t) ?? t;
}

class _BatchSectionBody extends StatefulWidget {
  const _BatchSectionBody({
    required this.batchId,
    required this.productId,
    required this.productName,
    required this.entryCode,
  });

  final int batchId;
  final int productId;
  final String productName;
  final String entryCode;

  @override
  State<_BatchSectionBody> createState() => _BatchSectionBodyState();
}

class _BatchSectionBodyState extends State<_BatchSectionBody> {
  int? _expandedSampleId;

  int get batchId => widget.batchId;
  int get productId => widget.productId;
  String get productName => widget.productName;
  String get entryCode => widget.entryCode;

  void _refreshDetail(BuildContext context) {
    try {
      context.read<InspectionDetailCubit>().load();
    } catch (_) {}
  }

  /// Template inherited from the product file (أصل الملف): the exact linked
  /// items of the محضر — physical map + chemical map — plus the taker
  /// history for autocomplete. New samples inherit ALL of it pre-filled
  /// (values empty, units filled); بيان names are never free text.
  Future<_BatchSampleTemplate> _loadTemplate(BuildContext context) async {
    Map<String, dynamic> physicalRef = {};
    Map<String, dynamic> chemicalRef = {};
    try {
      final product = await getIt<ReferenceRepository>()
          .getProductForInspection(productId);
      final p = product['physical_reference'];
      if (p is Map) physicalRef = Map<String, dynamic>.from(p);
      final c = product['chemical_reference'];
      if (c is Map) chemicalRef = Map<String, dynamic>.from(c);
    } catch (_) {}
    List<Map<String, dynamic>> takers = const [];
    try {
      takers = await getIt<InspectionRepository>().listSampleTakerHistory();
    } catch (_) {}
    var ranges = const <Map<String, dynamic>>[];
    try {
      ranges = await getIt<LabConfigurationRepository>().getProductRanges(
        productId,
      );
    } catch (_) {}
    // Legacy products (ranges only, no chemical_reference_json yet):
    // convert ranges into the same fixed chemical template.
    if (chemicalRef.isEmpty && ranges.isNotEmpty) {
      chemicalRef = {
        for (final r in ranges)
          if ('${r['analysis_name'] ?? ''}'.trim().isNotEmpty)
            '${r['analysis_name']}'.trim(): {
              'value': '',
              'unit': '${r['unit'] ?? ''}',
            },
      };
    }
    if (context.mounted &&
        physicalRef.isEmpty &&
        chemicalRef.isEmpty &&
        ranges.isEmpty) {
      // No linked items at all — keep silent; the form shows an empty-state
      // instead of free rows so بيان can never diverge from the محضر.
    }
    return _BatchSampleTemplate(
      physicalRef: physicalRef,
      chemicalRef: chemicalRef,
      takerOptions: takers,
    );
  }

  /// Adds a sample inheriting the محضر linked items: every physical بيان
  /// (e.g. اللون) and every chemical analysis arrives pre-filled with its
  /// unit/reference — only the values + taker are filled per sample.
  Future<void> _addSample(BuildContext context) async {
    final cubit = context.read<ProductBatchCubit>();
    final template = await _loadTemplate(context);
    if (!context.mounted) return;
    final data = await showAppOverlay<_SampleFormData>(
      context,
      title: AppText.t('عينة جديدة', 'New sample'),
      icon: Icons.science_outlined,
      builder: (sheetContext, close) => _SampleForm(
        template: template,
        onSave: (d) => close(d),
      ),
    );
    if (data == null || !context.mounted) return;
    HapticFeedback.selectionClick();
    final sample = await cubit.addSample(
      name: data.name.trim().isEmpty ? null : data.name.trim(),
      sampleTaker: data.taker.trim(),
      physicalResults: data.physical,
      chemicalResults: data.chemical,
    );
    if (!context.mounted) return;
    if (sample != null) {
      _refreshDetail(context);
      AppFeedback.success(
        context,
        AppText.t('تمت إضافة العينة', 'Sample added.'),
      );
    } else if (cubit.state.error != null) {
      AppFeedback.error(context, cubit.state.error!);
    }
  }

  /// Edits a sample's values only — the بيان list stays the inherited
  /// محضر set (same linked items, per-sample values).
  Future<void> _editSample(
    BuildContext context,
    Map<String, dynamic> sample,
  ) async {
    final cubit = context.read<ProductBatchCubit>();
    final sampleId = (sample['id'] as num).toInt();
    final template = await _loadTemplate(context);
    if (!context.mounted) return;
    final data = await showAppOverlay<_SampleFormData>(
      context,
      title: AppText.t('تعديل العينة', 'Edit sample'),
      icon: Icons.edit_outlined,
      builder: (sheetContext, close) => _SampleForm(
        template: template,
        initial: sample,
        onSave: (d) => close(d),
      ),
    );
    if (data == null || !context.mounted) return;
    await cubit.updateSample(
      sampleId,
      name: data.name.trim(),
      sampleTaker: data.taker.trim(),
      physicalResults: data.physical,
      chemicalResults: data.chemical,
    );
    if (!context.mounted) return;
    if (cubit.state.error != null) {
      AppFeedback.error(context, cubit.state.error!);
    } else {
      _refreshDetail(context);
      AppFeedback.success(context, AppText.t('تم حفظ العينة', 'Sample saved.'));
    }
  }

  Future<void> _setDecision(
    BuildContext context,
    Map<String, dynamic> sample,
  ) async {
    final cubit = context.read<ProductBatchCubit>();
    final sampleId = (sample['id'] as num).toInt();
    var status = '${sample['decision_status'] ?? ''}';
    if (!_batchDecisions.contains(status)) status = 'APPROVED';
    final reasonCtrl = TextEditingController(
      text: '${sample['decision_reason'] ?? ''}',
    );
    final saved = await showAppOverlay<bool>(
      context,
      title: AppText.t('قرار العينة', 'Sample decision'),
      icon: Icons.fact_check_outlined,
      builder: (sheetContext, close) => StatefulBuilder(
        builder: (context, setDraft) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppDropdown<String>(
              value: status,
              labelText: AppText.t('القرار', 'Decision'),
              items: [
                for (final s in _batchDecisions)
                  AppDropdownItem(value: s, label: statusLabel(s)),
              ],
              onChanged: (v) => setDraft(() => status = v ?? status),
            ),
            const SizedBox(height: AppSpacing.md),
            AppField(
              label: AppText.t('السبب', 'Reason'),
              controller: reasonCtrl,
              maxLines: 2,
            ),
            const SizedBox(height: AppSpacing.lg),
            AppButton(
              label: AppText.t('حفظ', 'Save'),
              expanded: true,
              onPressed: () => close(true),
            ),
          ],
        ),
      ),
    );
    final reason = reasonCtrl.text;
    reasonCtrl.dispose();
    if (saved != true || !context.mounted) return;
    await cubit.setSampleDecision(
      sampleId,
      status: status,
      reason: reason.trim(),
    );
    if (!context.mounted) return;
    if (cubit.state.error != null) {
      AppFeedback.error(context, cubit.state.error!);
    } else {
      _refreshDetail(context);
      AppFeedback.success(
        context,
        AppText.t('تم حفظ القرار', 'Decision saved.'),
      );
    }
  }

  Future<void> _deleteSample(
    BuildContext context,
    Map<String, dynamic> sample,
  ) async {
    final cubit = context.read<ProductBatchCubit>();
    final sampleId = (sample['id'] as num).toInt();
    final confirmed = await AppDeleteConfirmDialog.show(
      context,
      title: AppText.t('حذف العينة', 'Delete sample'),
      name: '${sample['sample_name'] ?? ''}',
    );
    if (!confirmed || !context.mounted) return;
    await cubit.deleteSample(sampleId);
    if (!context.mounted) return;
    if (cubit.state.error != null) {
      AppFeedback.error(context, cubit.state.error!);
    } else {
      _refreshDetail(context);
      AppFeedback.success(context, AppText.t('تم الحذف', 'Deleted.'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<ProductBatchCubit>().state;
    if (state.loading && state.samples.isEmpty) {
      return const AppSkeletonList(rows: 3, lines: 2, height: 220);
    }
    final progress = state.samples.isEmpty
        ? 0.0
        : state.decidedCount / state.samples.length;
    return AppErrorFeedback<ProductBatchCubit, ProductBatchState>(
      selector: (s) => s.error,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppSectionHeader(
            title: AppText.t('عينات التشغيلة', 'Batch samples'),
            icon: Icons.science_outlined,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: AppText.t('تحديث', 'Refresh'),
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  onPressed: state.loading
                      ? null
                      : () => context.read<ProductBatchCubit>().load(),
                  icon: const Icon(Icons.refresh),
                ),
                AppButton(
                  label: AppText.t('عينة', 'Sample'),
                  icon: const Icon(Icons.add),
                  small: true,
                  onPressed: () => _addSample(context),
                ),
              ],
            ),
          ),
          AppCard(
            enableHover: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${state.samples.length} ${AppText.t('عينة', 'samples')}'
                        ' • ${state.decidedCount} ${AppText.t('معتمدة', 'decided')}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13.spMax,
                          color: AppColors.textMuted,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.xs),
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadii.pill),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 6,
                    backgroundColor: AppColors.primary.withValues(alpha: 0.12),
                    color: AppColors.primary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          if (state.samples.isEmpty)
            AppEmptyState(
              icon: Icons.science_outlined,
              title: AppText.t('لا توجد عينات بعد', 'No samples yet'),
              subtitle: AppText.t(
                'أضف أول عينة بمن أخذها وتوقيتها ونتائجها.',
                'Add the first sample with its taker, time and results.',
              ),
              action: AppButton(
                label: AppText.t('عينة جديدة', 'New sample'),
                icon: const Icon(Icons.add),
                onPressed: () => _addSample(context),
              ),
            )
          else ...[
            // Sequential sample-after-sample table (عينة وراء عينة):
            // one row per sample in sample_no order with taker, date+hour
            // and result counts. Tapping a row expands its own tables.
            _SamplesSequentialTable(
              samples: state.samples,
              expandedId: _expandedSampleId,
              onToggle: (id) => setState(() {
                _expandedSampleId = _expandedSampleId == id ? null : id;
              }),
              onEdit: (s) => _editSample(context, s),
              onDecision: (s) => _setDecision(context, s),
              onDelete: (s) => _deleteSample(context, s),
            ),
            const SizedBox(height: AppSpacing.md),
          ],
        ],
      ),
    );
  }
}

/// Sequential sample-after-sample table (عينة وراء عينة): one row per
/// sample in `sample_no` order with taker, date+hour and result counts.
/// One tap expands that sample's own physical + chemical tables below.
/// The rows are fully independent of lab chemistry.
class _SamplesSequentialTable extends StatelessWidget {
  const _SamplesSequentialTable({
    required this.samples,
    required this.expandedId,
    required this.onToggle,
    required this.onEdit,
    required this.onDecision,
    required this.onDelete,
  });

  final List<Map<String, dynamic>> samples;
  final int? expandedId;
  final ValueChanged<int> onToggle;
  final ValueChanged<Map<String, dynamic>> onEdit;
  final ValueChanged<Map<String, dynamic>> onDecision;
  final ValueChanged<Map<String, dynamic>> onDelete;

  static int _resultCount(Map<String, dynamic> s) =>
      decodeBatchPhysical(s['physical_results_json']).length +
      decodeBatchChemical(s['chemical_results_json']).length;

  @override
  Widget build(BuildContext context) {
    // Repository already orders by sample_no ASC; re-sort defensively so the
    // on-screen table and the report extract always agree.
    final ordered = [...samples]
      ..sort((a, b) {
        final na = (a['sample_no'] as num?)?.toInt() ?? 0;
        final nb = (b['sample_no'] as num?)?.toInt() ?? 0;
        if (na != nb) return na.compareTo(nb);
        return ((a['id'] as num?)?.toInt() ?? 0).compareTo(
          (b['id'] as num?)?.toInt() ?? 0,
        );
      });
    return AppCard(
      enableHover: false,
      padding: const EdgeInsets.all(AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              headingRowColor: WidgetStatePropertyAll(
                AppColors.primary.withValues(alpha: 0.08),
              ),
              columns: [
                DataColumn(
                  label: Text(
                    AppText.t('#', '#'),
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
                DataColumn(
                  label: Text(
                    AppText.t('العينة', 'Sample'),
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
                DataColumn(
                  label: Text(
                    AppText.t('التاريخ والساعة', 'Date & time'),
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
                DataColumn(
                  label: Text(
                    AppText.t('أخذها', 'Taken by'),
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
                DataColumn(
                  label: Text(
                    AppText.t('النتائج', 'Results'),
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  numeric: true,
                ),
                DataColumn(
                  label: Text(
                    AppText.t('القرار', 'Decision'),
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
                DataColumn(
                  label: Text(
                    AppText.t('', ''),
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
              ],
              rows: [
                for (final s in ordered)
                  DataRow(
                    key: ValueKey('batch-sample-${s['id']}'),
                    selected: (s['id'] as num?)?.toInt() == expandedId,
                    onSelectChanged: (_) => onToggle((s['id'] as num).toInt()),
                    cells: [
                      DataCell(
                        Text(
                          '${s['sample_no'] ?? ''}',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                      DataCell(Text('${s['sample_name'] ?? ''}')),
                      DataCell(
                        Text(_fmtSampleDateTime('${s['tested_at'] ?? ''}')),
                      ),
                      DataCell(
                        Text(
                          '${s['sample_taker'] ?? ''}'.trim().isEmpty
                              ? '-'
                              : '${s['sample_taker']}',
                        ),
                      ),
                      DataCell(Text('${_resultCount(s)}')),
                      DataCell(
                        '${s['decision_status'] ?? ''}'.isEmpty
                            ? Text(
                                AppText.t('بانتظار', 'Pending'),
                                style: TextStyle(
                                  fontSize: 12.spMax,
                                  color: AppColors.textMuted,
                                ),
                              )
                            : AppStatusBadge('${s['decision_status'] ?? ''}'),
                      ),
                      DataCell(
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: AppText.t('تعديل العينة', 'Edit sample'),
                              constraints: const BoxConstraints(
                                minWidth: 40,
                                minHeight: 40,
                              ),
                              onPressed: () => onEdit(s),
                              icon: Icon(Icons.edit_outlined, size: 19.r),
                            ),
                            IconButton(
                              tooltip: AppText.t('قرار', 'Decision'),
                              constraints: const BoxConstraints(
                                minWidth: 40,
                                minHeight: 40,
                              ),
                              onPressed: () => onDecision(s),
                              icon: Icon(Icons.fact_check_outlined, size: 19.r),
                            ),
                            IconButton(
                              tooltip: AppText.t('حذف', 'Delete'),
                              constraints: const BoxConstraints(
                                minWidth: 40,
                                minHeight: 40,
                              ),
                              onPressed: () => onDelete(s),
                              icon: Icon(
                                Icons.delete_outline,
                                size: 19.r,
                                color: AppColors.danger,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
          for (final s in ordered)
            if ((s['id'] as num).toInt() == expandedId) ...[
              const Divider(height: AppSpacing.lg),
              _SampleResultsTable(sample: s, onEdit: () => onEdit(s)),
            ],
        ],
      ),
    );
  }
}

/// The sample's own result tables inside one expanded row: physical rows
/// then multiple chemical rows, both read off the sample row itself.
class _SampleResultsTable extends StatelessWidget {
  const _SampleResultsTable({required this.sample, required this.onEdit});

  final Map<String, dynamic> sample;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final physical = decodeBatchPhysical(sample['physical_results_json']);
    final chemical = decodeBatchChemical(sample['chemical_results_json']);
    final taker = '${sample['sample_taker'] ?? ''}'.trim();
    final enteredBy =
        '${sample['tested_by_name_resolved'] ?? sample['tested_by_name'] ?? '-'}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '${sample['sample_no'] ?? ''} • ${sample['sample_name'] ?? ''}',
          style: TextStyle(
            fontSize: 13.spMax,
            fontWeight: FontWeight.w700,
            color: AppColors.textStrong,
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          '${AppText.t('أخذها', 'Taken by')}: ${taker.isEmpty ? '-' : taker}'
          ' • ${AppText.t('أدخلها', 'Entered by')}: $enteredBy'
          ' • ${_fmtSampleDateTime('${sample['tested_at'] ?? ''}')}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12.spMax, color: AppColors.textMuted),
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          AppText.t('النتائج الظاهرية', 'Physical results'),
          style: TextStyle(
            fontSize: 13.spMax,
            fontWeight: FontWeight.w700,
            color: AppColors.textStrong,
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        if (physical.isEmpty)
          Text(
            AppText.t('لا توجد نتائج ظاهرية.', 'No physical results.'),
            style: TextStyle(fontSize: 12.spMax, color: AppColors.textMuted),
          )
        else
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              headingRowColor: WidgetStatePropertyAll(
                AppColors.primary.withValues(alpha: 0.06),
              ),
              columns: [
                DataColumn(
                  label: Text(
                    AppText.t('البيان', 'Item'),
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
                DataColumn(
                  label: Text(
                    AppText.t('النتيجة', 'Result'),
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
              ],
              rows: [
                for (final e in physical.entries)
                  DataRow(
                    cells: [
                      DataCell(Text(e.key)),
                      DataCell(
                        Text(
                          e.value.isEmpty ? '-' : e.value,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          AppText.t('النتائج الكيميائية', 'Chemical results'),
          style: TextStyle(
            fontSize: 13.spMax,
            fontWeight: FontWeight.w700,
            color: AppColors.textStrong,
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        if (chemical.isEmpty)
          Text(
            AppText.t('لا توجد نتائج كيميائية.', 'No chemical results.'),
            style: TextStyle(fontSize: 12.spMax, color: AppColors.textMuted),
          )
        else
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              headingRowColor: WidgetStatePropertyAll(
                AppColors.primary.withValues(alpha: 0.06),
              ),
              columns: [
                DataColumn(
                  label: Text(
                    AppText.t('التحليل', 'Analysis'),
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
                DataColumn(
                  label: Text(
                    AppText.t('النتيجة', 'Result'),
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
                DataColumn(
                  label: Text(
                    AppText.t('الوحدة', 'Unit'),
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
              ],
              rows: [
                for (final r in chemical)
                  DataRow(
                    cells: [
                      DataCell(Text(r['name'] ?? '')),
                      DataCell(
                        Text(
                          (r['result'] ?? '').isEmpty ? '-' : r['result']!,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                      DataCell(Text(r['unit'] ?? '')),
                    ],
                  ),
              ],
            ),
          ),
        const SizedBox(height: AppSpacing.sm),
        AppButton(
          label: AppText.t('تعديل العينة ونتائجها', 'Edit sample & results'),
          icon: Icon(Icons.edit_outlined, size: 18.r),
          style: AppButtonStyle.secondary,
          expanded: true,
          onPressed: onEdit,
        ),
      ],
    );
  }
}

/// Template inherited from the product file (أصل الملف): the exact linked
/// items of the محضر. New samples inherit ALL of it — بيان names are fixed,
/// only per-sample values are filled.
class _BatchSampleTemplate {
  const _BatchSampleTemplate({
    this.physicalRef = const {},
    this.chemicalRef = const {},
    this.takerOptions = const [],
  });

  final Map<String, dynamic> physicalRef;
  final Map<String, dynamic> chemicalRef;
  final List<Map<String, dynamic>> takerOptions;

  bool get hasPhysical => physicalRef.isNotEmpty;
  bool get hasChemical => chemicalRef.isNotEmpty;
}

/// Collected sample form data: identity + the sample's own results.
class _SampleFormData {
  _SampleFormData({
    required this.name,
    required this.taker,
    required this.physical,
    required this.chemical,
  });

  final String name;
  final String taker;
  final Map<String, String> physical;
  final List<Map<String, String>> chemical;
}

class _PhysRow {
  /// Fixed بيان inherited from the محضر (never editable).
  final String item;
  final String refHint;
  final TextEditingController value = TextEditingController();

  /// Free legacy row (only when the product has no linked items at all).
  final TextEditingController? freeName;

  _PhysRow.fixed({required this.item, required this.refHint, String valueText = ''}) : freeName = null {
    value.text = valueText;
  }

  _PhysRow.free({String nameText = '', String valueText = ''})
      : item = '',
        refHint = '',
        freeName = TextEditingController(text: nameText) {
    value.text = valueText;
  }

  bool get isFixed => freeName == null;
  String get name => isFixed ? item : freeName!.text;

  void dispose() {
    value.dispose();
    freeName?.dispose();
  }
}

class _ChemRow {
  /// Fixed analysis inherited from the محضر (never editable/selectable).
  final String name;
  final String unit;
  final String refHint;
  final TextEditingController result = TextEditingController();

  /// Free legacy row (only when the product has no linked items at all).
  final TextEditingController? freeName;
  final TextEditingController? freeUnit;

  _ChemRow.fixed({
    required this.name,
    required this.unit,
    required this.refHint,
    String resultText = '',
  })  : freeName = null,
        freeUnit = null {
    result.text = resultText;
  }

  _ChemRow.free({String nameText = '', String resultText = '', String unitText = ''})
      : name = '',
        unit = '',
        refHint = '',
        freeName = TextEditingController(text: nameText),
        freeUnit = TextEditingController(text: unitText) {
    result.text = resultText;
  }

  bool get isFixed => freeName == null;
  String get effectiveName => isFixed ? name : freeName!.text;
  String get effectiveUnit => isFixed ? unit : freeUnit!.text;

  void dispose() {
    result.dispose();
    freeName?.dispose();
    freeUnit?.dispose();
  }
}

/// Sample form with full inheritance from the محضر: every linked physical
/// بيان (e.g. اللون) and every linked chemical analysis arrives pre-filled
/// per sample — values empty, units/reference shown. بيان names are fixed
/// labels (never free text, never dropdown), so a sample can never carry
/// بيان/قيمة مختلفة عن المرتبط في المحضر من البداية. التaker uses history
/// autocomplete. Everything is stored on the sample row itself — the lab
/// pipeline is never involved. Empty values are allowed: a sample may be
/// filed first and completed later through the edit action.
class _SampleForm extends StatefulWidget {
  const _SampleForm({required this.template, this.initial, required this.onSave});

  final _BatchSampleTemplate template;
  final Map<String, dynamic>? initial;
  final ValueChanged<_SampleFormData> onSave;

  @override
  State<_SampleForm> createState() => _SampleFormState();
}

class _SampleFormState extends State<_SampleForm> {
  late final TextEditingController _nameCtrl = TextEditingController(
    text: '${widget.initial?['sample_name'] ?? ''}',
  );
  late final TextEditingController _takerCtrl = TextEditingController(
    text: '${widget.initial?['sample_taker'] ?? ''}',
  );
  late final List<_PhysRow> _physRows;
  late final List<_ChemRow> _chemRows;

  bool get _physFixed => widget.template.hasPhysical;
  bool get _chemFixed => widget.template.hasChemical;

  @override
  void initState() {
    super.initState();
    final init = widget.initial;
    final physStored = init == null
        ? const <String, String>{}
        : decodeBatchPhysical(init['physical_results_json']);
    final chemStored = init == null
        ? const <Map<String, String>>[]
        : decodeBatchChemical(init['chemical_results_json']);
    final chemByName = {
      for (final r in chemStored) r['name'] ?? '': r,
    };
    if (_physFixed) {
      _physRows = [
        for (final e in widget.template.physicalRef.entries)
          _PhysRow.fixed(
            item: e.key,
            refHint: referenceValueText(e.value),
            valueText: physStored[e.key] ?? '',
          ),
      ];
    } else if (init != null && physStored.isNotEmpty) {
      _physRows = [
        for (final e in physStored.entries)
          _PhysRow.free(nameText: e.key, valueText: e.value),
      ];
    } else {
      _physRows = [_PhysRow.free()];
    }
    if (_chemFixed) {
      _chemRows = [
        for (final e in widget.template.chemicalRef.entries)
          _ChemRow.fixed(
            name: e.key,
            unit: referenceUnitText(e.value),
            refHint: referenceValueText(e.value),
            resultText: chemByName[e.key]?['result'] ?? '',
          ),
      ];
    } else if (init != null && chemStored.isNotEmpty) {
      _chemRows = [
        for (final r in chemStored)
          _ChemRow.free(
            nameText: r['name'] ?? '',
            resultText: r['result'] ?? '',
            unitText: r['unit'] ?? '',
          ),
      ];
    } else {
      _chemRows = [_ChemRow.free()];
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _takerCtrl.dispose();
    for (final r in _physRows) {
      r.dispose();
    }
    for (final r in _chemRows) {
      r.dispose();
    }
    super.dispose();
  }

  void _save() {
    final physical = <String, String>{};
    for (final r in _physRows) {
      // Fixed rows: same linked بيان for every sample, value per sample
      // (empty allowed — complete later). Free legacy rows: skip empties.
      if (r.isFixed) {
        physical[r.item] = r.value.text.trim();
      } else {
        final name = r.freeName!.text.trim();
        if (name.isEmpty) continue;
        physical[name] = r.value.text.trim();
      }
    }
    final chemical = <Map<String, String>>[];
    for (final r in _chemRows) {
      if (r.isFixed) {
        chemical.add({
          'name': r.name,
          'result': r.result.text.trim(),
          'unit': r.unit,
        });
      } else {
        final name = r.freeName!.text.trim();
        final result = r.result.text.trim();
        if (name.isEmpty && result.isEmpty) continue;
        chemical.add({
          'name': name,
          'result': result,
          'unit': r.freeUnit!.text.trim(),
        });
      }
    }
    widget.onSave(
      _SampleFormData(
        name: _nameCtrl.text,
        taker: _takerCtrl.text,
        physical: physical,
        chemical: chemical,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppField(
            label: AppText.t('اسم العينة (اختياري)', 'Sample name (optional)'),
            controller: _nameCtrl,
            hint: AppText.t(
              'اتركه فارغاً للترقيم التلقائي',
              'Leave empty for auto numbering',
            ),
            autofocus: true,
          ),
          const SizedBox(height: AppSpacing.md),
          AppHistoryAutocomplete(
            label: AppText.t('من أخذ العينة', 'Sample taker'),
            controller: _takerCtrl,
            options: widget.template.takerOptions,
            hint: AppText.t('اسم من سحب العينة', 'Who drew the sample'),
            textInputAction: TextInputAction.next,
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              Expanded(
                child: Text(
                  AppText.t('النتائج الظاهرية', 'Physical results'),
                  style: TextStyle(
                    fontSize: 13.spMax,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textStrong,
                  ),
                ),
              ),
              if (_physFixed)
                Text(
                  '${_physRows.length} ${AppText.t('من المحضر', 'from report')}',
                  style: TextStyle(
                    fontSize: 11.spMax,
                    color: AppColors.textMuted,
                  ),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          if (_physFixed && _physRows.isEmpty)
            Text(
              AppText.t(
                'لا توجد عناصر ظاهرية مرتبطة بهذا المنتج.',
                'No physical items linked to this product.',
              ),
              style: TextStyle(fontSize: 12.spMax, color: AppColors.textMuted),
            )
          else
            for (var i = 0; i < _physRows.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                child: _physRows[i].isFixed
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            flex: 2,
                            child: Padding(
                              padding: const EdgeInsets.only(top: 10),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _physRows[i].item,
                                    style: TextStyle(
                                      fontWeight: FontWeight.w700,
                                      fontSize: 13.spMax,
                                      color: AppColors.textStrong,
                                    ),
                                  ),
                                  if (_physRows[i].refHint.isNotEmpty)
                                    Text(
                                      _physRows[i].refHint,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 11.spMax,
                                        color: AppColors.textMuted,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          Expanded(
                            flex: 2,
                            child: AppField(
                              label: AppText.t('القيمة', 'Value'),
                              controller: _physRows[i].value,
                            ),
                          ),
                        ],
                      )
                    : Row(
                        children: [
                          Expanded(
                            flex: 2,
                            child: AppField(
                              label: AppText.t('البيان', 'Item'),
                              controller: _physRows[i].freeName!,
                            ),
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          Expanded(
                            flex: 2,
                            child: AppField(
                              label: AppText.t('النتيجة', 'Result'),
                              controller: _physRows[i].value,
                            ),
                          ),
                          IconButton(
                            tooltip: AppText.t('حذف الصف', 'Remove row'),
                            constraints: const BoxConstraints(
                              minWidth: 40,
                              minHeight: 40,
                            ),
                            onPressed: _physRows.length <= 1
                                ? null
                                : () => setState(
                                    () => _physRows.removeAt(i).dispose(),
                                  ),
                            icon: Icon(
                              Icons.remove_circle_outline,
                              size: 19.r,
                              color: AppColors.danger,
                            ),
                          ),
                        ],
                      ),
              ),
          if (!_physFixed)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                onPressed: () => setState(() => _physRows.add(_PhysRow.free())),
                icon: Icon(Icons.add, size: 18.r),
                label: Text(AppText.t('صف ظاهري', 'Physical row')),
              ),
            ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Expanded(
                child: Text(
                  AppText.t(
                    'النتائج الكيميائية (من المحضر)',
                    'Chemical results (from report)',
                  ),
                  style: TextStyle(
                    fontSize: 13.spMax,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textStrong,
                  ),
                ),
              ),
              if (_chemFixed)
                Text(
                  '${_chemRows.length} ${AppText.t('تحليل', 'analyses')}',
                  style: TextStyle(
                    fontSize: 11.spMax,
                    color: AppColors.textMuted,
                  ),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          if (_chemFixed && _chemRows.isEmpty)
            Text(
              AppText.t(
                'لا توجد تحاليل كيميائية مرتبطة بهذا المنتج.',
                'No chemical analyses linked to this product.',
              ),
              style: TextStyle(fontSize: 12.spMax, color: AppColors.textMuted),
            )
          else
            for (var i = 0; i < _chemRows.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                child: _chemRows[i].isFixed
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            flex: 3,
                            child: Padding(
                              padding: const EdgeInsets.only(top: 10),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _chemRows[i].name,
                                    style: TextStyle(
                                      fontWeight: FontWeight.w700,
                                      fontSize: 13.spMax,
                                      color: AppColors.textStrong,
                                    ),
                                  ),
                                  Text(
                                    [
                                      if (_chemRows[i].refHint.isNotEmpty)
                                        _chemRows[i].refHint,
                                      if (_chemRows[i].unit.isNotEmpty)
                                        _chemRows[i].unit,
                                    ].join(' • '),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 11.spMax,
                                      color: AppColors.textMuted,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          Expanded(
                            flex: 2,
                            child: AppField(
                              label: AppText.t('النتيجة', 'Result'),
                              controller: _chemRows[i].result,
                            ),
                          ),
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                flex: 3,
                                child: AppField(
                                  label: AppText.t('التحليل', 'Analysis'),
                                  controller: _chemRows[i].freeName!,
                                ),
                              ),
                              IconButton(
                                tooltip: AppText.t('حذف الصف', 'Remove row'),
                                constraints: const BoxConstraints(
                                  minWidth: 40,
                                  minHeight: 40,
                                ),
                                onPressed: _chemRows.length <= 1
                                    ? null
                                    : () => setState(
                                        () =>
                                            _chemRows.removeAt(i).dispose(),
                                      ),
                                icon: Icon(
                                  Icons.remove_circle_outline,
                                  size: 19.r,
                                  color: AppColors.danger,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: AppSpacing.xs),
                          Row(
                            children: [
                              Expanded(
                                flex: 3,
                                child: AppField(
                                  label: AppText.t('النتيجة', 'Result'),
                                  controller: _chemRows[i].result,
                                ),
                              ),
                              const SizedBox(width: AppSpacing.sm),
                              Expanded(
                                flex: 2,
                                child: AppField(
                                  label: AppText.t('الوحدة', 'Unit'),
                                  controller: _chemRows[i].freeUnit!,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
              ),
          if (!_chemFixed)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                onPressed: () => setState(() => _chemRows.add(_ChemRow.free())),
                icon: Icon(Icons.add, size: 18.r),
                label: Text(AppText.t('تحليل كيميائي', 'Chemical analysis')),
              ),
            ),
          const SizedBox(height: AppSpacing.md),
          AppButton(
            label: AppText.t('حفظ', 'Save'),
            expanded: true,
            onPressed: _save,
          ),
        ],
      ),
    );
  }
}
