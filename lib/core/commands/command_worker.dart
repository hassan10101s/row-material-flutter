/// The command outbox worker (plan §5-§6): a single owner, claim → submit the
/// EXACT envelope → settle by error code.
///
/// Failure policy (§12 matrix):
///  * transport cut / timeout / 5xx → `settleRetry`, exponential backoff with
///    jitter; the next attempt re-sends the same `operationId` — the server
///    receipt guarantees no second effect even when the first commit landed;
///  * permanent codes → parked stop states with the saved reason, never a
///    blind retry loop (§5);
///  * process death mid-send → `recoverStalled` returns rows to pending on
///    the next start; the server-side receipt replay covers the "committed
///    before the answer arrived" window;
///  * offline / canSend false → claimed rows go straight back to pending
///    without burning a transport attempt.
library;

import 'dart:async';
import 'package:uuid/uuid.dart';

import 'command_contract.dart';
import 'command_outbox.dart';
import 'command_transport.dart';

enum Answer { approved, parked, retry, offlineSkip }

/// One bounded drain. Rounds are capped so an enqueue storm cannot turn into
/// an unbounded send loop; the next `onEnqueued`/connectivity trigger covers
/// the rest.
class SweepReport {
  const SweepReport({
    required this.sent,
    required this.approved,
    required this.parked,
    required this.retried,
    required this.skippedOffline,
  });

  static const SweepReport empty = SweepReport(
    sent: 0,
    approved: 0,
    parked: 0,
    retried: 0,
    skippedOffline: 0,
  );

  final int sent;
  final int approved;
  final int parked;
  final int retried;
  final int skippedOffline;

  SweepReport plus(SweepReport other) => SweepReport(
    sent: sent + other.sent,
    approved: approved + other.approved,
    parked: parked + other.parked,
    retried: retried + other.retried,
    skippedOffline: skippedOffline + other.skippedOffline,
  );

  @override
  String toString() =>
      'SweepReport($sent sent, $approved approved, $parked parked, '
      '$retried retried, $skippedOffline offline)';
}

class CommandWorker {
  CommandWorker({required this.outbox, required this.transport});

  final CommandOutbox outbox;
  final CommandTransport transport;

  /// "May this device send right now?" — bound by the service locator to the
  /// live session + connectivity; null means "always allowed" (tests).
  bool Function()? canSend;

  bool _running = false;
  bool _draining = false;
  bool _leaseLost = false;
  int _generation = 0;
  Timer? _retryTimer;
  final String _owner = const Uuid().v4();
  void Function(Object error)? onError;

  Future<void> _drainSafely() async {
    try {
      await runOnce();
    } on Object catch (error) {
      onError?.call(error);
    }
  }

  /// Single-flight owner (§5: "عامل واحد يمتلك طابور المؤسسة/الحساب"). Even
  /// if two owners ever raced, duplicate-effect prevention remains the
  /// server's receipt, not this flag.
  Future<SweepReport> runOnce({int maxRounds = 4}) async {
    if (_draining) return SweepReport.empty;
    if (canSend != null && !canSend!()) {
      final counts = await outbox.counts();
      return SweepReport(
        sent: 0,
        approved: 0,
        parked: 0,
        retried: 0,
        skippedOffline: counts.pending,
      );
    }
    _draining = true;
    final key = outbox.leaseKey;
    var acquired = false;
    Timer? heartbeat;
    final generation = _generation;
    try {
      acquired = await outbox.acquireLease(key, _owner);
      if (!acquired) return SweepReport.empty;
      _leaseLost = false;
      heartbeat = Timer.periodic(const Duration(seconds: 30), (_) async {
        try {
          if (!await outbox.renewLease(key, _owner)) _leaseLost = true;
        } on Object catch (error) {
          _leaseLost = true;
          onError?.call(error);
        }
      });
      await outbox.recoverStalled();
      var report = SweepReport.empty;
      for (var round = 0; round < maxRounds; round++) {
        if (_generation != generation ||
            _leaseLost ||
            (canSend != null && !canSend!())) {
          break;
        }
        final claimed = await outbox.claim();
        if (claimed.isEmpty) break;
        report = report.plus(await _sweep(claimed, generation));
      }
      return report;
    } finally {
      heartbeat?.cancel();
      try {
        if (acquired) await outbox.releaseLease(key, _owner);
      } finally {
        _draining = false;
      }
    }
  }

  void start() {
    if (_running) return;
    _running = true;
    unawaited(_drainSafely());
    _retryTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_running) unawaited(_drainSafely());
    });
  }

  void stop() {
    _running = false;
    _generation++;
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  /// Classify one transport answer into the store's lifecycle.
  Future<Answer> settle(CommandOutboxEntry entry, CommandResult result) async {
    if (result.operationId != entry.operationId ||
        (result.isApproved &&
            (result.entityId != entry.entityId ||
                result.committedVersion! < 1 ||
                result.changeSequence == null ||
                result.changeSequence! < 1 ||
                DateTime.tryParse(result.committedAt ?? '') == null))) {
      await outbox.settleRetry(
        entry.operationId,
        code: CommandErrorCodes.unavailable,
        message: 'إيصال غير مطابق للعملية المرسلة.',
      );
      return Answer.retry;
    }
    if (result.isApproved) {
      await outbox.settleApproved(entry.operationId, result);
      return Answer.approved;
    }
    final failure = result.failure;
    if (failure == null) {
      // Malformed reply: treat as transient rather than fabricating trust.
      await outbox.settleRetry(
        entry.operationId,
        code: CommandErrorCodes.internal,
        message: 'استجابة السيرفر لا تحمل نتيجة مفهومة.',
      );
      return Answer.retry;
    }
    switch (failure.code) {
      case CommandErrorCodes.unauthenticated:
        await outbox.settleTerminal(
          entry.operationId,
          state: OutboxState.authRequired,
          code: failure.code,
          message: failure.messageAr,
          result: result,
        );
        return Answer.parked;
      // A later version exists: the server record wins locally; the user
      // reviews, nothing is silently merged (§7 «التعديل المتعارض لا يمسح
      // تعديلًا آخر تلقائيًا»).
      case CommandErrorCodes.versionConflict:
      case CommandErrorCodes.deletedCannotModify:
        await outbox.settleTerminal(
          entry.operationId,
          state: OutboxState.needsReview,
          code: failure.code,
          message: failure.messageAr,
          result: result,
        );
        return Answer.parked;
    }
    if (commandPermanentErrors.contains(failure.code)) {
      await outbox.settleTerminal(
        entry.operationId,
        state: OutboxState.rejected,
        code: failure.code,
        message: failure.messageAr,
        result: result,
      );
      return Answer.parked;
    }
    await outbox.settleRetry(
      entry.operationId,
      code: failure.code,
      message: failure.messageAr,
    );
    return Answer.retry;
  }

  Future<Answer> submitOne(CommandOutboxEntry entry) async {
    CommandResult result;
    try {
      result = await transport.submit(entry.envelope());
    } on Object catch (e) {
      // A transport throw (socket, encoding, unclassified) is a network-shaped
      // failure, never evidence: settle it as retryable and keep the envelope
      // constant for the next attempt (§10: "لا يثبت فشل من إنترنت").
      await outbox.settleRetry(
        entry.operationId,
        code: CommandErrorCodes.unavailable,
        message: '$e',
      );
      return Answer.retry;
    }
    return settle(entry, result);
  }

  Future<SweepReport> _sweep(
    List<CommandOutboxEntry> entries,
    int generation,
  ) async {
    var approved = 0;
    var parked = 0;
    var retried = 0;
    var offline = 0;
    for (final entry in entries) {
      final scope = outbox.scopeProvider?.call();
      if (_generation != generation ||
          _leaseLost ||
          (outbox.scopeProvider != null &&
              (scope == null ||
                  !scope.owns(entry.organizationId, entry.uid) ||
                  scope.deviceId != entry.deviceId)) ||
          (canSend != null && !canSend!())) {
        await outbox.settleRetry(
          entry.operationId,
          code: CommandErrorCodes.offline,
          message: 'بانتظار الاتصال أو شروط الإرسال.',
        );
        offline++;
        continue;
      }
      final answer = await submitOne(entry);
      switch (answer) {
        case Answer.approved:
          approved++;
        case Answer.parked:
          parked++;
        case Answer.retry:
          retried++;
        case Answer.offlineSkip:
          offline++;
      }
    }
    return SweepReport(
      sent: entries.length - offline,
      approved: approved,
      parked: parked,
      retried: retried,
      skippedOffline: offline,
    );
  }
}
