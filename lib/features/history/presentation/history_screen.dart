import 'package:flutter/material.dart';

import '../../../design_system/tokens/app_spacing.dart';
import '../../../design_system/widgets/app_empty_state.dart';
import '../../../design_system/widgets/app_field.dart';
import '../../../design_system/widgets/app_status_badge.dart';
import '../../../di/service_locator.dart';
import '../../inspections/data/inspection_repo.dart';

/// Inspection history (port of Web HistoryView).
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  var _query = '';
  List<Map<String, dynamic>> _rows = [];
  var _loading = true;
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
      final rows = await getIt<InspectionRepo>().list(query: _query);
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('سجل الفحوصات | History',
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: AppSpacing.md),
          AppField(
            label: 'بحث | Search',
            hint: 'رمز الدخول، الخامة، المورد، رقم الشاحنة…',
            onChanged: (v) => setState(() => _query = v),
          ),
          const SizedBox(height: AppSpacing.sm),
          if (_loading)
            const Expanded(child: Center(child: CircularProgressIndicator()))
          else if (_error != null)
            Expanded(
              child: AppEmptyState(
                icon: Icons.error_outline,
                title: 'تعذر التحميل',
                subtitle: _error,
                action: TextButton(onPressed: _load, child: const Text('إعادة المحاولة')),
              ),
            )
          else
            Expanded(
              child: _rows.isEmpty
                  ? const AppEmptyState(
                      icon: Icons.inventory_2_outlined,
                      title: 'لا توجد فحوصات بعد | No inspections yet',
                    )
                  : Card(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Scrollbar(
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: DataTable(
                              columns: const [
                                DataColumn(label: Text('رقم الدخول | Code')),
                                DataColumn(label: Text('الخامة | Material')),
                                DataColumn(label: Text('التاريخ | Date')),
                                DataColumn(label: Text('المورد | Supplier')),
                                DataColumn(label: Text('الحالة | Status')),
                                DataColumn(label: Text('')),
                              ],
                              rows: [
                                for (final r in _rows)
                                  DataRow(
                                    cells: [
                                      DataCell(Text('${r['entry_code'] ?? ''}')),
                                      DataCell(Text('${r['material_name'] ?? ''}')),
                                      DataCell(Text('${r['inspection_date'] ?? ''}')),
                                      DataCell(Text('${r['supplier'] ?? '-'}')),
                                      DataCell(AppStatusBadge('${r['decision_status'] ?? ''}')),
                                      DataCell(
                                        IconButton(
                                          icon: const Icon(Icons.chevron_left, size: 18),
                                          tooltip: 'عرض',
                                          onPressed: () => _openDetail(r),
                                        ),
                                      ),
                                    ],
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
            ),
        ],
      ),
    );
  }

  void _openDetail(Map<String, dynamic> row) {}
}