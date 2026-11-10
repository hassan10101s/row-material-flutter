import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:material_lab/core/security/id_token_auth_time.dart';

String _jwt(Map<String, dynamic> claims) {
  final header = base64Url.encode(utf8.encode('{"alg":"RS256"}'));
  final payload = base64Url.encode(utf8.encode(jsonEncode(claims)));
  return '$header.$payload.ignored-signature';
}

void main() {
  test('reads auth_time from a padded and unpadded payload', () {
    expect(idTokenAuthTime(_jwt({'auth_time': 1717030000})), 1717030000);
    // Varying payload lengths hit all padding branches.
    expect(idTokenAuthTime(_jwt({'a': 1, 'auth_time': 1717030001})), 1717030001);
    expect(
      idTokenAuthTime(_jwt({'aa': 22, 'bb': 1, 'auth_time': 1717030002})),
      1717030002,
    );
  });

  test('returns null for missing, malformed or absent claims', () {
    expect(idTokenAuthTime(_jwt({'iat': 100})), isNull);
    expect(idTokenAuthTime(_jwt({'auth_time': 'not-a-number'})), isNull);
    expect(idTokenAuthTime('not-a-jwt'), isNull);
    expect(idTokenAuthTime('a.b'), isNull);
    expect(
      idTokenAuthTime(
        'a.${base64Url.encode(utf8.encode('\xff\xfe')).replaceAll('=', '')}.c',
      ),
      isNull,
    );
    expect(idTokenAuthTime(null), isNull);
  });
}
