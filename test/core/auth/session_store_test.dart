import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/auth/session_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('sign-out marker survives cache clearing until a new sign-in', () async {
    final store = SessionStore();

    await store.markSignedOut();
    await store.clear();

    expect(await store.isSignOutPending(), isTrue);

    await store.allowSignIn();

    expect(await store.isSignOutPending(), isFalse);
  });
}
