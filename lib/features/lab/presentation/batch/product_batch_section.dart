import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../../app/auth_gate.dart';
import '../../../../../core/constants/app_strings.dart';
import '../../../../../core/utils/app_dates.dart';
import '../../../../../core/utils/app_format.dart';
import '../../../../../core/utils/reference_range.dart';
import '../../../../../design_system/feedback/app_error_feedback.dart';
import '../../../../../design_system/feedback/app_feedback.dart';
import '../../../../../design_system/tokens/app_colors.dart';
import '../../../../../design_system/tokens/app_spacing.dart';
import '../../../../../design_system/widgets/app_adaptive.dart';
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

/// Chemical result fields accept numbers only (no letters): digits with at
/// most one decimal point, matching the raw-material form's normalization.
final _decimalOnlyFormatter = TextInputFormatter.withFunction(
  (oldValue, newValue) {
    final t = newValue.text;
    if (t.isEmpty || RegExp(r'^\d*\.?\d*$').hasMatch(t)) return newValue;
    return oldValue;
  },
);

/// Physical-value suggestions for one sample row: the محضر's own reference
/// values (raw numbers + separated options) plus the standard qualitative
/// keywords — the same autocomplete idea as the raw-material inspection form.
List<String> _physicalValueSuggestions(Object? reference) {
  final out = <String>[];
  final seen = <String>{};
  void add(String s) {
    final c = s.trim();
    if (c.isNotEmpty && seen.add(c.toLowerCase())) out.add(c);
  }

  final text = referenceValueText(reference).trim();
  if (text.isNotEmpty) {
    add(text);
    for (final p in text.split(RegExp(r'[|،,/]+'))) {
      add(p);
    }
  }
  for (final m in RegExp(r'-?\d+(?:\.\d+)?')
      .allMatches(formatReferenceRange(reference).display)) {
    add(m.group(0)!);
  }
  for (final k in const [
    'Normal',
    'Good',
    'Acceptable',
    'Very Good',
    'OK',
    'Abnormal',
    'Not Good',
    'Pale',
    'No',
  ]) {
    add(k);
  }
  return out;
}

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
            // Sequential sample-after-sample ledger (عينة وراء عينة):
            // one row per sample in sample_no order with taker, date+hour
            // and result counts. Tapping a row expands its own tables.
            // The phone renders the same ledger as cards - the 7-column
            // table would need a horizontal scroll that hides the actions.
            appAdaptiveVariant(
              context,
              desktop: (ctx) => _SamplesSequentialTable(
                samples: state.samples,
                expandedId: _expandedSampleId,
                onToggle: (id) => setState(() {
                  _expandedSampleId = _expandedSampleId == id ? null : id;
                }),
                onEdit: (s) => _editSample(ctx, s),
                onDecision: (s) => _setDecision(ctx, s),
                onDelete: (s) => _deleteSample(ctx, s),
              ),
              mobile: (ctx) => _SamplesMobileList(
                samples: state.samples,
                expandedId: _expandedSampleId,
                onToggle: (id) => setState(() {
                  _expandedSampleId = _expandedSampleId == id ? null : id;
                }),
                onEdit: (s) => _editSample(ctx, s),
                onDecision: (s) => _setDecision(ctx, s),
                onDelete: (s) => _deleteSample(ctx, s),
              ),
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
/// Hovering over any row displays a rich summary tooltip of physical and chemical results.
/// Tapping a row opens that sample's own detailed physical + chemical tables below.
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

  static String _buildSampleHoverTooltip(Map<String, dynamic> s) {
    final physical = decodeBatchPhysical(s['physical_results_json']);
    final chemical = decodeBatchChemical(s['chemical_results_json']);
    final buffer = StringBuffer();

    final sampleNo = s['sample_no'] != null ? '#${s['sample_no']} ' : '';
    buffer.writeln('🧪 $sampleNo${s['sample_name'] ?? ''}');

    final taker = '${s['sample_taker'] ?? ''}'.trim();
    if (taker.isNotEmpty) {
      buffer.writeln('${AppText.t('أخذها', 'Taken by')}: $taker');
    }
    final date = _fmtSampleDateTime('${s['tested_at'] ?? ''}');
    if (date != '-') {
      buffer.writeln('${AppText.t('التاريخ والساعة', 'Date & time')}: $date');
    }

    buffer.writeln('\n📋 ${AppText.t('النتائج الظاهرية / الفيزيائية:', 'Physical results:')}');
    if (physical.isEmpty) {
      buffer.writeln('  ${AppText.t('(لا توجد نتائج مسجلة)', '(No results recorded)')}');
    } else {
      for (final e in physical.entries) {
        buffer.writeln('  • ${e.key}: ${e.value.isEmpty ? '-' : e.value}');
      }
    }

    buffer.writeln('\n🔬 ${AppText.t('النتائج الكيميائية:', 'Chemical results:')}');
    if (chemical.isEmpty) {
      buffer.writeln('  ${AppText.t('(لا توجد نتائج مسجلة)', '(No results recorded)')}');
    } else {
      for (final r in chemical) {
        final unit = (r['unit'] ?? '').isEmpty ? '' : ' ${r['unit']}';
        buffer.writeln('  • ${r['name']}: ${r['result'] ?? '-'}$unit');
      }
    }

    final decision = '${s['decision_status'] ?? ''}'.trim();
    if (decision.isNotEmpty) {
      buffer.writeln('\n⚖️ ${AppText.t('القرار', 'Decision')}: $decision');
    }

    buffer.writeln('\n💡 ${AppText.t('انقر بالماوس لتثبيت وعرض التفاصيل بالأسفل', 'Click row to pin & view details below')}');
    return buffer.toString().trim();
  }

  Widget _cellWithTooltip({
    required Widget child,
    required Map<String, dynamic> sample,
  }) {
    return Tooltip(
      message: _buildSampleHoverTooltip(sample),
      waitDuration: const Duration(milliseconds: 200),
      showDuration: const Duration(seconds: 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadii.md),
        border: Border.all(
          color: AppColors.primary.withValues(alpha: 0.35),
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.14),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      textStyle: TextStyle(
        color: AppColors.textStrong,
        fontSize: 12.spMax,
        height: 1.45,
      ),
      child: child,
    );
  }

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
    final isRtl = Directionality.of(context) == TextDirection.rtl;

    return AppCard(
      enableHover: false,
      padding: const EdgeInsets.all(AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              showCheckboxColumn: false,
              headingRowColor: WidgetStatePropertyAll(
                AppColors.primary.withValues(alpha: 0.08),
              ),
              dataRowColor: WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.selected)) {
                  return AppColors.primary.withValues(alpha: 0.12);
                }
                if (states.contains(WidgetState.hovered)) {
                  return AppColors.primary.withValues(alpha: 0.05);
                }
                return Colors.transparent;
              }),
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
                for (final s in ordered) ...[
                  () {
                    final isExpanded = (s['id'] as num?)?.toInt() == expandedId;
                    return DataRow(
                      key: ValueKey('batch-sample-${s['id']}'),
                      selected: isExpanded,
                      onSelectChanged: (_) => onToggle((s['id'] as num).toInt()),
                      mouseCursor: const WidgetStatePropertyAll(SystemMouseCursors.click),
                      cells: [
                        DataCell(
                          _cellWithTooltip(
                            sample: s,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  isExpanded
                                      ? Icons.keyboard_arrow_down
                                      : (isRtl
                                          ? Icons.keyboard_arrow_left
                                          : Icons.keyboard_arrow_right),
                                  size: 18.r,
                                  color: isExpanded
                                      ? AppColors.primary
                                      : AppColors.textMuted,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  '${s['sample_no'] ?? ''}',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w700,
                                    color: isExpanded
                                        ? AppColors.primary
                                        : AppColors.textStrong,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        DataCell(
                          _cellWithTooltip(
                            sample: s,
                            child: Text(
                              '${s['sample_name'] ?? ''}',
                              style: TextStyle(
                                fontWeight: isExpanded
                                    ? FontWeight.w700
                                    : FontWeight.normal,
                                color: isExpanded
                                    ? AppColors.primary
                                    : AppColors.textStrong,
                              ),
                            ),
                          ),
                        ),
                        DataCell(
                          _cellWithTooltip(
                            sample: s,
                            child: Text(_fmtSampleDateTime('${s['tested_at'] ?? ''}')),
                          ),
                        ),
                        DataCell(
                          _cellWithTooltip(
                            sample: s,
                            child: Text(
                              '${s['sample_taker'] ?? ''}'.trim().isEmpty
                                  ? '-'
                                  : '${s['sample_taker']}',
                            ),
                          ),
                        ),
                        DataCell(
                          _cellWithTooltip(
                            sample: s,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: AppColors.primary.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(AppRadii.pill),
                              ),
                              child: Text(
                                '${_resultCount(s)}',
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.primary,
                                ),
                              ),
                            ),
                          ),
                        ),
                        DataCell(
                          _cellWithTooltip(
                            sample: s,
                            child: '${s['decision_status'] ?? ''}'.isEmpty
                                ? Text(
                                    AppText.t('بانتظار', 'Pending'),
                                    style: TextStyle(
                                      fontSize: 12.spMax,
                                      color: AppColors.textMuted,
                                    ),
                                  )
                                : AppStatusBadge('${s['decision_status'] ?? ''}'),
                          ),
                        ),
                        DataCell(
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: AppText.t('تعديل العينة', 'Edit sample'),
                                constraints: const BoxConstraints(
                                  minWidth: 36,
                                  minHeight: 36,
                                ),
                                onPressed: () => onEdit(s),
                                icon: Icon(Icons.edit_outlined, size: 18.r),
                              ),
                              IconButton(
                                tooltip: AppText.t('قرار', 'Decision'),
                                constraints: const BoxConstraints(
                                  minWidth: 36,
                                  minHeight: 36,
                                ),
                                onPressed: () => onDecision(s),
                                icon: Icon(Icons.fact_check_outlined, size: 18.r),
                              ),
                              IconButton(
                                tooltip: AppText.t('حذف', 'Delete'),
                                constraints: const BoxConstraints(
                                  minWidth: 36,
                                  minHeight: 36,
                                ),
                                onPressed: () => onDelete(s),
                                icon: Icon(
                                  Icons.delete_outline,
                                  size: 18.r,
                                  color: AppColors.danger,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    );
                  }(),
                ],
              ],
            ),
          ),
          for (final s in ordered)
            if ((s['id'] as num).toInt() == expandedId) ...[
              const SizedBox(height: AppSpacing.md),
              _SampleResultsTable(sample: s, onEdit: () => onEdit(s)),
            ],
        ],
      ),
    );
  }
}

/// The phone experience of the per-sample ledger: cards instead of the
/// 7-column table. The expanded sample's own results tables are inlined
/// beneath the tapped card, so the same tap-to-expand behaviour survives.
class _SamplesMobileList extends StatelessWidget {
  const _SamplesMobileList({
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

  @override
  Widget build(BuildContext context) {
    final ordered = [...samples]..sort((a, b) {
      final na = (a['sample_no'] as num?)?.toInt() ?? 0;
      final nb = (b['sample_no'] as num?)?.toInt() ?? 0;
      if (na != nb) return na.compareTo(nb);
      return ((a['id'] as num?)?.toInt() ?? 0).compareTo(
        (b['id'] as num?)?.toInt() ?? 0,
      );
    });
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
          child: Row(
            children: [
              Text(
                AppText.t('#', '#'),
                style: TextStyle(
                  fontSize: 12.spMax,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textMuted,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  AppText.t('العينة', 'Sample'),
                  style: TextStyle(
                    fontSize: 12.spMax,
                    fontWeight: FontWeight.w800,
                    color: AppColors.textMuted,
                  ),
                ),
              ),
              Text(
                AppText.t('النتائج', 'Results'),
                style: TextStyle(
                  fontSize: 12.spMax,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textMuted,
                ),
              ),
            ],
          ),
        ),
        for (final s in ordered) ...[
          _SampleMobileCard(
            sample: s,
            expanded: (s['id'] as num).toInt() == expandedId,
            onToggle: () => onToggle((s['id'] as num).toInt()),
            onEdit: () => onEdit(s),
            onDecision: () => onDecision(s),
            onDelete: () => onDelete(s),
          ),
          if ((s['id'] as num).toInt() == expandedId) ...[
            const SizedBox(height: AppSpacing.sm),
            _SampleResultsTable(sample: s, onEdit: () => onEdit(s)),
          ],
          const SizedBox(height: AppSpacing.sm),
        ],
      ],
    );
  }
}

/// One sample as a card: identity + status on top, taker/date/results
/// underneath, then the three per-sample actions with phone-sized targets.
class _SampleMobileCard extends StatelessWidget {
  const _SampleMobileCard({
    required this.sample,
    required this.expanded,
    required this.onToggle,
    required this.onEdit,
    required this.onDecision,
    required this.onDelete,
  });

  final Map<String, dynamic> sample;
  final bool expanded;
  final VoidCallback onToggle;
  final VoidCallback onEdit;
  final VoidCallback onDecision;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final decision = '${sample['decision_status'] ?? ''}'.trim();
    final resultCount =
        decodeBatchPhysical(sample['physical_results_json']).length +
        decodeBatchChemical(sample['chemical_results_json']).length;
    final isRtl = Directionality.of(context) == TextDirection.rtl;

    return AppCard(
      enableHover: false,
      padding: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(12.r),
        onTap: onToggle,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    expanded
                        ? Icons.keyboard_arrow_down
                        : (isRtl
                            ? Icons.keyboard_arrow_left
                            : Icons.keyboard_arrow_right),
                    size: 18.r,
                    color: expanded ? AppColors.primary : AppColors.textMuted,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '${sample['sample_no'] ?? ''}',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 13.spMax,
                      color: expanded ? AppColors.primary : AppColors.textStrong,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      '${sample['sample_name'] ?? ''}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14.spMax,
                        color: expanded ? AppColors.primary : AppColors.textStrong,
                      ),
                    ),
                  ),
                  if (decision.isNotEmpty) AppStatusBadge(decision),
                ],
              ),
              const SizedBox(height: AppSpacing.xs),
              Wrap(
                spacing: AppSpacing.md,
                runSpacing: 2,
                children: [
                  Text(
                    _fmtSampleDateTime('${sample['tested_at'] ?? ''}'),
                    style: TextStyle(
                      fontSize: 12.spMax,
                      color: AppColors.textMuted,
                    ),
                  ),
                  Text(
                    '${AppText.t('أخذها', 'Taken by')}: ${'${sample['sample_taker'] ?? ''}'.trim().isEmpty ? '-' : sample['sample_taker']}',
                    style: TextStyle(
                      fontSize: 12.spMax,
                      color: AppColors.textMuted,
                    ),
                  ),
                  Text(
                    '${AppText.t('النتائج', 'Results')}: $resultCount',
                    style: TextStyle(
                      fontSize: 12.spMax,
                      color: AppColors.textMuted,
                    ),
                  ),
                ],
              ),
              Row(
                children: [
                  const Spacer(),
                  IconButton(
                    key: ValueKey('batch-mobile-edit-${sample['id']}'),
                    tooltip: AppText.t('تعديل العينة', 'Edit sample'),
                    constraints: const BoxConstraints(
                      minWidth: 44,
                      minHeight: 44,
                    ),
                    onPressed: onEdit,
                    icon: Icon(Icons.edit_outlined, size: 20.r),
                  ),
                  IconButton(
                    tooltip: AppText.t('قرار', 'Decision'),
                    constraints: const BoxConstraints(
                      minWidth: 44,
                      minHeight: 44,
                    ),
                    onPressed: onDecision,
                    icon: Icon(Icons.fact_check_outlined, size: 20.r),
                  ),
                  IconButton(
                    tooltip: AppText.t('حذف', 'Delete'),
                    constraints: const BoxConstraints(
                      minWidth: 44,
                      minHeight: 44,
                    ),
                    onPressed: onDelete,
                    icon: Icon(
                      Icons.delete_outline,
                      size: 20.r,
                      color: AppColors.danger,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
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
    final decision = '${sample['decision_status'] ?? ''}'.trim();

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceSoft.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(AppRadii.lg),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.25)),
      ),
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header of expanded sample
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppRadii.md),
                ),
                child: Icon(
                  Icons.science_outlined,
                  color: AppColors.primary,
                  size: 20.r,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: AppSpacing.xs,
                      runSpacing: AppSpacing.xs,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          '${sample['sample_no'] ?? ''} • ${sample['sample_name'] ?? ''}',
                          style: TextStyle(
                            fontSize: 14.spMax,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textStrong,
                          ),
                        ),
                        if (decision.isNotEmpty) AppStatusBadge(decision),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${AppText.t('أخذها', 'Taken by')}: ${taker.isEmpty ? '-' : taker}'
                      ' • ${AppText.t('أدخلها', 'Entered by')}: $enteredBy'
                      ' • ${_fmtSampleDateTime('${sample['tested_at'] ?? ''}')}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12.spMax, color: AppColors.textMuted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          const Divider(height: 1),
          const SizedBox(height: AppSpacing.md),

          // Physical results section
          Row(
            children: [
              Icon(Icons.visibility_outlined, size: 18.r, color: AppColors.primary),
              const SizedBox(width: AppSpacing.xs),
              Text(
                AppText.t('النتائج الظاهرية والفيزيائية', 'Physical results'),
                style: TextStyle(
                  fontSize: 13.spMax,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textStrong,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          if (physical.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
              child: Text(
                AppText.t('لا توجد نتائج ظاهرية مسجلة لهذه العينة.', 'No physical results.'),
                style: TextStyle(fontSize: 12.spMax, color: AppColors.textMuted),
              ),
            )
          else
            Container(
              margin: const EdgeInsets.only(top: AppSpacing.xs),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(AppRadii.md),
                border: Border.all(color: AppColors.borderMuted),
              ),
              clipBehavior: Clip.antiAlias,
              child: DataTable(
                headingRowColor: WidgetStatePropertyAll(
                  AppColors.primary.withValues(alpha: 0.05),
                ),
                columns: [
                  DataColumn(
                    label: Text(
                      AppText.t('البيان / الفحص', 'Item / Test'),
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
                        DataCell(Text(e.key, style: const TextStyle(fontWeight: FontWeight.w600))),
                        DataCell(
                          Text(
                            e.value.isEmpty ? '-' : e.value,
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: AppColors.textStrong,
                            ),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),

          const SizedBox(height: AppSpacing.lg),

          // Chemical results section
          Row(
            children: [
              Icon(Icons.biotech_outlined, size: 18.r, color: AppColors.primary),
              const SizedBox(width: AppSpacing.xs),
              Text(
                AppText.t('النتائج الكيميائية والمعملية', 'Chemical results'),
                style: TextStyle(
                  fontSize: 13.spMax,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textStrong,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          if (chemical.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
              child: Text(
                AppText.t('لا توجد نتائج كيميائية مسجلة لهذه العينة.', 'No chemical results.'),
                style: TextStyle(fontSize: 12.spMax, color: AppColors.textMuted),
              ),
            )
          else
            Container(
              margin: const EdgeInsets.only(top: AppSpacing.xs),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(AppRadii.md),
                border: Border.all(color: AppColors.borderMuted),
              ),
              clipBehavior: Clip.antiAlias,
              child: DataTable(
                headingRowColor: WidgetStatePropertyAll(
                  AppColors.primary.withValues(alpha: 0.05),
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
                        DataCell(Text(r['name'] ?? '', style: const TextStyle(fontWeight: FontWeight.w600))),
                        DataCell(
                          Text(
                            (r['result'] ?? '').isEmpty ? '-' : r['result']!,
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: AppColors.primary,
                            ),
                          ),
                        ),
                        DataCell(Text(r['unit'] ?? '')),
                      ],
                    ),
                ],
              ),
            ),
          const SizedBox(height: AppSpacing.md),
          AppButton(
            label: AppText.t('تعديل العينة ونتائجها', 'Edit sample & results'),
            icon: Icon(Icons.edit_outlined, size: 18.r),
            style: AppButtonStyle.secondary,
            expanded: true,
            onPressed: onEdit,
          ),
        ],
      ),
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

  /// Raw reference value (map/text/number) powering the value suggestions.
  final Object? reference;
  final TextEditingController value = TextEditingController();

  /// Free legacy row (only when the product has no linked items at all).
  final TextEditingController? freeName;

  _PhysRow.fixed({
    required this.item,
    required this.refHint,
    this.reference,
    String valueText = '',
  }) : freeName = null {
    value.text = valueText;
  }

  _PhysRow.free({String nameText = '', String valueText = ''})
      : item = '',
        refHint = '',
        reference = null,
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
            reference: e.value,
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

  /// Physical value input with the reference-derived suggestion dropdown
  /// (raw-material parity); free rows fall back to the standard keywords.
  Widget _physicalValueField(String label, _PhysRow row) {
    final suggestions = _physicalValueSuggestions(row.reference);
    return AppField(
      label: label,
      controller: row.value,
      suffix: suggestions.isEmpty
          ? null
          : PopupMenuButton<String>(
              tooltip: AppText.t('اقتراحات', 'Suggestions'),
              onSelected: (v) => setState(() => row.value.text = v),
              itemBuilder: (_) => [
                for (final s in suggestions)
                  PopupMenuItem(value: s, child: Text(s)),
              ],
              child: Icon(
                Icons.arrow_drop_down,
                size: 20.r,
                color: AppColors.textMuted,
              ),
            ),
    );
  }

  /// Chemical result input: numbers only (letters are rejected).
  Widget _chemicalResultField(String label, TextEditingController ctrl) {
    return AppField(
      label: label,
      controller: ctrl,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [_decimalOnlyFormatter],
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
                            child: _physicalValueField(
                              AppText.t('القيمة', 'Value'),
                              _physRows[i],
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
                            child: _physicalValueField(
                              AppText.t('النتيجة', 'Result'),
                              _physRows[i],
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
                            child: _chemicalResultField(
                              AppText.t('النتيجة', 'Result'),
                              _chemRows[i].result,
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
                                child: _chemicalResultField(
                                  AppText.t('النتيجة', 'Result'),
                                  _chemRows[i].result,
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
