import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../core/constants/app_strings.dart';
import '../../../core/utils/app_exceptions.dart';
import '../../../design_system/feedback/app_feedback.dart';
import '../../../design_system/tokens/app_spacing.dart';
import '../domain/lab_local_repository.dart';

/// The global-constant editor, shared by both experiences.
///
/// The desktop variant presents this as an `AlertDialog` with Cancel/Save
/// actions; the mobile variant presents it as a full-screen route with a
/// single Save button. The fields and the save logic are identical either way,
/// so they live here once - only the *chrome* differs, via [actions]. A phone
/// cannot show a 440dp dialog, but it can show these same five fields stacked.
///
/// [actions] is handed this widget's [State] so a host can read `saving` and
/// call [ConstantsEditorState.submit] without any key or scope plumbing - the
/// flag and the submit call can therefore never get out of step.
class ConstantsEditor extends StatefulWidget {
  const ConstantsEditor({
    super.key,
    required this.repo,
    this.constant,
    this.actions,
  });

  /// The constant being edited, or null to create one.
  final Map<String, dynamic>? constant;

  /// Injected rather than resolved, so the form is testable and no variant can
  /// reach past the domain contract.
  final LabLocalRepository repo;

  /// Builds the per-experience action row. Omit it to render the fields only.
  final Widget Function(BuildContext context, ConstantsEditorState state)?
  actions;

  @override
  State<ConstantsEditor> createState() => ConstantsEditorState();
}

class ConstantsEditorState extends State<ConstantsEditor> {
  late final TextEditingController _name = TextEditingController(
    text: '${widget.constant?['name'] ?? ''}',
  );
  late final TextEditingController _symbol = TextEditingController(
    text: '${widget.constant?['symbol'] ?? ''}',
  );
  late final TextEditingController _value = TextEditingController(
    text: '${widget.constant?['value_text'] ?? ''}',
  );
  late final TextEditingController _unit = TextEditingController(
    text: '${widget.constant?['unit'] ?? ''}',
  );
  late final TextEditingController _description = TextEditingController(
    text: '${widget.constant?['description'] ?? ''}',
  );
  late bool _isExpression =
      (widget.constant?['is_expression'] as num?)?.toInt() == 1;
  late final TextEditingController _expression = TextEditingController(
    text:
        '${(widget.constant?['expression'] is Map ? (widget.constant?['expression'] as Map)['expression'] : widget.constant?['expression']) ?? ''}',
  );

  bool _saving = false;
  bool get saving => _saving;

  @override
  void dispose() {
    _name.dispose();
    _symbol.dispose();
    _value.dispose();
    _unit.dispose();
    _description.dispose();
    _expression.dispose();
    super.dispose();
  }

  /// Validates, saves, then pops with `true` so the caller knows to reload.
  Future<void> submit() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final payload = <String, dynamic>{
        if (widget.constant != null) 'id': widget.constant!['id'],
        'name': _name.text.trim(),
        'symbol': _symbol.text.trim(),
        'unit': _unit.text.trim(),
        'description': _description.text.trim(),
        'is_expression': _isExpression,
        'expression': _expression.text.trim(),
        'value_text': _value.text.trim(),
      };
      await widget.repo.upsertGlobalConstant(payload);
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
    final actions = widget.actions?.call(context, this);
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
        TextField(
          controller: _symbol,
          decoration: InputDecoration(
            labelText: AppText.t('الرمز', 'Symbol'),
            isDense: true,
          ),
        ),
        Row(
          children: [
            Expanded(
              child: SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(AppText.t('تعبير', 'Expression')),
                value: _isExpression,
                onChanged: (v) => setState(() => _isExpression = v),
              ),
            ),
            Expanded(
              child: TextField(
                controller: _unit,
                decoration: InputDecoration(
                  labelText: AppText.t('الوحدة', 'Unit'),
                  isDense: true,
                ),
              ),
            ),
          ],
        ),
        if (_isExpression)
          TextField(
            controller: _expression,
            maxLines: 3,
            decoration: InputDecoration(
              labelText: AppText.t('المعادلة', 'Expression'),
              isDense: true,
            ),
          )
        else
          TextField(
            controller: _value,
            decoration: InputDecoration(
              labelText: AppText.t('القيمة', 'Value'),
              isDense: true,
            ),
          ),
        TextField(
          controller: _description,
          decoration: InputDecoration(
            labelText: AppText.t('الوصف', 'Description'),
            isDense: true,
          ),
        ),
        if (actions != null) ...[
          const SizedBox(height: AppSpacing.md),
          actions,
        ],
      ],
    );
  }
}

/// Cancel button, shared so both variants dismiss the same way.
class ConstantsEditorCancel extends StatelessWidget {
  const ConstantsEditorCancel({super.key});

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: () => Navigator.of(context).pop(false),
    child: Text(AppStrings.cancel),
  );
}

/// Save button, shared so both variants submit identically.
class ConstantsEditorSave extends StatelessWidget {
  const ConstantsEditorSave({super.key, required this.state});

  final ConstantsEditorState state;

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      onPressed: state.saving ? null : state.submit,
      child: state.saving
          ? SizedBox(
              width: 18.r,
              height: 18.r,
              child: const CircularProgressIndicator(strokeWidth: 2),
            )
          : Text(AppStrings.save),
    );
  }
}

/// Title for the create/edit chrome. Bilingual, unlike the hardcoded Arabic the
/// pre-split dialog carried.
String constantsEditorTitle(bool isNew) => isNew
    ? AppText.t('إضافة ثابت', 'Add constant')
    : AppText.t('تعديل ثابت', 'Edit constant');
