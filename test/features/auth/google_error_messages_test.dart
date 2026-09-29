import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:material_lab/core/auth/session_store.dart';
import 'package:material_lab/core/constants/app_strings.dart';
import 'package:material_lab/core/database/database_helper.dart';
import 'package:material_lab/core/firebase/firebase_bootstrap.dart';
import 'package:material_lab/core/firebase/firebase_options.dart';
import 'package:material_lab/core/network/connectivity_service.dart';
import 'package:material_lab/core/sync/remote/auth_remote_data_source.dart';
import 'package:material_lab/core/sync/remote/remote_data_source.dart';
import 'package:material_lab/core/sync/sync_metadata.dart';
import 'package:material_lab/features/auth/data/auth_repository.dart';
import 'package:material_lab/features/auth/data/offline_first_auth_repository.dart';

class _MockDatabaseHelper extends Mock implements DatabaseHelper {}

class _MockSessionStore extends Mock implements SessionStore {}

class _MockConnectivity extends Mock implements ConnectivityService {}

class _MockSyncMetadata extends Mock implements SyncMetadata {}

class _MockAuthRemote extends Mock implements AuthRemoteDataSource {}

/// Plan §8.1 regression: a Google sign-in failure must surface a clear,
/// localized message to the user — never the raw plugin/technical text and
/// never the exception itself.
void main() {
  late _MockAuthRemote remote;
  late _MockDatabaseHelper db;
  late _MockSessionStore store;
  late _MockConnectivity connectivity;
  late _MockSyncMetadata metadata;

  setUp(() {
    AppText.useLanguage('ar');
    remote = _MockAuthRemote();
    db = _MockDatabaseHelper();
    store = _MockSessionStore();
    connectivity = _MockConnectivity();
    metadata = _MockSyncMetadata();
    when(() => remote.isConfigured).thenReturn(true);
  });

  OfflineFirstAuthRepository build() => OfflineFirstAuthRepository(
        remote: remote,
        sessionStore: store,
        dbHelper: db,
        connectivity: connectivity,
        metadata: metadata,
        bootstrap: const FirebaseBootstrapResult(
          status: FirebaseStatus.ready,
          config: FirebaseConfig(
            apiKey: 'k',
            appId: 'a',
            messagingSenderId: 'm',
            projectId: 'p',
            authDomain: 'd',
          ),
        ),
      );

  void expectFriendly(AuthFailure failure, String code, String rawMessage,
      {String? includes}) {
    expect(failure.code, code);
    expect(failure.message, isNotEmpty);
    expect(failure.message, isNot(contains(rawMessage)),
        reason: 'the raw technical detail must never reach the user');
    expect(failure.message, isNot(contains('Exception')),
        reason: 'the exception itself must never be mentioned');
    if (includes != null) expect(failure.message, contains(includes));
  }

  test('a cancelled Google sign-in shows a friendly cancellation message',
      () async {
    when(remote.signInWithGoogle)
        .thenThrow(const GoogleSignInException('user cancelled the sign-in flow'));

    try {
      await build().signInWithGoogle();
      fail('expected an AuthFailure');
    } on AuthFailure catch (e) {
      expectFriendly(e, 'cancelled', 'user cancelled the sign-in flow',
          includes: 'إلغاء');
    }
  });

  test('a missing desktop client id shows a configuration message, never the '
      'raw text', () async {
    when(remote.signInWithGoogle).thenThrow(const GoogleSignInException(
        'The Google client id is invalid, make sure it is a GOOGLE_DESKTOP_CLIENT_ID '
        'created in the Firebase console and that it has been approved'));

    try {
      await build().signInWithGoogle();
      fail('expected an AuthFailure');
    } on AuthFailure catch (e) {
      expectFriendly(e, 'missing_config', 'GOOGLE_DESKTOP_CLIENT_ID',
          includes: 'تسجيل Google');
    }
  });

  test('a rejected request shows a denial message without the raw text',
      () async {
    when(remote.signInWithGoogle).thenThrow(
        const GoogleSignInException('the token was rejected by the server'));

    try {
      await build().signInWithGoogle();
      fail('expected an AuthFailure');
    } on AuthFailure catch (e) {
      expectFriendly(e, 'access_denied', 'the token was rejected by the server',
          includes: 'لم يُسمح');
    }
  });

  test('an unknown exception becomes a generic friendly failure', () async {
    when(remote.signInWithGoogle)
        .thenThrow(Exception('boom: 503 backend unavailable'));

    try {
      await build().signInWithGoogle();
      fail('expected an AuthFailure');
    } on AuthFailure catch (e) {
      expectFriendly(e, 'auth_failed', 'boom: 503 backend unavailable',
          includes: 'حاول مرة أخرى');
    }
  });

  test('the message is localized to English when the app language is English',
      () async {
    AppText.useLanguage('en');
    when(remote.signInWithGoogle)
        .thenThrow(const GoogleSignInException('sign-in cancelled'));

    try {
      await build().signInWithGoogle();
      fail('expected an AuthFailure');
    } on AuthFailure catch (e) {
      expectFriendly(e, 'cancelled', 'sign-in cancelled',
          includes: 'Sign-in was cancelled');
    }

    AppText.useLanguage('ar');
  });
}