import 'package:flutter/material.dart';

import '../../../core/constants/app_strings.dart';
import '../../../core/utils/app_dates.dart';
import '../../../core/utils/app_exceptions.dart';
import '../../../design_system/feedback/app_feedback.dart';
import '../../../design_system/tokens/app_colors.dart';
import '../../../design_system/tokens/app_spacing.dart';
import '../../../design_system/widgets/app_button.dart';
import '../../../design_system/widgets/app_card.dart';
import '../../../design_system/widgets/app_field.dart';
import '../../../app/auth_gate.dart';
import '../../../di/service_locator.dart';
import '../../reference/data/reference_repo.dart';
import '../data/inspection_repo.dart';

/// New-inspection form (port of Web InspectionsForm + decision editing).
class InspectionFormScreen extends StatefulWidget {
  const InspectionFormScreen({super.key});

  @override
  State<InspectionFormScreen> createState() => _InspectionFormScreenState();
}

class _InspectionFormScreenState extends State<InspectionFormScreen> {
  final _repo = getIt<InspectionRepo>();
  final _reference = getIt<ReferenceRepo>();

  late final TextEditingController _date = TextEditingController(text: todayIso());
  final _expiry = TextEditingController();
  final _supplier = TextEditingController();
  final _truck = TextEditingController();
  final _qty = TextEditingController();
  final _sampleTaker = TextEditingController();
  final _entryCode = TextEditingController();
  final _decisionReason = TextEditingController();
  final _followUp = TextEditingController();
  final _rejectedQty = TextEditingController();

  final List<TextEditingController> _sampleNames = [TextEditingController(text: 'Result')];

  final Map<String, List<TextEditingController>> _physical = {};
  final Map<String, List<TextEditingController>> _chemical = {};

  List<Map<String, dynamic>> _materials = [];
  int? _materialId;
  String _materialCode = '';
  String _decision = 'APPROVED';
  bool _loading = true;
  bool _saving = false;
  String? _error;

  int get _sampleCount => _sampleNames.length;

  @override
  void initState() {
    super.initState();
    _loadMaterials();
  }

  @override
  void dispose() {
    for (final c in [..._sampleNames, _expiry, _supplier, _truck, _qty, _sampleTaker,
        _entryCode, _decisionReason, _followUp, _rejectedQty]) {
      c.dispose();
    }
    for (final list in _physical.values) {
      for (final c in list) {
        c.dispose();
      }
    }
    for (final list in _chemical.values) {
      for (final c in list) {
        c.dispose();
      }
    }
    super.dispose();
  }

  Future<void> _loadMaterials() async {
    try {
      final materials = await _reference.listMaterials();
      if (!mounted) return;
      setState(() {
        _materials = materials;
        _loading = false;
      });
    } on AppError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _selectMaterial(int id) async {
    final date = _date.text.trim().isEmpty ? todayIso() : _date.text.trim();
    final material = await _reference.getMaterial(id, inspectionDate: date);
    if (!mounted) return;
    setState(() {
      _materialId = id;
      _materialCode = '${material['material_code'] ?? ''}';
      _entryCode.text = '${material['next_entry_code'] ?? ''}';
      _rebuildResults(_physical, material['physical_reference'], 'physical');
      _rebuildResults(_chemical, material['chemical_reference'], 'chemical');
    });
  }

  void _rebuildResults(Map<String, List<TextEditingController>> target,
      dynamic ref, String type) {
    target.clear();
    final Map<String, dynamic> refMap = ref is Map ? Map<String, dynamic>.from(ref) : {};
    refMap.forEach((key, _) {
      if (key.toString().trim().isEmpty) return;
      target[key] = [for (var i = 0; i < _sampleCount; i++) TextEditingController()];
    });
  }

  void _addSample() {
    if (_sampleCount >= 3) {
      AppFeedback.error(context, 'الحد الأقصى 3 عينات | A maximum of 3 samples.');
      return;
    }
    setState(() {
      _sampleNames.add(TextEditingController());
      for (final map in [_physical, _chemical]) {
        for (final entry in map.entries) {
          entry.value.add(TextEditingController());
        }
      }
    });
  }

  void _removeSample(int index) {
    if (_sampleCount <= 1) return;
    setState(() {
      _sampleNames.removeAt(index).dispose();
      for (final map in [_physical, _chemical]) {
        for (final entry in map.entries) {
          if (index < entry.value.length) {
            entry.value.removeAt(index).dispose();
          }
        }
      }
    });
  }

  Map<String, dynamic> _collectResults(Map<String, List<TextEditingController>> source) {
    final out = <String, dynamic>{};
    source.forEach((param, controllers) {
      if (_sampleCount == 1) {
        out[param] = controllers.first.text;
      } else {
        out[param] = [for (final c in controllers) c.text];
      }
    });
    return out;
  }

  Future<void> _save() async {
    if (_materialId == null) {
      AppFeedback.error(context, 'يجب اختيار المادة | Material selection is required.');
      return;
    }
    if (_supplier.text.trim().length < 3) {
      AppFeedback.error(context, 'اسم المورد مطلوب (3 أحرف على الأقل) | Supplier is required.');
      return;
    }
    if (_sampleTaker.text.trim().length < 3) {
      AppFeedback.error(context,
          'اسم آخذ العينة مطلوب (3 أحرف على الأقل) | Sample taker is required.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final user = getIt<AuthGate>().currentUser;
      if (user == null) throw const AppError('انتهت الجلسة | Session expired.');
      final payload = <String, dynamic>{
        'material_id': _materialId,
        'inspection_date': _date.text.trim(),
        'expiry_date': _expiry.text.trim(),
        'entry_code': _entryCode.text.trim(),
        'supplier': _supplier.text.trim(),
        'truck_number': _truck.text.trim(),
        'quantity': _qty.text.trim(),
        'sample_taken_by': _sampleTaker.text.trim(),
        'sample_names': [for (final c in _sampleNames) c.text],
        'physical_results': _collectResults(_physical),
        'chemical_results': _collectResults(_chemical),
        'decision_status': _decision,
        'decision_reason': _decisionReason.text.trim(),
        'follow_up_note': _followUp.text.trim(),
        'rejected_quantity': _rejectedQty.text.trim(),
      };
      await _repo.create(payload, UserContext(
        id: user.id,
        fullName: user.fullName,
        role: user.role,
      ));
      if (!mounted) return;
      AppFeedback.success(context, 'تم حفظ الفحص | Inspection saved.');
      Navigator.of(context).pop(true);
    } on AppError catch (e) {
      if (mounted) setState(() => _error = e.message);
      AppFeedback.error(context, e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.page),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('فحص جديد | New Inspection', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: AppSpacing.md),
          if (_error != null) ...[
            Text(_error!,
                style: TextStyle(color: AppColors.danger, fontSize: 13)),
            const SizedBox(height: AppSpacing.md),
          ],
          _Card(
            title: 'البيانات الأساسية | Basic data',
            children: [
              DropdownButtonFormField<int>(
                initialValue: _materialId,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'المادة | Material',
                  isDense: true,
                ),
                items: [
                  for (final m in _materials)
                    DropdownMenuItem<int>(
                      value: (m['id'] as num).toInt(),
                      child: Text('${m['material_name']} (${m['material_code']})',
                          overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (value) {
                  if (value != null) _selectMaterial(value);
                },
              ),
              const SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  Expanded(
                    child: AppField(
                      label: 'تاريخ الفحص | Date (YYYY-MM-DD)',
                      controller: _date,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.lg),
                  Expanded(
                    child: AppField(
                      label: 'تاريخ الانتهاء | Expiry (YYYY-MM-DD)',
                      controller: _expiry,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  Expanded(
                    child: AppField(
                      label: 'المورد | Supplier',
                      controller: _supplier,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.lg),
                  Expanded(
                    child: AppField(
                      label: 'رقم الشاحنة | Truck no.',
                      controller: _truck,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.lg),
                  Expanded(
                    child: AppField(
                      label: 'الكمية | Quantity',
                      controller: _qty,
                      keyboardType: TextInputType.numberWithOptions(decimal: true),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  Expanded(
                    child: AppField(
                      label: 'آخذ العينة | Sample taker',
                      controller: _sampleTaker,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.lg),
                  Expanded(
                    child: Row(
                      children: [
                        Expanded(
                          child: AppField(
                            label: 'رقم القيد | Entry code',
                            controller: _entryCode,
                          ),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        IconButton(
                          tooltip: 'إعادة توليد | Regenerate',
                          onPressed: () async {
                            if (_materialId == null) return;
                            final code = await _reference.generateEntryCode(
                              _materialCode,
                              _date.text.trim(),
                            );
                            if (mounted) setState(() => _entryCode.text = code);
                          },
                          icon: const Icon(Icons.refresh, size: 20),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          _Card(
            title: 'العينات | Samples',
            children: [
              for (var i = 0; i < _sampleCount; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                  child: Row(
                    children: [
                      Expanded(
                        child: AppField(
                          label: 'اسم العينة ${i + 1} | Sample #${i + 1}',
                          controller: _sampleNames[i],
                        ),
                      ),
                      if (_sampleCount > 1) ...[
                        const SizedBox(width: AppSpacing.sm),
                        IconButton(
                          tooltip: 'إزالة | Remove',
                          onPressed: () => _removeSample(i),
                          icon: const Icon(Icons.close, size: 20),
                        ),
                      ],
                    ],
                  ),
                ),
              AppButton(
                small: true,
                style: AppButtonStyle.secondary,
                label: 'إضافة عينة | Add Sample',
                icon: const Icon(Icons.add, size: 18),
                onPressed: _sampleCount >= 3 ? null : _addSample,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          if (_physical.isNotEmpty)
            _Card(
              title: 'النتائج الفيزيائية | Physical results',
              children: [_resultsGrid(_physical)],
            ),
          if (_chemical.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.md),
            _Card(
              title: 'النتائج الكيميائية | Chemical results',
              children: [_resultsGrid(_chemical)],
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          _Card(
            title: 'قرار الجودة | Decision',
            children: [
              DropdownButtonFormField<String>(
                initialValue: _decision,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'القرار | Decision',
                  isDense: true,
                ),
                items: const [
                  DropdownMenuItem(value: 'APPROVED', child: Text('قبول نهائي | Approved')),
                  DropdownMenuItem(
                      value: 'CONDITIONAL_APPROVAL', child: Text('قبول مشروط | Conditional')),
                  DropdownMenuItem(
                      value: 'PARTIAL_REJECTION', child: Text('رفض جزئي | Partial rejection')),
                  DropdownMenuItem(value: 'FULL_REJECTION', child: Text('رفض كامل | Full rejection')),
                ],
                onChanged: (value) {
                  if (value != null) setState(() => _decision = value);
                },
              ),
              const SizedBox(height: AppSpacing.md),
              if (_decision == 'CONDITIONAL_APPROVAL') ...[
                AppField(
                  label: 'ملاحظة المتابعة | Follow-up note',
                  controller: _followUp,
                  maxLines: 3,
                ),
                const SizedBox(height: AppSpacing.md),
              ],
              if (_decision == 'PARTIAL_REJECTION') ...[
                AppField(
                  label: 'الكمية المرفوضة | Rejected quantity',
                  controller: _rejectedQty,
                  keyboardType: TextInputType.numberWithOptions(decimal: true),
                ),
                const SizedBox(height: AppSpacing.md),
              ],
              if (_decision == 'FULL_REJECTION' || _decision == 'PARTIAL_REJECTION') ...[
                AppField(
                  label: 'سبب القرار | Decision reason',
                  controller: _decisionReason,
                  maxLines: 3,
                ),
                const SizedBox(height: AppSpacing.md),
              ],
            ],
          ),
          const SizedBox(height: AppSpacing.xl),
          Row(
            children: [
              AppButton(
                label: AppStrings.save,
                icon: const Icon(Icons.check, size: 18),
                loading: _saving,
                onPressed: _saving ? null : _save,
              ),
              const SizedBox(width: AppSpacing.md),
              AppButton(
                style: AppButtonStyle.secondary,
                label: AppStrings.cancel,
                onPressed: () => Navigator.of(context).pop(false),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _resultsGrid(Map<String, List<TextEditingController>> source) {
    final params = source.keys.toList();
    return Column(
      children: [
        if (_sampleCount > 1)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.xs),
            child: Row(
              children: [
                const Expanded(flex: 2, child: SizedBox()),
                for (var i = 0; i < _sampleCount; i++)
                  Expanded(
                    flex: 3,
                    child: Text('عينة ${i + 1} | Sample #${i + 1}',
                        style: TextStyle(color: AppColors.textMuted, fontSize: 12)),
                  ),
              ],
            ),
          ),
        for (final param in params)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 2,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(param,
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                  ),
                ),
                Expanded(
                  flex: 3,
                  child: _sampleCount == 1
                      ? TextField(
                          controller: source[param]!.first,
                          decoration: const InputDecoration(isDense: true),
                        )
                      : Row(
                          children: [
                            for (var i = 0; i < _sampleCount; i++) ...[
                              if (i > 0) const SizedBox(width: AppSpacing.md),
                              Expanded(
                                child: TextField(
                                  controller: source[param]![i],
                                  decoration: const InputDecoration(isDense: true),
                                ),
                              ),
                            ],
                          ],
                        ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _Card extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const _Card({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: AppSpacing.sm),
            ...children,
          ],
        ),
      ),
    );
  }
}