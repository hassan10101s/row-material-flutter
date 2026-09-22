import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../app/auth_gate.dart';
import '../../../core/constants/app_strings.dart';
import '../../../core/utils/app_dates.dart';
import '../../../design_system/feedback/app_feedback.dart';
import '../../../design_system/tokens/app_colors.dart';
import '../../../design_system/tokens/app_spacing.dart';
import '../../../design_system/widgets/app_button.dart';
import '../../../design_system/widgets/app_card.dart';
import '../../../design_system/widgets/app_field.dart';
import '../../../di/service_locator.dart';
import '../data/inspection_repo.dart';
import 'cubit/inspection_form_cubit.dart';
import 'cubit/inspection_form_state.dart';
/// New-inspection form (port of Web InspectionsForm + decision editing).
class InspectionFormScreen extends StatefulWidget {
  const InspectionFormScreen({super.key});
  @override
  State<InspectionFormScreen> createState() => _InspectionFormScreenState();
}
class _InspectionFormScreenState extends State<InspectionFormScreen> {
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
  int get _sampleCount => _sampleNames.length;
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
  Future<void> _selectMaterial(int id) async {
    final date = _date.text.trim().isEmpty ? todayIso() : _date.text.trim();
    await context.read<InspectionFormCubit>().selectMaterial(id, date: date);
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
      AppFeedback.error(context, AppText.t('الحد الأقصى 3 عينات', 'A maximum of 3 samples.'));
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
    final state = context.read<InspectionFormCubit>().state;
    if (state.materialId == null) {
      AppFeedback.error(context, AppText.t('يجب اختيار المادة', 'Material selection is required.'));
      return;
    }
    if (_supplier.text.trim().length < 3) {
      AppFeedback.error(context, AppText.t('اسم المورد مطلوب (3 أحرف على الأقل)', 'Supplier is required.'));
      return;
    }
    if (_sampleTaker.text.trim().length < 3) {
      AppFeedback.error(context,
        AppText.t('اسم آخذ العينة مطلوب (3 أحرف على الأقل)', 'Sample taker is required.'));
      return;
    }
    final user = getIt<AuthGate>().currentUser;
    if (user == null) {
      AppFeedback.error(context, AppText.t('انتهت الجلسة', 'Session expired.'));
      return;
    }
    final payload = <String, dynamic>{
      'material_id': state.materialId,
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
      'decision_status': state.decision,
      'decision_reason': _decisionReason.text.trim(),
      'follow_up_note': _followUp.text.trim(),
      'rejected_quantity': _rejectedQty.text.trim(),
    };
    final ok = await context.read<InspectionFormCubit>().save(
          payload,
          UserContext(
            id: user.id,
            fullName: user.fullName,
            role: user.role,
          ),
        );
    if (!mounted) return;
    if (ok) {
      AppFeedback.success(context, AppText.t('تم حفظ الفحص', 'Inspection saved.'));
      Navigator.of(context).pop(true);
    }
  }
  @override
  Widget build(BuildContext context) {
    return BlocListener<InspectionFormCubit, InspectionFormState>(
      listenWhen: (prev, curr) =>
          prev.refRevision != curr.refRevision || prev.entryCode != curr.entryCode,
      listener: (context, state) {
        if (state.refRevision != 0) {
          _rebuildResults(_physical, state.physicalReference, 'physical');
          _rebuildResults(_chemical, state.chemicalReference, 'chemical');
        }
        if (_entryCode.text != state.entryCode && state.entryCode.isNotEmpty) {
          _entryCode.text = state.entryCode;
        }
      },
      child: _FormBody(date: _date, expiry: _expiry, supplier: _supplier, truck: _truck, qty: _qty, sampleTaker: _sampleTaker, entryCode: _entryCode, decisionReason: _decisionReason, followUp: _followUp, rejectedQty: _rejectedQty, sampleNames: _sampleNames, physical: _physical, chemical: _chemical, sampleCount: _sampleCount, onSelectMaterial: _selectMaterial, onAddSample: _addSample, onRemoveSample: _removeSample, onRegenerateEntry: () async {
        if (context.read<InspectionFormCubit>().state.materialId == null) return;
        final date = _date.text.trim().isEmpty ? todayIso() : _date.text.trim();
        await context.read<InspectionFormCubit>().regenerateEntryCode(date);
      }, onSave: _save),
    );
  }
}
class _FormBody extends StatelessWidget {
  final TextEditingController date;
  final TextEditingController expiry;
  final TextEditingController supplier;
  final TextEditingController truck;
  final TextEditingController qty;
  final TextEditingController sampleTaker;
  final TextEditingController entryCode;
  final TextEditingController decisionReason;
  final TextEditingController followUp;
  final TextEditingController rejectedQty;
  final List<TextEditingController> sampleNames;
  final Map<String, List<TextEditingController>> physical;
  final Map<String, List<TextEditingController>> chemical;
  final int sampleCount;
  final ValueChanged<int> onSelectMaterial;
  final VoidCallback onAddSample;
  final ValueChanged<int> onRemoveSample;
  final VoidCallback onRegenerateEntry;
  final VoidCallback onSave;
  const _FormBody({
    required this.date,
    required this.expiry,
    required this.supplier,
    required this.truck,
    required this.qty,
    required this.sampleTaker,
    required this.entryCode,
    required this.decisionReason,
    required this.followUp,
    required this.rejectedQty,
    required this.sampleNames,
    required this.physical,
    required this.chemical,
    required this.sampleCount,
    required this.onSelectMaterial,
    required this.onAddSample,
    required this.onRemoveSample,
    required this.onRegenerateEntry,
    required this.onSave,
  });
  @override
  Widget build(BuildContext context) {
    final state = context.watch<InspectionFormCubit>().state;
    if (state.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.page),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(AppText.t('فحص جديد', 'New Inspection'), style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: AppSpacing.md),
          if (state.error != null) ...[
            Text(state.error!,
                style: TextStyle(color: AppColors.danger, fontSize: 13.spMax)),
            const SizedBox(height: AppSpacing.md),
          ],
          _Card(
            title: AppText.t('البيانات الأساسية', 'Basic data'),
            children: [
              DropdownButtonFormField<int>(
                initialValue: state.materialId,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: AppText.t('المادة', 'Material'),
                  isDense: true,
                ),
                items: [
                  for (final m in state.materials)
                    DropdownMenuItem<int>(
                      value: (m['id'] as num).toInt(),
                      child: Text('${m['material_name']} (${m['material_code']})',
                          overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (value) {
                  if (value != null) onSelectMaterial(value);
                },
              ),
              const SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  Expanded(
                    child: AppField(
                      label: AppText.t('تاريخ الفحص', 'Date (YYYY-MM-DD)'),
                      controller: date,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.lg),
                  Expanded(
                    child: AppField(
                      label: AppText.t('تاريخ الانتهاء', 'Expiry (YYYY-MM-DD)'),
                      controller: expiry,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  Expanded(
                    child: AppField(
                      label: AppText.t('المورد', 'Supplier'),
                      controller: supplier,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.lg),
                  Expanded(
                    child: AppField(
                      label: AppText.t('رقم الشاحنة', 'Truck no.'),
                      controller: truck,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.lg),
                  Expanded(
                    child: AppField(
                      label: AppText.t('الكمية', 'Quantity'),
                      controller: qty,
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
                      label: AppText.t('آخذ العينة', 'Sample taker'),
                      controller: sampleTaker,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.lg),
                  Expanded(
                    child: Row(
                      children: [
                        Expanded(
                          child: AppField(
                            label: AppText.t('رقم القيد', 'Entry code'),
                            controller: entryCode,
                          ),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        IconButton(
                          tooltip: AppText.t('إعادة توليد', 'Regenerate'),
                          onPressed: onRegenerateEntry,
                          icon: Icon(Icons.refresh, size: 20.r),
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
            title: AppText.t('العينات', 'Samples'),
            children: [
              for (var i = 0; i < sampleCount; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                  child: Row(
                    children: [
                      Expanded(
                        child: AppField(
                          label: AppText.t('اسم العينة ${i + 1}', 'Sample #${i + 1}'),
                          controller: sampleNames[i],
                        ),
                      ),
                      if (sampleCount > 1) ...[
                        const SizedBox(width: AppSpacing.sm),
                        IconButton(
                          tooltip: AppText.t('إزالة', 'Remove'),
                          onPressed: () => onRemoveSample(i),
                          icon: Icon(Icons.close, size: 20.r),
                        ),
                      ],
                    ],
                  ),
                ),
              AppButton(
                small: true,
                style: AppButtonStyle.secondary,
                label: AppText.t('إضافة عينة', 'Add Sample'),
                icon: Icon(Icons.add, size: 18.r),
                onPressed: sampleCount >= 3 ? null : onAddSample,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          if (physical.isNotEmpty)
            _Card(
              title: AppText.t('النتائج الفيزيائية', 'Physical results'),
              children: [_resultsGrid(physical)],
            ),
          if (chemical.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.md),
            _Card(
              title: AppText.t('النتائج الكيميائية', 'Chemical results'),
              children: [_resultsGrid(chemical)],
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          _Card(
            title: AppText.t('قرار الجودة', 'Decision'),
            children: [
              DropdownButtonFormField<String>(
                initialValue: state.decision,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: AppText.t('القرار', 'Decision'),
                  isDense: true,
                ),
                items: [
                  DropdownMenuItem(value: 'APPROVED', child: Text(AppText.t('قبول نهائي', 'Approved'))),
                  DropdownMenuItem(
                      value: 'CONDITIONAL_APPROVAL', child: Text(AppText.t('قبول مشروط', 'Conditional'))),
                  DropdownMenuItem(
                      value: 'PARTIAL_REJECTION', child: Text(AppText.t('رفض جزئي', 'Partial rejection'))),
                  DropdownMenuItem(value: 'FULL_REJECTION', child: Text(AppText.t('رفض كامل', 'Full rejection'))),
                ],
                onChanged: (value) {
                  if (value != null) {
                    context.read<InspectionFormCubit>().setDecision(value);
                  }
                },
              ),
              const SizedBox(height: AppSpacing.md),
              if (state.decision == 'CONDITIONAL_APPROVAL') ...[
                AppField(
                  label: AppText.t('ملاحظة المتابعة', 'Follow-up note'),
                  controller: followUp,
                  maxLines: 3,
                ),
                const SizedBox(height: AppSpacing.md),
              ],
              if (state.decision == 'PARTIAL_REJECTION') ...[
                AppField(
                  label: AppText.t('الكمية المرفوضة', 'Rejected quantity'),
                  controller: rejectedQty,
                  keyboardType: TextInputType.numberWithOptions(decimal: true),
                ),
                const SizedBox(height: AppSpacing.md),
              ],
              if (state.decision == 'FULL_REJECTION' || state.decision == 'PARTIAL_REJECTION') ...[
                AppField(
                  label: AppText.t('سبب القرار', 'Decision reason'),
                  controller: decisionReason,
                  maxLines: 3,
                ),
                const SizedBox(height: AppSpacing.md),
              ],
            ],
          ),
          const SizedBox(height: AppSpacing.xl),
          Wrap(
            spacing: AppSpacing.md,
            runSpacing: AppSpacing.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              AppButton(
                label: AppStrings.save,
                icon: Icon(Icons.check, size: 18.r),
                loading: state.saving,
                onPressed: state.saving ? null : onSave,
              ),
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
        if (sampleCount > 1)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.xs),
            child: Row(
              children: [
                const Expanded(flex: 2, child: SizedBox()),
                for (var i = 0; i < sampleCount; i++)
                  Expanded(
                    flex: 3,
                    child: Text(AppText.t('عينة ${i + 1}', 'Sample #${i + 1}'),
                        style: TextStyle(color: AppColors.textMuted, fontSize: 12.spMax)),
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
                        style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13.spMax)),
                  ),
                ),
                Expanded(
                  flex: 3,
                  child: sampleCount == 1
                      ? TextField(
                          controller: source[param]!.first,
                          decoration: const InputDecoration(isDense: true),
                        )
                      : Row(
                          children: [
                            for (var i = 0; i < sampleCount; i++) ...[
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