/// Transport seam of the central command protocol (§6): a callable, trusted
/// backend (`submitCommand`) — Cloud Functions today; another backend only by
/// registering a different [CommandTransport] in the service locator.
library;

import 'dart:convert';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

import 'command_contract.dart';

abstract interface class CommandTransport {
  /// Sends EXACTLY the envelope's bytes. Throwing transport errors are
  /// classified into [CommandResult.retryable]/permanent failure by
  /// [CloudFunctionsCommandTransport].
  Future<CommandResult> submit(CommandEnvelope envelope);
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

/// Callable-Cloud-Functions implementation.
class CloudFunctionsCommandTransport implements CommandTransport {
  CloudFunctionsCommandTransport({
    this.region = 'us-central1',
    this.functionName = 'submitCommand',
    this.useRest = false,
    this.projectId,
    this.auth,
    this.client,
    this.tokenProvider,
  });

  /// Deployment region of the `submitCommand` callable.
  final String region;
  final String functionName;
  final bool useRest;
  final String? projectId;
  final FirebaseAuth? auth;
  final http.Client? client;
  final Future<String?> Function()? tokenProvider;

  Future<CommandResult> _submitRest(CommandEnvelope envelope) async {
    final id = projectId;
    if (id == null || !RegExp(r'^[a-z0-9-]+$').hasMatch(id)) {
      return CommandResult.retryable(
        envelope.operationId,
        CommandErrorCodes.unavailable,
        'خدمة الأوامر غير مهيأة.',
      );
    }
    final token = tokenProvider != null
        ? await tokenProvider!()
        : await (auth ?? FirebaseAuth.instance).currentUser?.getIdToken();
    if (token == null || token.isEmpty) {
      return CommandResult.retryable(
        envelope.operationId,
        CommandErrorCodes.unauthenticated,
        'سجل الدخول أولاً.',
      );
    }
    final transport = client ?? http.Client();
    try {
      final response = await transport
          .post(
            Uri.https('$region-$id.cloudfunctions.net', '/$functionName'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode({'data': envelope.toWire()}),
          )
          .timeout(const Duration(seconds: 60));
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      if (body is Map && body['error'] is Map) {
        final error = body['error'] as Map;
        return _fromFunctionsException(
          envelope,
          FirebaseFunctionsException(
            code: '${error['status'] ?? 'UNAVAILABLE'}'
                .toLowerCase()
                .replaceAll('_', '-'),
            message: '${error['message'] ?? ''}',
            details: error['details'],
          ),
        );
      }
      if (response.statusCode == 200 && body is Map && body['result'] is Map) {
        return CommandResult.fromJson(
          Map<String, dynamic>.from(body['result'] as Map),
        );
      }
      return CommandResult.retryable(
        envelope.operationId,
        CommandErrorCodes.unavailable,
        'تعذر تأكيد رد السيرفر.',
      );
    } finally {
      if (client == null) transport.close();
    }
  }

  @override
  Future<CommandResult> submit(CommandEnvelope envelope) async {
    try {
      if (useRest) return await _submitRest(envelope);
      final callable = FirebaseFunctions.instanceFor(region: region)
          .httpsCallable(
            functionName,
            options: HttpsCallableOptions(timeout: const Duration(seconds: 60)),
          );
      final response = await callable.call<Map<String, dynamic>>(
        envelope.toWire(),
      );
      return CommandResult.fromJson(response.data);
    } on FirebaseFunctionsException catch (e) {
      return _fromFunctionsException(envelope, e);
    } on Object catch (e) {
      // Any transport-level failure (socket, encoding) is retryable — the
      // worker re-sends the SAME operationId and the receipt dedupes.
      return CommandResult.retryable(
        envelope.operationId,
        CommandErrorCodes.unavailable,
        '$e',
      );
    }
  }

  /// Business-strict codes arrive as `data-loss` HttpsErrors carrying our
  /// code in `details` (the function side mirrors
  /// [commandPermanentErrors]); flat transport errors stay retryable.
  static const Set<String> _permanentHttpsCodes = {
    'permission-denied',
    'unauthenticated',
    'invalid-argument',
    'failed-precondition',
    'not-found',
  };

  CommandResult _fromFunctionsException(
    CommandEnvelope envelope,
    FirebaseFunctionsException e,
  ) {
    final details = e.details;
    final serverCode = details is Map
        ? '${details['code'] ?? ''}'
        : (details is String ? details : '');
    final message = details is Map
        ? details['messageAr'] as String? ?? e.message ?? ''
        : (e.message ?? '');
    if (_permanentHttpsCodes.contains(e.code)) {
      return CommandResult(
        operationId: envelope.operationId,
        status: CommandResult.statusRejected,
        entityId: envelope.entityId,
        failure: CommandFailure(
          code: serverCode.isEmpty ? _mapHttpsCode(e.code) : serverCode,
          messageAr: message,
        ),
      );
    }
    // Our supported stable code set (including VERSION_CONFLICT which maps
    // to https failed-precondition? No — version conflicts carry `details`,
    // so anything without one is transport-shaped).
    if (serverCode == CommandErrorCodes.unauthenticated ||
        serverCode == CommandErrorCodes.permissionDenied) {
      return CommandResult(
        operationId: envelope.operationId,
        status: CommandResult.statusRejected,
        entityId: envelope.entityId,
        failure: CommandFailure(code: serverCode, messageAr: message),
      );
    }
    return CommandResult.retryable(
      envelope.operationId,
      serverCode.isEmpty ? CommandErrorCodes.unavailable : serverCode,
      message,
    );
  }

  static String _mapHttpsCode(String code) => switch (code) {
    'unauthenticated' => CommandErrorCodes.unauthenticated,
    'permission-denied' => CommandErrorCodes.permissionDenied,
    'invalid-argument' => CommandErrorCodes.badPayload,
    'failed-precondition' => CommandErrorCodes.versionConflict,
    'not-found' => CommandErrorCodes.notFound,
    'resource-exhausted' => CommandErrorCodes.unavailable,
    'internal' || 'data-loss' => CommandErrorCodes.internal,
    _ => CommandErrorCodes.unavailable,
  };
}
