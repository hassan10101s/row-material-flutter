import '../../../../di/service_locator.dart';
import '../../../../core/security/secure_field_access.dart';
import '../../../../core/security/secure_display_guard.dart';
import 'package:flutter/material.dart';
import '../../../../core/constants/app_strings.dart';
import '../../../../design_system/widgets/app_window.dart';
import '../../../../design_system/widgets/app_button.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../domain/nir_validation_repository.dart';

Future<void> showNirCalibrationHistory(
  BuildContext context, {
  required List<NirValidationSettings> history,
  required List<NirParameterStats> current,
  required Future<List<NirValidationSettings>> Function(int limit) loadHistory,
}) => showAppContent<void>(
  context,
  title: AppText.t('سجل المعايرة', 'Calibration history'),
  subtitle: AppText.t(
    'دورات المقارنة والتعديلات المسجّلة بعد اعتماد السيرفر',
    'Comparison cycles and recorded adjustments after server approval',
  ),
  icon: Icons.history,
  size: AppWindowSize.lg,
  builder: (_, _) =>
      SecureDisplayGuard(access: getIt.isRegistered<SecureFieldAccess>() ? getIt<SecureFieldAccess>() : null, child: _History(history: history, current: current, loadHistory: loadHistory)),
);

class _History extends StatefulWidget {
  const _History({
    required this.history,
    required this.current,
    required this.loadHistory,
  });
  final List<NirValidationSettings> history;
  final List<NirParameterStats> current;
  final Future<List<NirValidationSettings>> Function(int limit) loadHistory;
  @override
  State<_History> createState() => _HistoryState();
}

class _HistoryState extends State<_History> {
  late List<NirValidationSettings> _history = widget.history;
  int _limit = 50;
  bool _loading = false;
  String? _error;

  Future<void> _more() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final limit = _limit + 50;
      final records = await widget.loadHistory(limit);
      if (mounted) {
        setState(() {
          _history = records;
          _limit = limit;
        });
      }
    } on Object catch (error) {
      if (mounted) setState(() => _error = AppError.friendly(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _number(Object? value) =>
      value is num && value.isFinite ? value.toStringAsFixed(4) : '—';

  NirParameterStats? _current(
    NirValidationSettings record,
    Map<String, dynamic> summary,
  ) {
    final matches = widget.current.where((stat) {
      if (NirValidationSettings.scopeValue(stat.scope) != summary['scope'] ||
          stat.parameter.trim().toLowerCase() !=
              '${summary['parameter']}'.trim().toLowerCase()) {
        return false;
      }
      final remoteId = '${summary['entityRemoteId'] ?? ''}';
      if (remoteId.isNotEmpty) return stat.entityRemoteId == remoteId;
      final id = stat.scope == NirScope.rawMaterial
          ? record.materialId
          : record.productId;
      return id != null
          ? stat.entityId == id
          : stat.entityName == summary['entityName'];
    }).toList();
    return matches.length == 1 ? matches.single : null;
  }

  Widget _summary(NirValidationSettings record, Map<String, dynamic> summary) {
    final current = _current(record, summary);
    final metrics = [
      (
        AppText.t('عدد النقاط', 'Pairs'),
        '${summary['count'] ?? '—'}',
        current == null ? '—' : '${current.count}',
      ),
      (
        AppText.t('الانحراف NIR − المعمل', 'Bias NIR − lab'),
        _number(summary['bias']),
        _number(current?.bias),
      ),
      (
        'R²',
        _number(summary['r2']),
        _number(current == null || current.count < 2 ? null : current.r2),
      ),
      (
        'RMSE',
        _number(summary['rmse']),
        _number(current == null || current.count < 2 ? null : current.rmse),
      ),
      (
        AppText.t('الميل فقط', 'Slope only'),
        _number(summary['slopeOnly']),
        _number(current?.slopeOnly),
      ),
      (
        AppText.t('الميل مع القاطع', 'Full-fit slope'),
        _number(summary['slope']),
        _number(current == null || current.count < 2 ? null : current.slope),
      ),
      (
        AppText.t('القاطع', 'Intercept'),
        _number(summary['intercept']),
        _number(
          current == null || current.count < 2 ? null : current.intercept,
        ),
      ),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${summary['entityName']} · ${summary['parameter']} (${summary['unit'] ?? ''})',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          Text(
            '${AppText.t('الدورة السابقة من', 'Previous cycle from')}: ${'${summary['horizonStart'] ?? ''}'.isEmpty ? AppText.t('بداية السجل', 'Beginning of history') : summary['horizonStart']}',
          ),
          Table(
            columnWidths: const {
              0: FlexColumnWidth(2),
              1: FlexColumnWidth(),
              2: FlexColumnWidth(),
            },
            children: [
              TableRow(
                children: [
                  const SizedBox(),
                  Text(AppText.t('قبل التصفير', 'Before reset')),
                  Text(AppText.t('الحالي', 'Current')),
                ],
              ),
              for (final metric in metrics)
                TableRow(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(4),
                      child: Text(metric.$1),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(4),
                      child: Text(metric.$2),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(4),
                      child: Text(metric.$3),
                    ),
                  ],
                ),
            ],
          ),
          Text(
            '${AppText.t('مقترح الميل فقط', 'Proposed slope only')}: ${_number(summary['slopeOnly'])}',
          ),
          Text(
            '${AppText.t('الميل والقاطع المقترحان', 'Proposed slope and intercept')}: a=${_number(summary['slope'])}, b=${_number(summary['intercept'])}',
          ),
          Text(
            '${AppText.t('بداية الفترة الحالية', 'Current period start')}: ${current?.horizonStart.isNotEmpty == true ? current!.horizonStart : '—'}',
          ),
          if (current == null)
            Text(
              AppText.t(
                'لا تتوفر نقاط مطابقة للدورة الحالية في البيانات المحمّلة.',
                'No matching current-cycle statistics are available in the loaded data.',
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        AppText.t(
          '«قبل التصفير» ملخص ثابت وقت إعداد الطلب. «الحالي» حساب من البيانات المتاحة الآن، وليس إثباتًا أن تعديل الجهاز سبّب تحسنًا.',
          'Before reset is a fixed summary captured when preparing the request. Current uses data available now and does not establish that a device adjustment caused improvement.',
        ),
      ),
      const SizedBox(height: AppSpacing.md),
      if (_history.isEmpty)
        Text(
          AppText.t(
            'لا توجد دورات معايرة مسجّلة بعد.',
            'No calibration cycles recorded yet.',
          ),
        ),
      for (final record in _history)
        ExpansionTile(
          key: ValueKey('nir-reset-${record.id}'),
          title: Text(
            record.isGlobal
                ? AppText.t('بدء دورة عامة', 'Global cycle reset')
                : '${record.entityName} · ${record.parameter}',
          ),
          subtitle: Text(
            '${AppText.t('بداية الدورة', 'Cycle start')}: ${record.startDate}\n${AppText.t('بواسطة', 'By')}: ${record.resetByName} · ${record.createdAt}',
          ),
          childrenPadding: const EdgeInsets.all(AppSpacing.sm),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (record.resetNote.isNotEmpty)
              Text(
                '${AppText.t('السبب والإجراء', 'Reason and action')}: ${record.resetNote}',
              ),
            if (record.calibrationSnapshot == null)
              Text(
                AppText.t(
                  'سجل قديم: لم يُحفظ ملخص المعايرة وقت هذا التصفير.',
                  'Legacy record: no calibration summary was captured at this reset.',
                ),
              )
            else ...[
              Text(
                '${AppText.t('وقت التقاط الملخص', 'Summary captured at')}: ${record.calibrationSnapshot!.capturedAt}',
              ),
              if (record.calibrationSnapshot!.summaries.isEmpty)
                Text(
                  AppText.t(
                    'لم تتوفر نقاط مطابقة وقت إعداد الطلب.',
                    'No matched pairs were available when preparing the request.',
                  ),
                ),
              for (final summary in record.calibrationSnapshot!.summaries)
                _summary(record, summary),
            ],
            const SizedBox(height: AppSpacing.sm),
            Text(
              record.calibrationSnapshot?.appliedCorrection == null
                  ? AppText.t(
                      'لم يُسجّل تعديل مطبّق على الجهاز.',
                      'No applied device adjustment was recorded.',
                    )
                  : '${AppText.t('تعديل أكّد المستخدم تطبيقه', 'Adjustment reported as applied by the operator')}: a=${_number(record.calibrationSnapshot!.appliedCorrection!.slope)}, b=${_number(record.calibrationSnapshot!.appliedCorrection!.intercept)}',
            ),
          ],
        ),
      if (_error != null) Text(_error!),
      if (_history.length >= _limit)
        AppButton(
          label: AppText.t('تحميل سجلات أقدم', 'Load older records'),
          loading: _loading,
          onPressed: _loading ? null : _more,
          style: AppButtonStyle.secondary,
        ),
    ],
  );
}
