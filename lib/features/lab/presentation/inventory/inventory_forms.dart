import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../../app/auth_gate.dart';
import '../../../../../core/constants/app_strings.dart';
import '../../../../../core/utils/app_exceptions.dart';
import '../../../../../design_system/feedback/app_feedback.dart';
import '../../../../../design_system/tokens/app_colors.dart';
import '../../../../../design_system/tokens/app_spacing.dart';
import '../../../../../design_system/widgets/app_dropdown.dart';
import '../../../../../design_system/widgets/app_unit_field.dart';
import '../../../../../design_system/widgets/app_window.dart';
import '../../../../../di/service_locator.dart';
import '../../core/formula_engine.dart';
import '../../domain/lab_local_repository.dart';
import '../../domain/lab_result_repository.dart';

/// Shared inventory editors (used by desktop dialog AND mobile full-screen
/// route so behaviour can never diverge — only the chrome differs).
class InventoryItemDialog extends StatefulWidget {
  final Map<String, dynamic>? item;
  const InventoryItemDialog({super.key, this.item});
  @override
  State<InventoryItemDialog> createState() => InventoryItemDialogState();
}

class InventoryItemDialogState extends State<InventoryItemDialog> {
  final _repo = getIt<LabLocalRepository>();
  List<String> _unitSymbols = const [];
  @override
  void initState() {
    super.initState();
    try {
      _repo.listUnitSymbols().then((symbols) {
        if (mounted) setState(() => _unitSymbols = symbols);
      });
    } catch (_) {}
  }

  late final TextEditingController _name = TextEditingController(
    text: '${widget.item?['name'] ?? ''}',
  );
  late final TextEditingController _qty = TextEditingController(
    text: '${widget.item?['current_qty'] ?? ''}',
  );
  late final TextEditingController _min = TextEditingController(
    text: '${widget.item?['min_qty'] ?? ''}',
  );
  late final TextEditingController _description = TextEditingController(
    text: '${widget.item?['description'] ?? ''}',
  );
  late String _category = '${widget.item?['category'] ?? 'liquid'}';
  late final TextEditingController _unit = TextEditingController(
    text: '${widget.item?['unit'] ?? 'mL'}',
  );
  bool _saving = false;
  @override
  void dispose() {
    _name.dispose();
    _qty.dispose();
    _min.dispose();
    _description.dispose();
    _unit.dispose();
    super.dispose();
  }

  Future<void> save() async {
    setState(() => _saving = true);
    try {
      if (widget.item == null) {
        await _repo.addInventoryItem(
          name: _name.text,
          category: _category,
          unit: _unit.text.trim().isEmpty ? 'mL' : _unit.text.trim(),
          qty: double.tryParse(_qty.text) ?? 0,
          minQty: double.tryParse(_min.text) ?? 0,
          description: _description.text,
        );
      } else {
        await _repo.updateInventoryItem((widget.item!['id'] as num).toInt(), {
          'name': _name.text,
          'category': _category,
          'unit': _unit.text.trim(),
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
      if (mounted) AppFeedback.errorFrom(context, e);
    }
  }

  bool get saving => _saving;

  /// The field list shared by dialog and full-screen route.
  Widget buildFields() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: _name,
          decoration: InputDecoration(
            labelText: AppText.t('الاسم', 'Name'),
            isDense: true,
          ),
        ),
        AppDropdown<String>(
          value: _category,
          labelText: AppText.t('النوع', 'Type'),
          items: [
            for (final c in inventoryCategories)
              AppDropdownItem(
                value: c,
                label: inventoryCategoryLabel(c),
              ),
          ],
          onChanged: (v) {
            if (v == null) return;
            setState(() {
              _category = v;
              // The unit follows the category: a liquid cannot stay on
              // grams, a powder cannot stay on litres, and counted items
              // are always pieces.
              _unit.text = defaultUnitForCategory[v] ?? _unit.text;
            });
          },
        ),
        AppUnitField(
          controller: _unit,
          symbols: _unitSymbols,
          allowedUnits: categoryUnits[_category],
          // Counted items are pieces, full stop — no picker needed.
          enabled: _category != 'count',
        ),
        if (widget.item == null)
          TextField(
            controller: _qty,
            decoration: InputDecoration(
              labelText: AppText.t('الكمية', 'Quantity'),
              isDense: true,
            ),
          ),
        TextField(
          controller: _min,
          decoration: InputDecoration(
            labelText: AppText.t('الحد الأدنى', 'Minimum'),
            isDense: true,
          ),
        ),
        TextField(
          controller: _description,
          maxLines: 2,
          decoration: InputDecoration(
            labelText: AppText.t('الوصف', 'Description'),
            isDense: true,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return AppWindow(
      title: widget.item == null
          ? AppText.t('إضافة مادة', 'Add item')
          : AppText.t('تعديل مادة', 'Edit item'),
      icon: Icons.inventory_2_outlined,
      size: AppWindowSize.sm,
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: Text(AppStrings.cancel),
        ),
        FilledButton(
          onPressed: _saving ? null : save,
          child: _saving
              ? SizedBox(
                  width: 18.r,
                  height: 18.r,
                  child: const CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(AppStrings.save),
        ),
      ],
      child: buildFields(),
    );
  }
}

/// Reusable item form (fields + save). Used by the mobile full-screen
/// route; the desktop dialog above keeps its own copy so its pixels
/// do not move.
class InventoryItemForm extends StatefulWidget {
  final Map<String, dynamic>? item;
  const InventoryItemForm({super.key, this.item});
  @override
  State<InventoryItemForm> createState() => InventoryItemFormState();
}

class InventoryItemFormState extends State<InventoryItemForm> {
  final _repo = getIt<LabLocalRepository>();
  List<String> _unitSymbols = const [];

  @override
  void initState() {
    super.initState();
    try {
      _repo.listUnitSymbols().then((symbols) {
        if (mounted) setState(() => _unitSymbols = symbols);
      });
    } catch (_) {}
  }

  late final TextEditingController _name = TextEditingController(
    text: '${widget.item?['name'] ?? ''}',
  );
  late final TextEditingController _qty = TextEditingController(
    text: '${widget.item?['current_qty'] ?? ''}',
  );
  late final TextEditingController _min = TextEditingController(
    text: '${widget.item?['min_qty'] ?? ''}',
  );
  late final TextEditingController _description = TextEditingController(
    text: '${widget.item?['description'] ?? ''}',
  );
  late String _category = '${widget.item?['category'] ?? 'liquid'}';
  late final TextEditingController _unit = TextEditingController(
    text: '${widget.item?['unit'] ?? 'mL'}',
  );
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _qty.dispose();
    _min.dispose();
    _description.dispose();
    _unit.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      if (widget.item == null) {
        await _repo.addInventoryItem(
          name: _name.text,
          category: _category,
          unit: _unit.text.trim().isEmpty ? 'mL' : _unit.text.trim(),
          qty: double.tryParse(_qty.text) ?? 0,
          minQty: double.tryParse(_min.text) ?? 0,
          description: _description.text,
        );
      } else {
        await _repo.updateInventoryItem((widget.item!['id'] as num).toInt(), {
          'name': _name.text,
          'category': _category,
          'unit': _unit.text.trim(),
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
      if (mounted) AppFeedback.errorFrom(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: _name,
          decoration: InputDecoration(
            labelText: AppText.t('الاسم', 'Name'),
            isDense: true,
          ),
        ),
        AppDropdown<String>(
          value: _category,
          labelText: AppText.t('النوع', 'Type'),
          items: [
            for (final c in inventoryCategories)
              AppDropdownItem(
                value: c,
                label: inventoryCategoryLabel(c),
              ),
          ],
          onChanged: (v) {
            if (v == null) return;
            setState(() {
              _category = v;
              // The unit follows the category: a liquid cannot stay on
              // grams, a powder cannot stay on litres, and counted items
              // are always pieces.
              _unit.text = defaultUnitForCategory[v] ?? _unit.text;
            });
          },
        ),
        AppUnitField(
          controller: _unit,
          symbols: _unitSymbols,
          allowedUnits: categoryUnits[_category],
          // Counted items are pieces, full stop — no picker needed.
          enabled: _category != 'count',
        ),
        if (widget.item == null)
          TextField(
            controller: _qty,
            decoration: InputDecoration(
              labelText: AppText.t('الكمية', 'Quantity'),
              isDense: true,
            ),
          ),
        TextField(
          controller: _min,
          decoration: InputDecoration(
            labelText: AppText.t('الحد الأدنى', 'Minimum'),
            isDense: true,
          ),
        ),
        TextField(
          controller: _description,
          maxLines: 2,
          decoration: InputDecoration(
            labelText: AppText.t('الوصف', 'Description'),
            isDense: true,
          ),
        ),
        if (_saving)
          const Padding(
            padding: EdgeInsets.only(top: AppSpacing.md),
            child: LinearProgressIndicator(),
          ),
      ],
    );
  }
}

class InventoryAdjustDialog extends StatefulWidget {
  final Map<String, dynamic> item;
  const InventoryAdjustDialog({super.key, required this.item});
  @override
  State<InventoryAdjustDialog> createState() => InventoryAdjustDialogState();
}

class InventoryAdjustDialogState extends State<InventoryAdjustDialog> {
  final _repo = getIt<LabResultRepository>();
  late final TextEditingController _delta = TextEditingController(
    text: '${widget.item['current_qty'] ?? 0}',
  );
  final _reason = TextEditingController();
  bool _saving = false;
  Map<String, dynamic>? get _currentUserMap {
    final user = getIt<AuthGate>().currentUser;
    if (user == null) return null;
    return {
      'id': user.id,
      'username': user.username,
      'full_name': user.fullName,
    };
  }

  @override
  void dispose() {
    _delta.dispose();
    _reason.dispose();
    super.dispose();
  }

  Future<void> save() async {
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
      if (mounted) AppFeedback.errorFrom(context, e);
    }
  }

  bool get saving => _saving;

  Widget buildFields() {
    final current = '${widget.item['current_qty'] ?? 0}';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${widget.item['name']} — الحالية: $current ${widget.item['unit']}',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: AppSpacing.md),
        TextField(
          controller: _delta,
          decoration: InputDecoration(
            labelText: AppText.t('الكمية الجديدة', 'New quantity'),
            isDense: true,
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        TextField(
          controller: _reason,
          decoration: InputDecoration(
            labelText: AppText.t('السبب', 'Reason'),
            isDense: true,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return AppWindow(
      title: AppText.t('تسوية الكمية', 'Adjust quantity'),
      icon: Icons.balance_outlined,
      size: AppWindowSize.sm,
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: Text(AppStrings.cancel),
        ),
        FilledButton(
          onPressed: _saving ? null : save,
          child: _saving
              ? SizedBox(
                  width: 18.r,
                  height: 18.r,
                  child: const CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(AppStrings.save),
        ),
      ],
      child: buildFields(),
    );
  }
}

/// Mobile full-screen adjust form (same repo call, 52h CTA).
class InventoryAdjustForm extends StatefulWidget {
  final Map<String, dynamic> item;
  const InventoryAdjustForm({super.key, required this.item});
  @override
  State<InventoryAdjustForm> createState() => InventoryAdjustFormState();
}

class InventoryAdjustFormState extends State<InventoryAdjustForm> {
  final _repo = getIt<LabResultRepository>();
  late final TextEditingController _delta = TextEditingController(
    text: '${widget.item['current_qty'] ?? 0}',
  );
  final _reason = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _delta.dispose();
    _reason.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final user = getIt<AuthGate>().currentUser;
      await _repo.adjustStock(
        itemId: (widget.item['id'] as num).toInt(),
        newQty: double.tryParse(_delta.text),
        reason: _reason.text,
        user: user == null
            ? null
            : {
                'id': user.id,
                'username': user.username,
                'full_name': user.fullName,
              },
      );
      if (mounted) Navigator.of(context).pop(true);
    } on AppError catch (e) {
      setState(() => _saving = false);
      if (mounted) AppFeedback.error(context, e.message);
    } catch (e) {
      setState(() => _saving = false);
      if (mounted) AppFeedback.errorFrom(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '${widget.item['name']}',
          style: TextStyle(
            fontSize: 14.spMax,
            fontWeight: FontWeight.w700,
            color: AppColors.textStrong,
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        TextField(
          controller: _delta,
          decoration: InputDecoration(
            labelText: AppText.t('الكمية الجديدة', 'New quantity'),
            isDense: true,
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        TextField(
          controller: _reason,
          decoration: InputDecoration(
            labelText: AppText.t('السبب', 'Reason'),
            isDense: true,
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        SizedBox(
          height: AppSpacing.mobileCtaHeight.h,
          child: FilledButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? SizedBox(
                    width: 18.r,
                    height: 18.r,
                    child: const CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : Text(AppText.t('حفظ', 'Save')),
          ),
        ),
      ],
    );
  }
}
