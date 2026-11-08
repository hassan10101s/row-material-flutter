import 'dart:async';

import '../utils/app_dates.dart';
import '../utils/app_exceptions.dart';
import '../sync/sync_data_changes.dart';
import 'command_contract.dart';
import 'command_outbox.dart';
import 'command_transport.dart';
import 'command_result_recorder.dart';
import 'central_receipt_awaiter.dart';
import 'drafts_store.dart';

/// User-driven writes and read-only receipt recovery. There is no send timer,
/// queue drain or reconnect upload. Every send targets one explicit operation.
class DirectWriteService {
  DirectWriteService({
    required this.outbox,
    required this.transport,
    required this.isOnline,
    required this.synchronize,
    this.waitBudget = const Duration(seconds: 30),
    this.onManualRequest,
  });
  final CommandOutbox outbox;
  final CommandTransport transport;
  final bool Function() isOnline;
  final Future<int> Function(int sequence) synchronize;
  final Duration waitBudget;
  final void Function()? onManualRequest;
  final DateTime _legacyCutoff = DateTime.now();
  final Map<String, Future<void>> _sending = {};
  final Map<String, Future<bool>> _retries = {};
  bool _recovering = false;
  Timer? _outcomeTimer;
  bool _checkingOutcomes = false;
  Future<void>? _outcomeCheck;
  int _monitorGeneration = 0;
  final Map<String, DateTime> _receiptCheckAfter = {};
  Future<bool> Function(CommandOutboxEntry entry, bool approved)? onOutcome;
  bool Function()? mayMonitor;

  void startOutcomeMonitor() {
    _outcomeTimer ??= Timer.periodic(
      const Duration(seconds: 8),
      (_) => unawaited(checkOutcomes()),
    );
    unawaited(checkOutcomes());
  }

  void stopOutcomeMonitor() {
    _monitorGeneration++;
    _outcomeTimer?.cancel();
    _outcomeTimer = null;
    onOutcome = null;
  }

  Future<void> _follow(CommandOutboxEntry entry) async {
    final db = await outbox.dbHelper.database;
    if (!_current(entry)) return;
    await db.rawInsert(
      'INSERT OR IGNORE INTO command_followups(operation_id) VALUES (?)',
      [entry.operationId],
    );
  }

  /// Checks receipts only. No submit, retry, or write to shared business data.
  /// The acknowledged marker survives navigation/restart; removed cards are
  /// still followed, and success requires the complete local projection.
  Future<void> checkOutcomes() async {
    final active = _outcomeCheck;
    if (active != null) return active;
    final future = _checkOutcomes();
    _outcomeCheck = future;
    try {
      await future;
    } finally {
      if (identical(_outcomeCheck, future)) _outcomeCheck = null;
    }
  }

  Future<void> _checkOutcomes() async {
    if (_checkingOutcomes ||
        onOutcome == null ||
        (mayMonitor != null && !mayMonitor!())) {
      return;
    }
    _checkingOutcomes = true;
    final generation = _monitorGeneration;
    try {
      final db = await outbox.dbHelper.database;
      final databaseGeneration = outbox.dbHelper.connectionGeneration;
      final scope = outbox.scopeProvider?.call();
      if (outbox.scopeProvider != null && scope == null) return;
      final rows = await db.rawQuery(
        '''SELECT q.*, f.operation_id AS followed_id
        FROM command_outbox q LEFT JOIN command_followups f ON f.operation_id=q.operation_id
        WHERE q.attempts > 0 AND q.state <> 'archived'
          AND ((f.operation_id IS NOT NULL AND f.notified_at IS NULL)
            OR (f.operation_id IS NULL AND (q.state <> 'approved'
              OR EXISTS (SELECT 1 FROM central_command_entities e WHERE e.operation_id=q.operation_id))))
          ${scope == null ? '' : 'AND q.organization_id = ? AND q.uid = ? AND q.device_id = ?'}
        ORDER BY q.id''',
        scope == null ? [] : [scope.organizationId, scope.uid, scope.deviceId],
      );
      final entries = rows.map(CommandOutboxEntry.fromRow).toList();
      final followed = {
        for (final row in rows)
          if (row['followed_id'] != null) row['operation_id'],
      };
      for (final entry in entries) {
        if (!_current(entry) ||
            entry.attempts == 0 ||
            entry.state == OutboxState.archived) {
          continue;
        }
        if (!followed.contains(entry.operationId)) await _follow(entry);
      }
      final waiting = {
        for (final row in await db.query(
          'command_followups',
          where: 'notified_at IS NULL',
        ))
          row['operation_id'],
      };
      for (final entry in entries) {
        if (generation != _monitorGeneration ||
            databaseGeneration != outbox.dbHelper.connectionGeneration ||
            onOutcome == null) {
          return;
        }
        if (!waiting.contains(entry.operationId) ||
            !_current(entry) ||
            isSending(entry.operationId) ||
            entry.state == OutboxState.archived) {
          continue;
        }
        var current = entry;
        var approved = false;
        final due = _receiptCheckAfter[entry.operationId];
        if ({
              OutboxState.pending,
              OutboxState.inFlight,
              OutboxState.authRequired,
            }.contains(current.state) &&
            due != null &&
            DateTime.now().isBefore(due)) {
          continue;
        }
        if (isOnline() &&
            !{
              OutboxState.rejected,
              OutboxState.needsReview,
            }.contains(current.state)) {
          try {
            approved = await verify(current, resumeQuota: false);
            if (!_current(entry) || generation != _monitorGeneration) return;
            current = await outbox.getByOperationId(entry.operationId) ?? entry;
          } catch (_) {
            continue;
          }
        }
        final rejected = {
          OutboxState.rejected,
          OutboxState.needsReview,
        }.contains(current.state);
        if (!approved && !rejected) {
          _receiptCheckAfter[entry.operationId] = DateTime.now().add(
            const Duration(seconds: 30),
          );
          continue;
        }
        _receiptCheckAfter.remove(entry.operationId);
        final notify = onOutcome;
        if (notify == null ||
            generation != _monitorGeneration ||
            databaseGeneration != outbox.dbHelper.connectionGeneration ||
            !_current(current)) {
          return;
        }
        if (await notify(current, approved) &&
            generation == _monitorGeneration &&
            _current(current)) {
          await db.update(
            'command_followups',
            {'notified_at': nowIso()},
            where: 'operation_id = ?',
            whereArgs: [current.operationId],
          );
        }
        // One visible outcome per tick; later messages cannot immediately
        // replace the previous banner. All remaining results stay durable.
        return;
      }
    } catch (_) {
      // Closed database / account transition / offline: retry reads next tick.
    } finally {
      _checkingOutcomes = false;
    }
  }

  bool isSending(String operationId) => _sending.containsKey(operationId);

  Future<List<CommandOutboxEntry>> openRequests({
    bool includeDismissed = false,
    bool includeCompleted = false,
  }) async {
    final entries = await outbox.list(limit: 100000);
    final db = await outbox.dbHelper.readDatabase;
    final dismissed = includeDismissed
        ? <Object?>{}
        : {
            for (final row in await db.query(
              'dismissed_command_requests',
              columns: ['operation_id'],
            ))
              row['operation_id'],
          };
    final locks = {
      for (final row in await db.query(
        'central_command_entities',
        columns: ['operation_id'],
      ))
        row['operation_id'],
    };
    return entries
        .where(
          (entry) =>
              entry.state != OutboxState.archived &&
              !dismissed.contains(entry.operationId) &&
              (includeCompleted ||
                  entry.state != OutboxState.approved ||
                  locks.contains(entry.operationId)),
        )
        .toList();
  }

  /// Local list removal only. Receipt recovery and immutable request/locks
  /// survive, so a late server answer cannot cause a duplicate operation.
  Future<void> dismissRequest(CommandOutboxEntry entry) async {
    if (!_current(entry)) {
      throw const AuthorizationError('العملية لا تخص الحساب والجهاز الحاليين.');
    }
    if (isSending(entry.operationId)) {
      throw const ValidationError(
        'الطلب قيد الإرسال الآن؛ انتظر انتهاء المحاولة.',
      );
    }
    final db = await outbox.dbHelper.database;
    await db.transaction((txn) async {
      if (!_current(entry) || isSending(entry.operationId)) {
        throw const ValidationError('تغيرت حالة الطلب؛ حدّث القائمة.');
      }
      final rows = await txn.query(
        'command_outbox',
        where: 'operation_id = ? AND organization_id = ? AND uid = ?',
        whereArgs: [entry.operationId, entry.organizationId, entry.uid],
      );
      if (rows.length != 1) throw const ValidationError('الطلب غير متاح.');
      final current = CommandOutboxEntry.fromRow(rows.single);
      if (current.attempts == 0) {
        throw const ValidationError('هذه مسودة لم تُرسل؛ استخدم حذف المسودة.');
      }
      // Idempotent and durable across restart. Never releases an unresolved
      // entity lock or changes the request's state, payload or operation id.
      await txn.rawInsert(
        'INSERT OR IGNORE INTO dismissed_command_requests(operation_id, organization_id, uid, dismissed_at) VALUES (?, ?, ?, ?)',
        [current.operationId, current.organizationId, current.uid, nowIso()],
      );
      await txn.delete(
        'drafts',
        where: 'id = ? AND organization_id = ? AND uid = ?',
        whereArgs: [current.draftId, current.organizationId, current.uid],
      );
    });
    SyncDataChanges.notifyStatus();
  }

  bool _current(CommandOutboxEntry entry) {
    final provider = outbox.scopeProvider;
    final scope = provider?.call();
    return provider == null ||
        (scope != null &&
            scope.owns(entry.organizationId, entry.uid) &&
            scope.deviceId == entry.deviceId);
  }

  Future<bool> submitAndWait(CommandOutboxEntry entry) async {
    if (!isOnline()) return false;
    if (!_current(entry)) {
      throw const AuthorizationError('العملية لا تخص الحساب والجهاز الحاليين.');
    }
    onManualRequest?.call();
    final waiter = CentralReceiptAwaiter(
      outbox: outbox,
      drain: () => _sendOnce(entry),
      synchronize: synchronize,
      isOnline: isOnline,
      isCurrent: _current,
      budget: waitBudget,
    );
    return waiter.wait(entry);
  }

  Future<void> _sendOnce(CommandOutboxEntry entry) {
    final existing = _sending[entry.operationId];
    if (existing != null) return existing;
    final future = _send(entry);
    _sending[entry.operationId] = future;
    return future.whenComplete(() {
      if (identical(_sending[entry.operationId], future)) {
        _sending.remove(entry.operationId);
        unawaited(checkOutcomes());
      }
    });
  }

  Future<void> _send(CommandOutboxEntry entry) async {
    if (!isOnline() || !_current(entry)) return;
    // A callback polling for the answer may re-enter here; only pending,
    // never-attempted work is sent. A manual retry explicitly resets it below.
    final current = await outbox.getByOperationId(entry.operationId);
    if (current == null ||
        current.state != OutboxState.pending ||
        current.attempts > 0) {
      return;
    }
    final claimed = await outbox.claim(
      operationId: entry.operationId,
      limit: 1,
    );
    if (claimed.isEmpty) return;
    final request = claimed.single;
    await _follow(request);
    try {
      final result = await transport.submit(request.envelope());
      if (!_current(request)) return;
      await CommandResultRecorder(outbox).settle(request, result);
    } catch (error) {
      if (!_current(request)) return;
      await outbox.settleRetry(
        request.operationId,
        code: CommandErrorCodes.unavailable,
        message:
            'تعذر تأكيد نتيجة العملية. تحقق من النتيجة قبل إعادة المحاولة.',
      );
    } finally {
      SyncDataChanges.notifyStatus();
    }
  }

  /// Explicit user retry preserves the operation id, content and base version.
  Future<bool> retry(CommandOutboxEntry entry) {
    final existing = _retries[entry.operationId];
    if (existing != null) return existing;
    final future = _retry(entry);
    _retries[entry.operationId] = future;
    return future.whenComplete(() => _retries.remove(entry.operationId));
  }

  Future<bool> _retry(CommandOutboxEntry entry) async {
    if (!isOnline()) {
      throw const ValidationError('إعادة المحاولة تحتاج اتصالًا بالإنترنت.');
    }
    if (isSending(entry.operationId)) return false;
    if (!_current(entry)) throw const AuthorizationError('تغير الحساب الحالي.');
    onManualRequest?.call();
    if (await verify(entry, resumeQuota: false)) return true;
    final db = await outbox.dbHelper.database;
    await db.transaction((txn) async {
      if (!_current(entry)) return;
      final rows = await txn.query(
        'command_outbox',
        where: 'operation_id = ?',
        whereArgs: [entry.operationId],
      );
      final row = rows.isEmpty ? null : CommandOutboxEntry.fromRow(rows.single);
      if (row == null ||
          row.state == OutboxState.approved ||
          row.state == OutboxState.archived ||
          row.state == OutboxState.rejected ||
          row.state == OutboxState.needsReview) {
        return;
      }
      await txn.update(
        'command_outbox',
        {'state': 'pending', 'next_attempt_at': null, 'updated_at': nowIso()},
        where: 'operation_id = ?',
        whereArgs: [entry.operationId],
      );
    });
    // Claim for a manual retry, without resetting the persisted attempt count.
    final claimed = await outbox.claim(
      operationId: entry.operationId,
      limit: 1,
    );
    if (claimed.isEmpty) return false;
    final request = claimed.single;
    await _follow(request);
    final future = () async {
      try {
        final result = await transport.submit(request.envelope());
        if (_current(request)) {
          // An earlier attempt may have committed before its reply was lost.
          // A later permission/version refusal cannot disprove that commit.
          if (!result.isApproved &&
              (commandPermanentErrors.contains(result.failure?.code) ||
                  result.failure?.code == CommandErrorCodes.versionConflict ||
                  result.failure?.code ==
                      CommandErrorCodes.deletedCannotModify)) {
            await outbox.settleRetry(
              request.operationId,
              code: CommandErrorCodes.unavailable,
              message:
                  'تعذر حسم المحاولة السابقة؛ تحقق من إيصال العملية قبل تعديل السجل.',
            );
          } else {
            await CommandResultRecorder(outbox).settle(request, result);
          }
        }
      } catch (_) {
        if (_current(request)) {
          await outbox.settleRetry(
            request.operationId,
            code: CommandErrorCodes.unavailable,
            message: 'تعذر تأكيد النتيجة؛ تحقق منها لاحقًا.',
          );
        }
      } finally {
        SyncDataChanges.notifyStatus();
      }
    }();
    _sending[request.operationId] = future;
    unawaited(
      future.then<void>(
        (_) {
          _sending.remove(request.operationId);
          unawaited(checkOutcomes());
        },
        onError: (Object error, StackTrace stack) {
          _sending.remove(request.operationId);
        },
      ),
    );
    final waiter = CentralReceiptAwaiter(
      outbox: outbox,
      drain: () => future,
      synchronize: synchronize,
      isOnline: isOnline,
      isCurrent: _current,
      budget: waitBudget,
    );
    return waiter.wait(request);
  }

  /// GET receipt only. Absence never causes an automatic retry.
  Future<bool> verify(
    CommandOutboxEntry entry, {
    bool resumeQuota = true,
  }) async {
    if (!isOnline() || !_current(entry)) return false;
    var current = await outbox.getByOperationId(entry.operationId);
    if (current == null) return false;
    if (resumeQuota) onManualRequest?.call();
    if (current.state != OutboxState.approved) {
      final reader = transport;
      if (reader is! CommandReceiptReader || current.attempts == 0) {
        return false;
      }
      final result = await (reader as CommandReceiptReader).lookupReceipt(
        current.envelope(),
      );
      if (result == null || !_current(current)) return false;
      await CommandResultRecorder(outbox).settle(current, result);
      current = await outbox.getByOperationId(entry.operationId);
    }
    final sequence = current?.result?.changeSequence;
    if (current?.state != OutboxState.approved || sequence == null) {
      return false;
    }
    final applied = await synchronize(sequence);
    SyncDataChanges.notifyStatus();
    return applied >= sequence;
  }

  /// Startup/reconnect reconciliation never sends. Old unsent queue entries
  /// become manual drafts; attempted entries are checked by receipt only.
  Future<void> recover({
    bool migrateUnsent = false,
    bool checkReceipts = true,
  }) async {
    if (_recovering) return;
    _recovering = true;
    try {
      final entries = await outbox.list(limit: 100000);
      final db = await outbox.dbHelper.readDatabase;
      final lockedOperations = {
        for (final row in await db.query(
          'central_command_entities',
          columns: ['operation_id'],
        ))
          row['operation_id'],
      };
      for (final entry in entries) {
        if (!_current(entry) || isSending(entry.operationId)) continue;
        if ({
          OutboxState.rejected,
          OutboxState.needsReview,
        }.contains(entry.state)) {
          if (!lockedOperations.contains(entry.operationId)) continue;
          // Older clients could misclassify a failed post-commit receipt read
          // as rejection. Check for that receipt before repairing their locks.
          if (checkReceipts &&
              isOnline() &&
              transport is CommandReceiptReader) {
            try {
              await verify(entry, resumeQuota: false);
              if (_current(entry)) {
                await outbox.releaseSettledLocks(entry.operationId);
              }
            } catch (_) {
              /* Cannot prove the old result yet; keep its protection. */
            }
          }
          continue;
        }
        if (migrateUnsent &&
            entry.state == OutboxState.pending &&
            entry.attempts == 0 &&
            (DateTime.tryParse(entry.createdAt)?.isBefore(_legacyCutoff) ??
                false)) {
          await retainUnsentAsDraft(entry);
        } else if (checkReceipts &&
            entry.attempts > 0 &&
            isOnline() &&
            {
              OutboxState.pending,
              OutboxState.inFlight,
              OutboxState.authRequired,
            }.contains(entry.state)) {
          try {
            await verify(entry, resumeQuota: false);
          } catch (_) {
            /* Keep uncertainty intact. */
          }
        }
      }
    } finally {
      _recovering = false;
      SyncDataChanges.notifyStatus();
    }
  }

  Future<bool> retainUnsentAsDraft(CommandOutboxEntry entry) async {
    if (!_current(entry) || isSending(entry.operationId)) return false;
    final db = await outbox.dbHelper.database;
    return db.transaction((txn) async {
      if (!_current(entry)) return false;
      final changed = await txn.update(
        'command_outbox',
        {'state': 'archived', 'updated_at': nowIso(), 'next_attempt_at': null},
        where: "operation_id = ? AND state = 'pending' AND attempts = 0",
        whereArgs: [entry.operationId],
      );
      if (changed == 0) return false;
      await txn.delete(
        'central_command_entities',
        where: 'operation_id = ?',
        whereArgs: [entry.operationId],
      );
      await DraftsStore.transition(
        txn,
        entry.draftId,
        state: DraftState.localDraft,
      );
      return true;
    });
  }

  Future<bool> cancelUnsent(CommandOutboxEntry entry) async {
    if (!_current(entry) || isSending(entry.operationId)) return false;
    final db = await outbox.dbHelper.database;
    return db.transaction((txn) async {
      if (!_current(entry)) return false;
      final changed = await txn.delete(
        'command_outbox',
        where: "operation_id = ? AND state = 'pending' AND attempts = 0",
        whereArgs: [entry.operationId],
      );
      if (changed == 0) return false;
      await txn.delete(
        'central_command_entities',
        where: 'operation_id = ?',
        whereArgs: [entry.operationId],
      );
      await txn.delete('drafts', where: 'id = ?', whereArgs: [entry.draftId]);
      return true;
    });
  }
}
