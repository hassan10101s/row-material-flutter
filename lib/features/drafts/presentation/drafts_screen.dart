import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';

import '../../../app/auth_gate.dart';
import '../../../core/constants/app_strings.dart';
import '../../../core/commands/command_contract.dart';
import '../../../core/commands/command_outbox.dart';
import '../../../core/commands/direct_write_service.dart';
import '../../../core/commands/domain_draft_service.dart';
import '../../../core/commands/drafts_store.dart';
import '../../../core/sync/sync_data_changes.dart';
import '../../../design_system/feedback/app_feedback.dart';
import '../../../design_system/tokens/app_spacing.dart';
import '../../../design_system/widgets/app_button.dart';
import '../../../design_system/widgets/app_card.dart';
import '../../../design_system/widgets/app_dialogs.dart';
import '../../../design_system/widgets/app_empty_state.dart';
import '../../../design_system/widgets/app_window.dart';
import '../../../di/service_locator.dart';

class DraftsScreen extends StatefulWidget {
  const DraftsScreen({super.key, this.showTitle = true});
  final bool showTitle;

  static Future<void> open(
    BuildContext context, {
    VoidCallback? onRefreshData,
  }) => showAppContent<void>(
    context,
    title: AppText.t('المسودات', 'Drafts'),
    icon: Icons.drafts_outlined,
    size: AppWindowSize.lg,
    scrollBody: false,
    builder: (_, _) => DraftsScreen(showTitle: false),
    actionsBuilder: onRefreshData == null
        ? null
        : (_, _) => [
            AppButton(
              label: AppText.t('تحديث البيانات', 'Refresh data'),
              icon: const Icon(Icons.refresh),
              onPressed: onRefreshData,
            ),
          ],
  );
  @override
  State<DraftsScreen> createState() => _DraftsScreenState();
}

class _DraftsScreenState extends State<DraftsScreen> {
  final _busy = <String>{};
  List<CommandDraft> _drafts = [];
  List<CommandOutboxEntry> _requests = [];
  String? _error;
  bool _loading = true;
  bool _showRemovedRequests = false;
  bool _showCompletedRequests = false;
  StreamSubscription<void>? _data, _status;
  int _loadVersion = 0;

  @override
  void initState() {
    super.initState();
    _data = SyncDataChanges.stream.listen((_) => unawaited(_load()));
    _status = SyncDataChanges.statusStream.listen((_) => unawaited(_load()));
    unawaited(_load());
  }

  @override
  void dispose() {
    _data?.cancel();
    _status?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final version = ++_loadVersion;
    try {
      final drafts = await getIt<DraftsStore>().listOpen(limit: 100000);
      final writes = getIt<DirectWriteService>();
      final requests = _showCompletedRequests
          ? await writes.openRequests(
              includeDismissed: _showRemovedRequests,
              includeCompleted: true,
            )
          : _showRemovedRequests
          ? await writes.openRequests(includeDismissed: true)
          : await writes.openRequests();
      if (!mounted || version != _loadVersion) return;
      setState(() {
        _drafts = drafts
            .where((d) => d.state == DraftState.localDraft)
            .toList();
        _requests = requests;
        _loading = false;
        _error = null;
      });
    } catch (_) {
      if (!mounted || version != _loadVersion) return;
      setState(() {
        _error = AppText.t(
          'تعذر تحميل المسودات. أعد المحاولة.',
          'Could not load drafts. Try again.',
        );
        _loading = false;
      });
    }
  }

  Future<void> _run(String id, Future<void> Function() action) async {
    if (!mounted || _busy.contains(id)) return;
    setState(() => _busy.add(id));
    try {
      await action();
    } catch (error) {
      if (mounted) AppFeedback.errorFrom(context, error);
    } finally {
      if (mounted) {
        setState(() => _busy.remove(id));
        await _load();
      }
    }
  }

  List<Map> _writes(Map<String, dynamic> payload) => [
    for (final value in payload['writes'] as List? ?? const [])
      if (value is Map) value,
  ];
  String _name(Map write) {
    final data = write['payload'] as Map? ?? const {};
    for (final key in [
      'materialName',
      'entryCode',
      'name',
      'title',
      'symbol',
      'sheetDate',
    ]) {
      if ('${data[key] ?? ''}'.trim().isNotEmpty) return '${data[key]}';
    }
    return AppText.t('سجل مرتبط', 'Related record');
  }

  String _title(Map<String, dynamic> payload) {
    final writes = _writes(payload);
    if (writes.isEmpty) return AppText.t('مسودة محفوظة', 'Saved draft');
    final first = writes.first;
    final operation = first['operation'] == 'create'
        ? AppText.t('إنشاء', 'Create')
        : first['operation'] == 'tombstone'
        ? AppText.t('حذف', 'Delete')
        : AppText.t('تعديل', 'Update');
    return '$operation: ${_name(first)}';
  }

  bool _technical(String key) =>
      key.endsWith('Id') ||
      key.endsWith('Ids') ||
      const {
        'version',
        'remoteVersion',
        'remoteSyncedAt',
        'deviceId',
        'protocol',
        'createdBy',
        'updatedBy',
        'createdAt',
        'updatedAt',
        'importedAt',
        'deletedAt',
        'organizationId',
      }.contains(key);
  String _value(Object? value) {
    if (value == null) return '-';
    if (value is String) {
      try {
        return _value(jsonDecode(value));
      } catch (_) {
        return value;
      }
    }
    if (value is Map || value is List) {
      return const JsonEncoder.withIndent('  ').convert(value);
    }
    return '$value';
  }

  String _field(String key) => switch (key) {
    'materialName' => AppText.t('اسم الخامة', 'Material name'),
    'materialCode' => AppText.t('الكود', 'Code'),
    'name' => AppText.t('الاسم', 'Name'),
    'entryCode' => AppText.t('كود الفحص', 'Entry code'),
    'supplier' => AppText.t('المورد', 'Supplier'),
    'quantity' => AppText.t('الكمية', 'Quantity'),
    'inspectionDate' => AppText.t('تاريخ الفحص', 'Inspection date'),
    'physicalReferenceJson' => AppText.t(
      'المواصفات الظاهرية',
      'Physical specifications',
    ),
    'chemicalReferenceJson' => AppText.t(
      'المواصفات الكيميائية',
      'Chemical specifications',
    ),
    'unit' => AppText.t('الوحدة', 'Unit'),
    'title' => AppText.t('العنوان', 'Title'),
    'minValue' => AppText.t('الحد الأدنى', 'Minimum'),
    'maxValue' => AppText.t('الحد الأقصى', 'Maximum'),
    'description' => AppText.t('الوصف', 'Description'),
    'decisionStatus' => AppText.t('القرار', 'Decision'),
    _ => key.replaceAllMapped(
      RegExp(r'[A-Z]'),
      (m) => ' ${m[0]!.toLowerCase()}',
    ),
  };

  Future<void> _preview(Map<String, dynamic> payload) => showAppContent<void>(
    context,
    title: AppText.t('مراجعة المسودة', 'Review draft'),
    size: AppWindowSize.lg,
    builder: (_, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final write in _writes(payload))
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.md),
            child: AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _name(write),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  for (final entry
                      in (write['payload'] as Map? ?? const {}).entries)
                    if (!_technical('${entry.key}'))
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: SelectableText(
                          '${_field('${entry.key}')}: ${_value(entry.value)}',
                        ),
                      ),
                ],
              ),
            ),
          ),
      ],
    ),
  );
  void _outcome(bool done) {
    if (!mounted) return;
    if (done) {
      AppFeedback.success(
        context,
        AppText.t('تم تأكيد الحفظ على السيرفر', 'Save confirmed by server'),
      );
    } else {
      AppFeedback.info(
        context,
        AppText.t(
          'لم يصل تأكيد بعد. تحقق من النتيجة قبل إعادة المحاولة.',
          'No confirmation yet. Check the result before retrying.',
        ),
      );
    }
  }

  Future<void> _submit(CommandDraft draft) async {
    if (!await showAppConfirm(
      context,
      title: AppText.t('إرسال المسودة؟', 'Submit draft?'),
      message: AppText.t(
        'سيتم إرسال هذه التغييرات إلى السيرفر بصلاحيات حسابك الحالية.',
        'These changes will be submitted to the server using your current permissions.',
      ),
    )) {
      return;
    }
    if (!mounted) return;
    await _run(draft.id, () async {
      final entry = await getIt<DomainDraftService>().submit(draft.id);
      _outcome(await getIt<DirectWriteService>().submitAndWait(entry));
    });
  }

  Future<void> _delete(CommandDraft draft) async {
    if (!await showAppConfirm(
      context,
      title: AppText.t('حذف المسودة؟', 'Delete draft?'),
      confirmLabel: AppText.t('حذف المسودة', 'Delete draft'),
      message: AppText.t(
        'ستُحذف المسودة المحلية فقط. لن تتغير بيانات السيرفر.',
        'Only the local draft will be deleted. Server data will not change.',
      ),
      danger: true,
    )) {
      return;
    }
    if (!mounted) return;
    await _run(draft.id, () async {
      await getIt<DraftsStore>().deleteUnsent(draft.id);
      if (mounted) {
        AppFeedback.success(
          context,
          AppText.t('تم حذف المسودة', 'Draft deleted'),
        );
      }
    });
  }

  Future<void> _removeEvent(CommandOutboxEntry entry) async {
    if (!await showAppConfirm(
      context,
      title: AppText.t('إزالة الحدث من القائمة؟', 'Remove event from list?'),
      confirmLabel: AppText.t('إزالة الحدث', 'Remove event'),
      message: AppText.t(
        'ستُحذف نسخة المسودة من الجهاز ويُزال الحدث من القائمة. هذا لا يلغي طلبًا وصل للخادم؛ سنحتفظ بمعرّفه لمتابعة الإيصال ومنع التكرار. يمكنك عرضه من «عرض الأحداث المُزالة».',
        'The local draft copy will be deleted and the event removed from the list. This does not cancel a request received by the server. Its identity remains for receipt recovery and duplicate protection. You can view it under Show removed events.',
      ),
      danger: true,
    )) {
      return;
    }
    if (!mounted) return;
    await _run(entry.operationId, () async {
      await getIt<DirectWriteService>().dismissRequest(entry);
      if (mounted) {
        AppFeedback.success(
          context,
          AppText.t('تمت إزالة الحدث من القائمة', 'Event removed from list'),
        );
      }
    });
  }

  Future<void> _retry(CommandOutboxEntry entry) async {
    if (!await showAppConfirm(
      context,
      title: AppText.t('إعادة محاولة العملية؟', 'Retry operation?'),
      message: AppText.t(
        'سنتحقق من النتيجة أولًا، ثم نستخدم نفس الطلب لمنع التكرار.',
        'We will check the result first, then reuse the same request to prevent duplicates.',
      ),
    )) {
      return;
    }
    if (!mounted) return;
    await _run(entry.operationId, () async {
      _outcome(await getIt<DirectWriteService>().retry(entry));
    });
  }

  Future<void> _closeRejected(CommandOutboxEntry entry) async {
    if (!await showAppConfirm(
      context,
      title: AppText.t('حذف المسودة المرفوضة؟', 'Delete rejected draft?'),
      confirmLabel: AppText.t('حذف المسودة', 'Delete draft'),
      message: AppText.t(
        'ستُحذف المسودة من هذا الجهاز نهائيًا، وسيبقى سجل الطلب وسبب الرفض لمنع تكراره. لن تتغير بيانات السيرفر.',
        'The draft will be permanently deleted from this device. The request and rejection reason remain to prevent replay. Server data will not change.',
      ),
      danger: true,
    )) {
      return;
    }
    if (!mounted) return;
    await _run(entry.operationId, () async {
      final closed = await getIt<CommandOutbox>().releaseLockAndArchive(
        entry.operationId,
        deleteDraft: true,
      );
      if (closed && mounted) {
        AppFeedback.info(context, AppText.t('تم حذف المسودة', 'Draft deleted'));
      }
    });
  }

  @override
  Widget build(BuildContext buildContext) {
    final online = getIt<AuthGate>().online;
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return AppEmptyState(
        icon: Icons.error_outline,
        title: _error!,
        action: AppButton(
          label: AppText.t('إعادة المحاولة', 'Retry'),
          onPressed: _load,
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        if (widget.showTitle)
          Text(
            AppText.t('المسودات', 'Drafts'),
            style: Theme.of(context).textTheme.titleLarge,
          ),
        if (widget.showTitle) const SizedBox(height: AppSpacing.sm),
        Text(
          AppText.t(
            'مسودات هذا الجهاز لا تُرسل تلقائيًا عند عودة الإنترنت. راجعها ثم أرسلها بنفسك.',
            'Drafts on this device are never sent automatically when connection returns. Review and submit them yourself.',
          ),
        ),
        AppButton(
          label: _showRemovedRequests
              ? AppText.t('إخفاء الأحداث المُزالة', 'Hide removed events')
              : AppText.t('عرض الأحداث المُزالة', 'Show removed events'),
          style: AppButtonStyle.ghost,
          onPressed: () {
            setState(() => _showRemovedRequests = !_showRemovedRequests);
            unawaited(_load());
          },
        ),
        AppButton(
          label: _showCompletedRequests
              ? AppText.t(
                  'إخفاء العمليات المكتملة',
                  'Hide completed operations',
                )
              : AppText.t('عرض العمليات المكتملة', 'Show completed operations'),
          style: AppButtonStyle.ghost,
          onPressed: () {
            setState(() => _showCompletedRequests = !_showCompletedRequests);
            unawaited(_load());
          },
        ),
        if (_drafts.isEmpty && _requests.isEmpty)
          AppEmptyState(
            icon: Icons.drafts_outlined,
            title: AppText.t(
              'لا توجد مسودات أو طلبات تحتاج مراجعة',
              'No drafts or requests to review',
            ),
          ),
        for (final draft in _drafts)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.md),
            child: AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _title(draft.payload),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  Text(
                    AppText.t(
                      'محفوظة محليًا ولم تُرسل',
                      'Saved locally, not submitted',
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Wrap(
                    spacing: AppSpacing.sm,
                    runSpacing: AppSpacing.sm,
                    children: [
                      AppButton(
                        label: AppText.t('مراجعة', 'Review'),
                        style: AppButtonStyle.secondary,
                        onPressed: () => _preview(draft.payload),
                      ),
                      AppButton(
                        label: AppText.t('إرسال', 'Submit'),
                        loading: _busy.contains(draft.id),
                        onPressed:
                            !online ||
                                _busy.contains(draft.id) ||
                                draft.entityType != 'domainTransaction' ||
                                _writes(draft.payload).isEmpty ||
                                _writes(draft.payload).length >
                                    businessEffectLimit(_writes(draft.payload))
                            ? null
                            : () => _submit(draft),
                      ),
                      AppButton(
                        label: AppText.t('حذف المسودة', 'Delete draft'),
                        icon: const Icon(Icons.delete_outline),
                        style: AppButtonStyle.danger,
                        onPressed: _busy.contains(draft.id)
                            ? null
                            : () => _delete(draft),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        if (_requests.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
            child: Text(
              AppText.t('متابعة العمليات', 'Operation history'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
        for (final entry in _requests)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.md),
            child: AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _title(entry.payload),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  Text(
                    {
                          OutboxState.rejected,
                          OutboxState.needsReview,
                        }.contains(entry.state)
                        ? AppText.t('تعذر تنفيذ العملية', 'Operation failed')
                        : entry.state == OutboxState.approved
                        ? AppText.t(
                            'أكّد الخادم الحفظ',
                            'Server confirmed the save',
                          )
                        : AppText.t(
                            'بانتظار تأكيد الخادم',
                            'Awaiting server confirmation',
                          ),
                  ),
                  Text(
                    entry.result?.failure?.messageAr ??
                        entry.lastError ??
                        AppText.t(
                          'بانتظار تأكيد نتيجة السيرفر',
                          'Awaiting server confirmation',
                        ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Wrap(
                    spacing: AppSpacing.sm,
                    runSpacing: AppSpacing.sm,
                    children: [
                      AppButton(
                        label: AppText.t('مراجعة', 'Review'),
                        style: AppButtonStyle.secondary,
                        onPressed: () => _preview(entry.payload),
                      ),
                      if ({
                        OutboxState.rejected,
                        OutboxState.needsReview,
                      }.contains(entry.state))
                        AppButton(
                          label: AppText.t('حذف المسودة', 'Delete draft'),
                          icon: const Icon(Icons.delete_outline),
                          style: AppButtonStyle.danger,
                          onPressed: _busy.contains(entry.operationId)
                              ? null
                              : () => _closeRejected(entry),
                        )
                      else ...[
                        AppButton(
                          label: AppText.t('إزالة الحدث', 'Remove event'),
                          icon: const Icon(Icons.delete_outline),
                          style: AppButtonStyle.danger,
                          onPressed:
                              entry.attempts == 0 ||
                                  _busy.contains(entry.operationId) ||
                                  getIt<DirectWriteService>().isSending(
                                    entry.operationId,
                                  )
                              ? null
                              : () => _removeEvent(entry),
                        ),
                        AppButton(
                          label: AppText.t('تحقق من النتيجة', 'Check result'),
                          onPressed:
                              !online || _busy.contains(entry.operationId)
                              ? null
                              : () => _run(entry.operationId, () async {
                                  _outcome(
                                    await getIt<DirectWriteService>().verify(
                                      entry,
                                    ),
                                  );
                                }),
                        ),
                        if (entry.state != OutboxState.approved)
                          AppButton(
                            label: AppText.t('إعادة المحاولة', 'Retry'),
                            style: AppButtonStyle.ghost,
                            onPressed:
                                !online ||
                                    _busy.contains(entry.operationId) ||
                                    getIt<DirectWriteService>().isSending(
                                      entry.operationId,
                                    )
                                ? null
                                : () => _retry(entry),
                          ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
