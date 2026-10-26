import 'dart:convert';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

class CentralSyncGap implements Exception {
  const CentralSyncGap();
}

class CentralSyncTransport {
  CentralSyncTransport({
    this.region = 'us-central1',
    this.functionName = 'readCentralSync',
    this.useRest = false,
    this.projectId,
    this.auth,
    this.client,
    this.tokenProvider,
  });

  final String region;
  final String functionName;
  final bool useRest;
  final String? projectId;
  final FirebaseAuth? auth;
  final http.Client? client;
  final Future<String?> Function()? tokenProvider;

  Future<Map<String, dynamic>> call(Map<String, Object?> data) async {
    if (!useRest) {
      try {
        final response = await FirebaseFunctions.instanceFor(region: region)
            .httpsCallable(
              functionName,
              options: HttpsCallableOptions(
                timeout: const Duration(seconds: 60),
              ),
            )
            .call<Map<String, dynamic>>(data);
        return response.data;
      } on FirebaseFunctionsException catch (error) {
        final details = error.details;
        if (details is Map && details['code'] == 'EVENT_GAP') {
          throw const CentralSyncGap();
        }
        rethrow;
      }
    }
    final project = projectId;
    if (project == null || !RegExp(r'^[a-z0-9-]+$').hasMatch(project)) {
      throw StateError('Central sync is not configured.');
    }
    final token = tokenProvider != null
        ? await tokenProvider!()
        : await (auth ?? FirebaseAuth.instance).currentUser?.getIdToken();
    if (token == null || token.isEmpty) {
      throw StateError('Sign in is required.');
    }
    final transport = client ?? http.Client();
    try {
      final response = await transport
          .post(
            Uri.https('$region-$project.cloudfunctions.net', '/$functionName'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode({'data': data}),
          )
          .timeout(const Duration(seconds: 60));
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (response.statusCode != 200 ||
          decoded is! Map ||
          decoded['result'] is! Map) {
        final error = decoded is Map ? decoded['error'] : null;
        final details = error is Map ? error['details'] : null;
        if (details is Map && details['code'] == 'EVENT_GAP') {
          throw const CentralSyncGap();
        }
        throw StateError(
          error is Map
              ? '${error['message'] ?? 'Central sync failed.'}'
              : 'Central sync failed.',
        );
      }
      return Map<String, dynamic>.from(decoded['result'] as Map);
    } finally {
      if (client == null) transport.close();
    }
  }
}
