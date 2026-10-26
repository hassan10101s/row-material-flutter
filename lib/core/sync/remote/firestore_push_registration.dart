import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crypto/crypto.dart';

import 'push_registration.dart';

/// Device tokens are private infrastructure, separate from domain sync rows.
class FirestorePushRegistration implements PushRegistration {
  String _id(String uid, String token) =>
      '${uid}_${sha256.convert(utf8.encode(token))}';
  DocumentReference<Map<String, dynamic>> _ref(
    String org,
    String uid,
    String token,
  ) => FirebaseFirestore.instance
      .collection('organizations')
      .doc(org)
      .collection('pushTokens')
      .doc(_id(uid, token));

  @override
  Future<void> register({
    required String organizationId,
    required String uid,
    required String deviceId,
    required String token,
  }) => _ref(organizationId, uid, token).set({
    'uid': uid,
    'deviceId': deviceId,
    'token': token,
    'platform': Platform.operatingSystem,
    'updatedAt': DateTime.now().toUtc().toIso8601String(),
  });

  @override
  Future<void> unregister({
    required String organizationId,
    required String uid,
    required String token,
  }) => _ref(organizationId, uid, token).delete();
}
