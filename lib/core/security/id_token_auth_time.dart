import 'dart:convert';

/// Reads the `auth_time` claim (seconds since epoch) straight from a Firebase
/// ID token. The bundled Windows firebase_auth plugin fills only the token
/// string, so `IdTokenResult.authTime` stays null there; the secure-visibility
/// Rules compare the raw claim (`request.auth.token.auth_time`), so decoding
/// it from the token itself yields the value the Rules expect on every
/// platform.
int? idTokenAuthTime(String? token) {
  if (token == null) return null;
  try {
    final parts = token.split('.');
    if (parts.length < 2) return null;
    var payload = parts[1];
    final remainder = payload.length % 4;
    if (remainder == 2) {
      payload = '$payload==';
    } else if (remainder == 3) {
      payload = '$payload=';
    }
    final decoded = jsonDecode(utf8.decode(base64Url.decode(payload)));
    if (decoded is! Map<String, dynamic>) return null;
    final time = decoded['auth_time'];
    return time is num ? time.toInt() : null;
  } on Object {
    return null;
  }
}
