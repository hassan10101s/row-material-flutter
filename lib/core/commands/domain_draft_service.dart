import '../auth/session_source.dart';
import '../sync/sync_run_scope.dart';
import '../utils/app_exceptions.dart';
import 'command_contract.dart';
import 'command_outbox.dart';
import 'drafts_store.dart';

/// Explicit user submission. Recovery workers only see requests created here
/// (or by an online save); they never scan the drafts table for work.
class DomainDraftService {
  DomainDraftService({
    required this.drafts,
    required this.outbox,
    required this.source,
    required this.isOnline,
  });
  final DraftsStore drafts;
  final CommandOutbox outbox;
  final SessionSource source;
  final bool Function() isOnline;

  Future<CommandOutboxEntry> submit(String draftId) async {
    if (!isOnline()) {
      throw const ValidationError('الإرسال يحتاج اتصالًا بالإنترنت.');
    }
    final scope = SyncRunScope(source, outbox.dbHelper);
    final actor = scope.session;
    if (!actor.canWrite) {
      throw const AuthorizationError('ليس لديك صلاحية الإرسال.');
    }
    final db = await outbox.dbHelper.database;
    final entry = await db.transaction((txn) async {
      scope.check();
      final rows = await txn.query(
        'drafts',
        where: 'id = ? AND organization_id = ? AND uid = ?',
        whereArgs: [draftId, actor.organizationId, actor.uid],
      );
      if (rows.length != 1) {
        throw const ValidationError('المسودة غير متاحة لهذا الحساب.');
      }
      final draft = CommandDraft.fromRow(rows.single);
      if (draft.entityType != 'domainTransaction' ||
          draft.state != DraftState.localDraft) {
        throw const ValidationError(
          'راجع نتيجة الطلب السابق قبل إعادة الإرسال.',
        );
      }
      final writes = draft.payload['writes'];
      if (writes is! List || writes.isEmpty) {
        throw const ValidationError('مسودة بلا تغييرات.');
      }
      if (writes.length > businessEffectLimit(writes)) {
        throw const ValidationError(largeOperationMessage);
      }
      for (final raw in writes) {
        final w = raw as Map;
        final locks = await txn.query(
          'central_command_entities',
          where: 'entity_type = ? AND entity_id = ?',
          whereArgs: [w['entityType'], w['entityId']],
          limit: 1,
        );
        if (locks.isNotEmpty) {
          throw const ValidationError('يوجد طلب سابق لهذا السجل.');
        }
      }
      final staged = await outbox.enqueueDraftSubmit(
        txn,
        draft: draft,
        commandType: CommandTypes.domainCommit,
        entityId: draft.entityId,
        expectedVersion: 0,
        payload: draft.payload,
        dependencies: const {},
      );
      for (final raw in writes) {
        final w = raw as Map;
        await txn.insert('central_command_entities', {
          'entity_type': w['entityType'],
          'entity_id': w['entityId'],
          'operation_id': staged.operationId,
        });
      }
      scope.check();
      return staged;
    });
    return entry;
  }
}
