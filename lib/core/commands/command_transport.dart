/// Transport seam of the central command protocol (§6): a trusted backend —
/// the Firestore direct transaction client (`FirestoreDirectCommandTransport`)
/// is registered in the service locator; another backend only by registering
/// a different [CommandTransport] there.
library;

import 'command_contract.dart';

abstract interface class CommandTransport {
  /// Sends EXACTLY the envelope's bytes. Throwing transport errors are
  /// classified into [CommandResult.retryable]/permanent failure by the
  /// registered implementation.
  Future<CommandResult> submit(CommandEnvelope envelope);
}

/// Read-only recovery of a previously issued request. Returning null proves
/// only that no receipt was found at that moment; it never triggers a resend.
abstract interface class CommandReceiptReader {
  Future<CommandResult?> lookupReceipt(CommandEnvelope envelope);
}

/// Degraded-mode transport (Firebase not ready): every send becomes a
/// retryable UNAVAILABLE so drafts keep their state and never marked approved.
class UnconfiguredCommandTransport implements CommandTransport {
  const UnconfiguredCommandTransport();

  @override
  Future<CommandResult> submit(CommandEnvelope envelope) => Future.value(
    CommandResult.retryable(
      envelope.operationId,
      CommandErrorCodes.unavailable,
      'خدمة الأوامر غير جاهزة على هذا الجهاز.',
    ),
  );
}
