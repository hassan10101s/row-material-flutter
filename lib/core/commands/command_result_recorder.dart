import 'command_contract.dart';
import 'command_outbox.dart';

enum Answer { approved, parked, retry, offlineSkip }

/// Records a definitive response or uncertainty; never sends or schedules a request.
class CommandResultRecorder {
  const CommandResultRecorder(this.outbox);
  final CommandOutbox outbox;
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
}
