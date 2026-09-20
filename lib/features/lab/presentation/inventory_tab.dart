import 'package:flutter/material.dart';

import '../../../core/constants/app_strings.dart';
import '../../../core/utils/app_exceptions.dart';
import '../../../design_system/feedback/app_feedback.dart';
import '../../../design_system/tokens/app_colors.dart';
import '../../../design_system/tokens/app_spacing.dart';
import '../../../design_system/widgets/app_button.dart';
import '../../../design_system/widgets/app_card.dart';
import '../../../app/auth_gate.dart';
import '../../../di/service_locator.dart';
import '../core/formula_engine.dart' show inventoryUnits;
import '../data/lab_repo.dart';

/// Lab inventory tab (port of LabView inventory list + form).
class InventoryTab extends StatefulWidget {
  const InventoryTab({super.key});

  @override
  State<InventoryTab> createState() => _InventoryTabState();
}

class _InventoryTabState extends State<InventoryTab> {
  final _repo = getIt<LabRepo>();
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;
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
      final rows = await _repo.listInventory();
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _loading = false;
      });
    } on AppError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _openAdd() async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => const _InventoryDialog(),
    );
    if (saved == true) _load();
  }

  Future<void> _openEdit(Map<String, dynamic> row) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _InventoryDialog(item: row),
    );
    if (saved == true) _load();
  }

  Future<void> _openAdjust(Map<String, dynamic> row) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _AdjustDialog(item: row),
    );
    if (saved == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('المخزون | Inventory', style: Theme.of(context).textTheme.titleLarge),
            const Spacer(),
            AppButton(
              small: true,
              label: 'إضافة مادة | Add item',
              icon: const Icon(Icons.add, size: 16),
              onPressed: _openAdd,
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        if (_loading) ...[
          const Center(child: CircularProgressIndicator()),
        ] else if (_error != null) ...[
          Text(_error!, style: TextStyle(color: AppColors.danger)),
        ] else if (_rows.isEmpty) ...[
          const Text('لا توجد مواد | No inventory items'),
        ] else
          AppCard(
            padding: EdgeInsets.zero,
            child: SizedBox(
              width: double.infinity,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  columns: const [
                    DataColumn(label: Text('الاسم | Name')),
                    DataColumn(label: Text('النوع | Category')),
                    DataColumn(label: Text('الوحدة | Unit')),
                    DataColumn(label: Text('الكمية | Qty')),
                    DataColumn(label: Text('الحد الأدنى | Min')),
                    DataColumn(label: Text('الحالة | Status')),
                    DataColumn(label: Text('')),
                  ],
                  rows: [
                    for (final r in _rows)
                      DataRow(
                        cells: [
                          DataCell(Text('${r['name']}')),
                          DataCell(Text(r['category'] == 'liquid' ? 'سائل | Liquid' : 'مسحوق | Powder')),
                          DataCell(Text('${r['unit'] ?? ''}')),
                          DataCell(Text('${r['current_qty'] ?? 0}')),
                          DataCell(Text('${r['min_qty'] ?? 0}')),
                          DataCell(_statusCell(r)),
                          DataCell(Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: 'تسوية الكمية | Adjust',
                                visualDensity: VisualDensity.compact,
                                onPressed: () => _openAdjust(r),
                                icon: const Icon(Icons.swap_vert, size: 18),
                              ),
                              IconButton(
                                tooltip: AppStrings.edit,
                                visualDensity: VisualDensity.compact,
                                onPressed: () => _openEdit(r),
                                icon: const Icon(Icons.edit_outlined, size: 18),
                              ),
                            ],
                          )),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _statusCell(Map<String, dynamic> r) {
    final qty = (r['current_qty'] as num?)?.toDouble() ?? 0;
    final min = (r['min_qty'] as num?)?.toDouble() ?? 0;
    if (qty <= 0) {
      return Text('نفد | Empty', style: TextStyle(color: AppColors.danger, fontSize: 12));
    }
    if (qty < min) {
      return Text('منخفض | Low', style: TextStyle(color: AppColors.partial, fontSize: 12));
    }
    return Text('متوفر | OK', style: TextStyle(color: AppColors.success, fontSize: 12));
  }
}

class _InventoryDialog extends StatefulWidget {
  final Map<String, dynamic>? item;
  const _InventoryDialog({this.item});

  @override
  State<_InventoryDialog> createState() => _InventoryDialogState();
}

class _InventoryDialogState extends State<_InventoryDialog> {
  final _repo = getIt<LabRepo>();
  late final TextEditingController _name =
      TextEditingController(text: '${widget.item?['name'] ?? ''}');
  late final TextEditingController _qty =
      TextEditingController(text: '${widget.item?['current_qty'] ?? ''}');
  late final TextEditingController _min =
      TextEditingController(text: '${widget.item?['min_qty'] ?? ''}');
  late final TextEditingController _description =
      TextEditingController(text: '${widget.item?['description'] ?? ''}');
  late String _category = '${widget.item?['category'] ?? 'liquid'}';
  late String _unit = '${widget.item?['unit'] ?? 'mL'}';
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _qty.dispose();
    _min.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      if (widget.item == null) {
        await _repo.addInventoryItem(
          name: _name.text,
          category: _category,
          unit: _unit,
          qty: double.tryParse(_qty.text) ?? 0,
          minQty: double.tryParse(_min.text) ?? 0,
          description: _description.text,
        );
      } else {
        await _repo.updateInventoryItem((widget.item!['id'] as num).toInt(), {
          'name': _name.text,
          'category': _category,
          'unit': _unit,
          'min_qty': double.tryParse(_min.text) ?? 0,
          'description': _description.text,
        });
      }
      if (mounted) Navigator.of(context).pop(true);
    } on AppError catch (e) {
      setState(() => _saving = false);
      if (mounted) AppFeedback.error(context, e.message);
    } catch (e) {
      setState(() => _saving = false);
      if (mounted) AppFeedback.error(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.item == null ? 'إضافة مادة | Add item' : 'تعديل مادة | Edit item'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'الاسم | Name', isDense: true),
              ),
              DropdownButtonFormField<String>(
                initialValue: _category,
                decoration:
                    const InputDecoration(labelText: 'النوع | Category', isDense: true),
                items: const [
                  DropdownMenuItem(value: 'liquid', child: Text('سائل | Liquid')),
                  DropdownMenuItem(value: 'powder', child: Text('مسحوق | Powder')),
                ],
                onChanged: (v) {
                  if (v != null) setState(() => _category = v);
                },
              ),
              DropdownButtonFormField<String>(
                initialValue: _unit,
                decoration:
                    const InputDecoration(labelText: 'الوحدة | Unit', isDense: true),
                items: [
                  for (final u in inventoryUnits)
                    DropdownMenuItem(value: u, child: Text(u)),
                ],
                onChanged: (v) {
                  if (v != null) setState(() => _unit = v);
                },
              ),
              if (widget.item == null)
                TextField(
                  controller: _qty,
                  decoration: const InputDecoration(labelText: 'الكمية | Quantity', isDense: true),
                ),
              TextField(
                controller: _min,
                decoration:
                    const InputDecoration(labelText: 'الحد الأدنى | Min quantity', isDense: true),
              ),
              TextField(
                controller: _description,
                maxLines: 2,
                decoration:
                    const InputDecoration(labelText: 'الوصف | Description', isDense: true),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: Text(AppStrings.cancel),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(AppStrings.save),
        ),
      ],
    );
  }
}

class _AdjustDialog extends StatefulWidget {
  final Map<String, dynamic> item;
  const _AdjustDialog({required this.item});

  @override
  State<_AdjustDialog> createState() => _AdjustDialogState();
}

class _AdjustDialogState extends State<_AdjustDialog> {
  final _repo = getIt<LabRepo>();
  late final TextEditingController _delta =
      TextEditingController(text: '${widget.item['current_qty'] ?? 0}');
  final _reason = TextEditingController();
  bool _saving = false;

  Map<String, dynamic>? get _currentUserMap {
    final user = getIt<AuthGate>().currentUser;
    if (user == null) return null;
    return {'id': user.id, 'username': user.username, 'full_name': user.fullName};
  }

  @override
  void dispose() {
    _delta.dispose();
    _reason.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await _repo.adjustStock(
        itemId: (widget.item['id'] as num).toInt(),
        newQty: double.tryParse(_delta.text),
        reason: _reason.text,
        user: _currentUserMap,
      );
      if (mounted) Navigator.of(context).pop(true);
    } on AppError catch (e) {
      setState(() => _saving = false);
      if (mounted) AppFeedback.error(context, e.message);
    } catch (e) {
      setState(() => _saving = false);
      if (mounted) AppFeedback.error(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = '${widget.item['current_qty'] ?? 0}';
    return AlertDialog(
      title: const Text('تسوية الكمية | Adjust stock'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${widget.item['name']} — الحالية: $current ${widget.item['unit']}',
                style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _delta,
              decoration: const InputDecoration(
                labelText: 'الكمية الجديدة | New quantity',
                isDense: true,
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _reason,
              decoration: const InputDecoration(labelText: 'السبب | Reason', isDense: true),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: Text(AppStrings.cancel),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(AppStrings.save),
        ),
      ],
    );
  }
}