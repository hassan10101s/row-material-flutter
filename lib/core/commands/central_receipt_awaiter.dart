import 'dart:async';

import '../utils/app_exceptions.dart';
import 'command_outbox.dart';

/// Bounds the UI wait, not the lifetime of the durable server request.
/// A timed-out drain may still commit; only its original receipt settles it.
class CentralReceiptAwaiter {
  CentralReceiptAwaiter({
    required this.outbox,
    required this.drain,
    required this.synchronize,
    required this.isOnline,
    this.isCurrent,
    this.budget = const Duration(seconds: 12),
  });
  final CommandOutbox outbox;
  final Future<void> Function() drain;
  final Future<int> Function(int sequence) synchronize;
  final bool Function() isOnline;
  final bool Function(CommandOutboxEntry entry)? isCurrent;
  final Duration budget;

  Future<bool> wait(CommandOutboxEntry entry) async {
    final elapsed = Stopwatch()..start();
    Duration remaining() => budget - elapsed.elapsed;
    try {
      while (remaining() > Duration.zero) {
        if (!isOnline() || (isCurrent != null && !isCurrent!(entry))) {
          return false;
        }
        await drain().timeout(remaining());
        final settled = await outbox
            .getByOperationId(entry.operationId)
            .timeout(remaining());
        if (settled == null || (isCurrent != null && !isCurrent!(entry))) {
          return false;
        }
        switch (settled.state) {
          case OutboxState.approved:
            final sequence = settled.result?.changeSequence;
            if (sequence == null) return false;
            try {
              return await synchronize(sequence).timeout(remaining()) >=
                  sequence;
            } on Object {
              return false;
            }
          case OutboxState.rejected:
          case OutboxState.needsReview:
            throw ValidationError(
              settled.lastError ?? 'رفض السيرفر طلب الاعتماد؛ راجع المسودات.',
            );
          case OutboxState.authRequired:
            throw AuthorizationError(
              settled.lastError ?? 'انتهت الجلسة؛ سجّل الدخول ثم أعد المحاولة.',
            );
          case OutboxState.archived:
            return false;
          default:
            if (settled.state == OutboxState.pending && settled.attempts > 0) {
              return false;
            }
            if (remaining() <= Duration.zero) return false;
            await Future<void>.delayed(
              const Duration(milliseconds: 250),
            ).timeout(remaining());
        }
      }
    } on TimeoutException {
      // Never settle/requeue here: the same explicitly sent request remains in flight.
      return false;
    } finally {
      elapsed.stop();
    }
    return false;
  }
}
