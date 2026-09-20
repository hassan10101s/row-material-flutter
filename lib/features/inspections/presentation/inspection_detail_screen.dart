import 'package:flutter/material.dart';

import 'dart:convert';

import '../../../core/constants/app_strings.dart';
import '../../../core/utils/app_dates.dart';
import '../../../core/utils/app_exceptions.dart';
import '../../../design_system/feedback/app_feedback.dart';
import '../../../design_system/tokens/app_colors.dart';
import '../../../design_system/tokens/app_spacing.dart';
import '../../../design_system/widgets/app_button.dart';
import '../../../design_system/widgets/app_card.dart';
import '../../../design_system/widgets/app_status_badge.dart';
import '../../../app/auth_gate.dart';
import '../../../di/service_locator.dart';
import '../../reports/data/report_service.dart';
import '../data/inspection_repo.dart';
import 'inspection_widgets.dart';

/// Inspection detail: results vs reference, status history, decision
/// update and PDF export.
class InspectionDetailScreen extends StatefulWidget {
  final int inspectionId;
  const InspectionDetailScreen({super.key, required this.inspectionId});

  @override
  State<InspectionDetailScreen> createState() => _InspectionDetailScreenState();
}

class _InspectionDetailScreenState extends State<InspectionDetailScreen> {
  final _repo = getIt<InspectionRepo>();
  final _reports = getIt<ReportService>();

  Map<String, dynamic>? _inspection;
  List<Map<String, dynamic>> _history = [];
  bool _loading = true;
  String? _error;
  String _busy = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final inspection = await _repo.getById(widget.inspectionId);
      if (!mounted) return;
      setState(() {
        _inspection = inspection;
        _history = List<Map<String, dynamic>>.from(inspection['status_history'] ?? []);
        _loading = false;
      });
    } on AppError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _exportPdf(String kind) async {
    if (_busy.isNotEmpty) return;
    setState(() => _busy = kind);
    try {
      final doc = kind == 'label'
          ? await _reports.sampleLabelPdf(widget.inspectionId)
          : await _reports.inspectionReport(widget.inspectionId);
      final date = parseIsoDate('${_inspection?['inspection_date'] ?? ''}');
      final file = await _reports.saveReport(doc, date: date);
      if (!mounted) return;
      AppFeedback.success(context, 'تم التصدير | Exported: ${file.path}');
    } on AppError catch (e) {
      if (mounted) AppFeedback.error(context, e.message);
    } catch (e) {
      if (mounted) AppFeedback.error(context, '$e');
    } finally {
      if (mounted) setState(() => _busy = '');
    }
  }

  Future<void> _openDecisionDialog() async {
    final inspection = _inspection;
    if (inspection == null) return;
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => DecisionDialog(
        inspectionId: widget.inspectionId,
        inspection: inspection,
      ),
    );
    if (saved == true) {
      await _load();
      if (mounted) AppFeedback.success(context, 'تم تحديث القرار | Decision updated.');
    }
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('حذف الفحص | Delete inspection'),
        content:
            const Text('سيتم حذف الفحص نهائياً. هل أنت متأكد؟ | This removes the record permanently.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(AppStrings.cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(AppStrings.delete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _repo.delete(widget.inspectionId);
      if (mounted) {
        AppFeedback.success(context, 'تم الحذف | Deleted.');
        Navigator.of(context).pop(true);
      }
    } on AppError catch (e) {
      if (mounted) AppFeedback.error(context, e.message);
    } catch (e) {
      if (mounted) AppFeedback.error(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final inspection = _inspection;
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, style: TextStyle(color: AppColors.danger)),
            const SizedBox(height: AppSpacing.md),
            AppButton(
              style: AppButtonStyle.secondary,
              label: 'إعادة المحاولة | Retry',
              onPressed: _load,
            ),
          ],
        ),
      );
    }
    if (inspection == null) {
      return const Center(child: Text('غير موجود | Not found'));
    }

    final samples = _sampleLabels(inspection);
    final user = getIt<AuthGate>().currentUser;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.page),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${inspection['material_name']}',
                        style: Theme.of(context).textTheme.headlineSmall),
                    Text(
                      '${inspection['entry_code']} — ${inspection['material_code']}',
                      style: TextStyle(color: AppColors.textMuted),
                    ),
                  ],
                ),
              ),
              AppStatusBadge('${inspection['decision_status']}'),
              const SizedBox(width: AppSpacing.md),
              AppButton(
                style: AppButtonStyle.pdf,
                label: AppStrings.exportPdf,
                icon: const Icon(Icons.picture_as_pdf, size: 18),
                loading: _busy == 'report',
                onPressed: _busy.isEmpty ? () => _exportPdf('report') : null,
              ),
              const SizedBox(width: AppSpacing.sm),
              AppButton(
                style: AppButtonStyle.secondary,
                label: 'ملصق | Label',
                icon: const Icon(Icons.label_outline, size: 18),
                loading: _busy == 'label',
                onPressed: _busy.isEmpty ? () => _exportPdf('label') : null,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xl),
          Wrap(
            spacing: AppSpacing.xl,
            runSpacing: AppSpacing.sm,
            children: [
              InfoItem(
                  label: 'تاريخ الفحص | Date', value: '${inspection['inspection_date']}'),
              if ('${inspection['expiry_date'] ?? ''}'.trim().isNotEmpty)
                InfoItem(
                    label: 'تاريخ الانتهاء | Expiry', value: '${inspection['expiry_date']}'),
              InfoItem(label: 'المورد | Supplier', value: '${inspection['supplier']}'),
              if ('${inspection['truck_number'] ?? ''}'.trim().isNotEmpty)
                InfoItem(label: 'الشاحنة | Truck', value: '${inspection['truck_number']}'),
              InfoItem(label: 'الكمية | Qty', value: '${inspection['quantity']}'),
              InfoItem(
                  label: 'آخذ العينة | Sample taker', value: '${inspection['sample_taken_by']}'),
              InfoItem(
                  label: 'الأخصائي | Specialist', value: '${inspection['specialist_name']}'),
              InfoItem(label: 'النسخة | Version', value: '${inspection['decision_version']}'),
            ],
          ),
          if ('${inspection['decision_reason'] ?? ''}'.trim().isNotEmpty) ...[
            const SizedBox(height: AppSpacing.md),
            Text('سبب القرار | Reason: ${inspection['decision_reason']}'),
          ],
          if ('${inspection['follow_up_note'] ?? ''}'.trim().isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xs),
            Text('ملاحظة المتابعة | Follow-up: ${inspection['follow_up_note']}'),
          ],
          const SizedBox(height: AppSpacing.xl),
          ResultsCard(
            title: 'النتائج الفيزيائية | Physical results',
            reference: _asMap(inspection['physical_reference']),
            results: _asMap(inspection['physical_results']),
            samples: samples,
            numeric: false,
          ),
          const SizedBox(height: AppSpacing.md),
          ResultsCard(
            title: 'النتائج الكيميائية | Chemical results',
            reference: _asMap(inspection['chemical_reference']),
            results: _asMap(inspection['chemical_results']),
            samples: samples,
            numeric: true,
          ),
          if (_history.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.md),
            HistoryCard(history: _history),
          ],
          const SizedBox(height: AppSpacing.xl),
          Row(
            children: [
              AppButton(
                style: AppButtonStyle.accent,
                label: 'تحديث القرار | Update decision',
                icon: const Icon(Icons.gavel, size: 18),
                onPressed: (user?.canEditInspections ?? false) ? _openDecisionDialog : null,
              ),
              const SizedBox(width: AppSpacing.md),
              if (user?.canEditUsers ?? false)
                AppButton(
                  style: AppButtonStyle.danger,
                  label: AppStrings.delete,
                  icon: const Icon(Icons.delete_outline, size: 18),
                  onPressed: _delete,
                ),
            ],
          ),
        ],
      ),
    );
  }

  List<String> _sampleLabels(Map<String, dynamic> inspection) {
    final names = _jsonList(inspection['sample_names']);
    final labels = names.isEmpty ? <String>['Result'] : [for (final n in names) '$n'];
    while (labels.length < 3) {
      labels.add('Sample #${labels.length + 1}');
    }
    return labels;
  }

  Map<String, dynamic> _asMap(dynamic value) {
    if (value is Map) return Map<String, dynamic>.from(value);
    return const {};
  }

  List<dynamic> _jsonList(dynamic value) {
    if (value == null) return const [];
    if (value is List) return value;
    try {
      return jsonDecode('$value');
    } catch (_) {
      return const [];
    }
  }
}

/// Results vs reference table.
class ResultsCard extends StatelessWidget {
  final String title;
  final Map<String, dynamic> reference;
  final Map<String, dynamic> results;
  final List<String> samples;
  final bool numeric;

  const ResultsCard({
    super.key,
    required this.title,
    required this.reference,
    required this.results,
    required this.samples,
    required this.numeric,
  });

  @override
  Widget build(BuildContext context) {
    if (reference.isEmpty) return const SizedBox.shrink();
    final params = reference.keys.toList();
    return AppCard(
      padding: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: AppSpacing.sm),
            Table(
              columnWidths: const {
                0: FlexColumnWidth(2.2),
                1: FlexColumnWidth(1.8),
                2: FlexColumnWidth(3.4),
                3: FixedColumnWidth(28),
              },
              defaultVerticalAlignment: TableCellVerticalAlignment.middle,
              children: [
                const TableRow(
                  children: [
                    Padding(
                      padding: EdgeInsets.symmetric(vertical: 6),
                      child: Text('الخاصية | Parameter',
                          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
                    ),
                    Padding(
                      padding: EdgeInsets.symmetric(vertical: 6),
                      child: Text('المرجعية | Reference',
                          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
                    ),
                    Padding(
                      padding: EdgeInsets.symmetric(vertical: 6),
                      child: Text('النتيجة | Result',
                          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
                    ),
                    SizedBox(),
                  ],
                ),
                for (final param in params)
                  TableRow(
                    children: _rowFor(param),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _rowFor(String param) {
    final ref = '${reference[param] ?? ''}';
    dynamic value = results[param];
    final List<dynamic> values = value is List
        ? value
        : value == null || '$value'.trim().isEmpty
            ? <dynamic>[]
            : <dynamic>[value];

    final cells = <Widget>[
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text(param, style: const TextStyle(fontSize: 13)),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text(ref,
            style: TextStyle(color: AppColors.textMuted, fontSize: 13)),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: values.isEmpty
            ? Text('—', style: TextStyle(color: AppColors.textMuted, fontSize: 13))
            : Wrap(
                spacing: AppSpacing.lg,
                children: [
                  for (var i = 0; i < values.length; i++)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (values.length > 1)
                          Text('${samples[i]} ',
                              style: TextStyle(color: AppColors.textMuted, fontSize: 12)),
                        Text('${values[i]}', style: const TextStyle(fontSize: 13)),
                      ],
                    ),
                ],
              ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: _statusIcon(ref, values),
      ),
    ];
    return cells;
  }

  Widget _statusIcon(String ref, List<dynamic> values) {
    if (!numeric || ref.trim().isEmpty || values.isEmpty) {
      return const SizedBox();
    }
    final anyFail = values.any((v) =>
        checkResultPass(reference: ref, value: '$v', numeric: true).pass == false);
    if (anyFail) {
      return Icon(Icons.close, size: 16, color: AppColors.danger);
    }
    return Icon(Icons.check_circle_outline, size: 16, color: AppColors.success);
  }
}

/// Status-history timeline.
class HistoryCard extends StatelessWidget {
  final List<Map<String, dynamic>> history;
  const HistoryCard({super.key, required this.history});

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('سجل القرارات | Decision history',
                style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: AppSpacing.sm),
            for (final row in history)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.timeline, size: 16),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: AppSpacing.sm,
                        runSpacing: 4,
                        children: [
                          AppStatusBadge('${row['new_status']}'),
                          Text(
                            'النسخة ${row['version']} | v${row['version']}'
                            ' by ${row['changed_by_name']} — ${row['changed_at']}',
                            style: TextStyle(color: AppColors.textMuted, fontSize: 12),
                          ),
                          if ('${row['change_reason'] ?? ''}'.trim().isNotEmpty)
                            Text('سبب: ${row['change_reason']}',
                                style: const TextStyle(fontSize: 12)),
                          if ('${row['follow_up_note'] ?? ''}'.trim().isNotEmpty)
                            Text('متابعة: ${row['follow_up_note']}',
                                style: const TextStyle(fontSize: 12)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}