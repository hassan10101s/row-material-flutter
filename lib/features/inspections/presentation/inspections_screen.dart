import 'package:flutter/material.dart';

import '../../../app/auth_gate.dart';
import '../../../core/constants/app_strings.dart';
import '../../../core/utils/app_dates.dart';
import '../../../core/utils/app_exceptions.dart';
import '../../../design_system/feedback/app_feedback.dart';
import '../../../design_system/tokens/app_colors.dart';
import '../../../design_system/tokens/app_spacing.dart';
import '../../../design_system/widgets/app_button.dart';
import '../../../design_system/widgets/app_card.dart';
import '../../../design_system/widgets/app_empty_state.dart';
import '../../../design_system/widgets/app_status_badge.dart';
import '../../../di/service_locator.dart';
import '../../reports/data/report_service.dart';
import '../data/inspection_repo.dart';
import 'inspection_detail_screen.dart';
import 'inspection_form_screen.dart';

const _allStatuses = [
  'APPROVED',
  'CONDITIONAL_APPROVAL',
  'PARTIAL_REJECTION',
  'FULL_REJECTION',
];

/// Inspections ledger: search, filter, create, PDFs and follow-up report.
class InspectionsScreen extends StatefulWidget {
  const InspectionsScreen({super.key});

  @override
  State<InspectionsScreen> createState() => _InspectionsScreenState();
}

class _InspectionsScreenState extends State<InspectionsScreen> {
  final _repo = getIt<InspectionRepo>();
  final _reports = getIt<ReportService>();

  List<Map<String, dynamic>> _rows = [];
  List<Map<String, dynamic>> _visible = [];
  String _query = '';
  String _status = '';
  bool _loading = true;
  bool _exporting = false;
  String? _error;

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
      final rows = await _repo.list(orderBy: 'inspection_date DESC, id DESC');
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _applyFilters();
        _loading = false;
      });
    } on AppError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _applyFilters() {
    final q = _query.trim().toLowerCase();
    final list = q.isEmpty
        ? _rows
        : [
            for (final r in _rows)
              if ('${r['entry_code']}'.toLowerCase().contains(q) ||
                  '${r['material_name']}'.toLowerCase().contains(q) ||
                  '${r['supplier']}'.toLowerCase().contains(q) ||
                  '${r['truck_number']}'.toLowerCase().contains(q))
                r,
          ];
    _visible = _status.isEmpty
        ? list
        : [for (final r in list) if ('${r['decision_status']}' == _status) r];
  }

  Future<void> _newInspection() async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const InspectionFormScreen()),
    );
    if (saved == true) {
      _load();
    }
  }

  Future<void> _openDetail(Map<String, dynamic> row) async {
    final id = (row['id'] as num).toInt();
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => InspectionDetailScreen(inspectionId: id)),
    );
    if (changed == true) _load();
  }

  Future<void> _exportFollowUp() async {
    if (_visible.isEmpty) {
      AppFeedback.error(context, 'لا توجد فحوصات للتقرير | Nothing to report.');
      return;
    }
    setState(() => _exporting = true);
    try {
      final doc = await _reports.followUpReport([
        for (final r in _visible) (r['id'] as num).toInt(),
      ]);
      final file = await _reports.saveReport(doc);
      if (!mounted) return;
      AppFeedback.success(context, 'تم التصدير | Exported: ${file.path}');
    } on AppError catch (e) {
      if (mounted) AppFeedback.error(context, e.message);
    } catch (e) {
      if (mounted) AppFeedback.error(context, '$e');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = getIt<AuthGate>().currentUser;
    final canCreate = user?.canCreateInspection ?? false;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.page),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(AppStrings.inspections, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              Expanded(
                child: TextField(
                  onChanged: (v) => setState(() {
                    _query = v;
                    _applyFilters();
                  }),
                  decoration: const InputDecoration(
                    labelText: 'بحث | Search',
                    isDense: true,
                    prefixIcon: Icon(Icons.search, size: 20),
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              SizedBox(
                width: 260,
                child: DropdownButtonFormField<String>(
                  initialValue: _status,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'الحالة | Status',
                    isDense: true,
                  ),
                  items: [
                    const DropdownMenuItem(value: '', child: Text('الكل | All')),
                    for (final s in _allStatuses)
                      DropdownMenuItem(value: s, child: Text(statusLabel(s))),
                  ],
                  onChanged: (v) => setState(() {
                    _status = v ?? '';
                    _applyFilters();
                  }),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              AppButton(
                icon: const Icon(Icons.description_outlined, size: 18),
                label: 'تقرير متابعة | Follow-up',
                style: AppButtonStyle.secondary,
                loading: _exporting,
                onPressed: _exporting ? null : _exportFollowUp,
              ),
              const SizedBox(width: AppSpacing.md),
              if (canCreate)
                AppButton(
                  icon: const Icon(Icons.add, size: 18),
                  label: AppStrings.newInspection,
                  onPressed: _newInspection,
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          if (_loading) ...[
            const Center(child: CircularProgressIndicator()),
          ] else if (_error != null) ...[
            Text(_error!, style: TextStyle(color: AppColors.danger)),
          ] else if (_visible.isEmpty) ...[
            const AppEmptyState(
              icon: Icons.inventory_2_outlined,
              title: 'لا توجد فحوصات | No inspections',
              subtitle: 'ابدأ بفحص جديد أو عدّل معايير البحث.',
            ),
          ] else
            AppCard(
              padding: EdgeInsets.zero,
              child: SizedBox(
                width: double.infinity,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    columns: const [
                      DataColumn(label: Text('رقم القيد | Entry')),
                      DataColumn(label: Text('التاريخ | Date')),
                      DataColumn(label: Text('المادة | Material')),
                      DataColumn(label: Text('المورد | Supplier')),
                      DataColumn(label: Text('الكمية | Qty')),
                      DataColumn(label: Text('القرار | Decision')),
                      DataColumn(label: Text(''), numeric: true),
                    ],
                    rows: [
                      for (final r in _visible)
                        DataRow(
                          onSelectChanged: (_) => _openDetail(r),
                          cells: [
                            DataCell(Text('${r['entry_code']}')),
                            DataCell(Text(parseIsoToDisplay('${r['inspection_date']}') ?? '')),
                            DataCell(
                              Text('${r['material_name']}',
                                  overflow: TextOverflow.ellipsis),
                            ),
                            DataCell(Text('${r['supplier']}',
                                overflow: TextOverflow.ellipsis)),
                            DataCell(Text('${r['quantity']}')),
                            DataCell(AppStatusBadge('${r['decision_status']}')),
                            DataCell(
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  _IconAction(
                                    tooltip: 'تحديث القرار | Decision',
                                    icon: Icons.gavel_outlined,
                                    onTap: () => _openDecision(r),
                                  ),
                                  _IconAction(
                                    tooltip: 'تصدير PDF | PDF',
                                    icon: Icons.picture_as_pdf_outlined,
                                    onTap: () => _exportOne(r, 'report'),
                                  ),
                                  _IconAction(
                                    tooltip: 'ملصق | Label',
                                    icon: Icons.label_outline,
                                    onTap: () => _exportOne(r, 'label'),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
            ),
          const SizedBox(height: AppSpacing.sm),
          if (!_loading && _error == null)
            Text('${_visible.length} من ${_rows.length} فحص | of inspections',
                style: TextStyle(color: AppColors.textMuted, fontSize: 12)),
        ],
      ),
    );
  }

  Future<void> _openDecision(Map<String, dynamic> row) async {
    final id = (row['id'] as num).toInt();
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => InspectionDetailScreen(inspectionId: id)),
    );
    if (changed == true) _load();
  }

  Future<void> _exportOne(Map<String, dynamic> row, String kind) async {
    final id = (row['id'] as num).toInt();
    try {
      final doc = kind == 'label'
          ? await _reports.sampleLabelPdf(id)
          : await _reports.inspectionReport(id);
      final date = parseIsoDate('${row['inspection_date'] ?? ''}');
      final file = await _reports.saveReport(doc, date: date);
      if (!mounted) return;
      AppFeedback.success(context, 'تم التصدير | Exported: ${file.path}');
    } on AppError catch (e) {
      if (mounted) AppFeedback.error(context, e.message);
    } catch (e) {
      if (mounted) AppFeedback.error(context, '$e');
    }
  }
}

class _IconAction extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;
  const _IconAction({
    required this.tooltip,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onTap,
      icon: Icon(icon, size: 18),
      visualDensity: VisualDensity.compact,
    );
  }
}