import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Byte-compatible port of core/utils.py  _b64_urlsafe_nopad_encode/decode,
/// _stream_xor_crypt, seal_text, unseal_text.
const String sealedTextPrefix = 'enc1:';

/// base64url without padding.
String b64UrlNoPad(List<int> bytes) =>
    base64UrlEncode(bytes).replaceAll('=', '');

Uint8List b64UrlNoPadDecode(String text) {
  var t = text.trim();
  final pad = (4 - t.length % 4) % 4;
  t += '=' * pad;
  return base64Url.decode(t);
}

Uint8List secureRandomBytes(int length) {
  final random = Random.secure();
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    out[i] = random.nextInt(256);
  }
  return out;
}

Uint8List sha256Bytes(List<int> data) => Uint8List.fromList(sha256.convert(data).bytes);

List<int> _hmacBytes(List<int> key, List<int> message) =>
    Hmac(sha256, key).convert(message).bytes;

/// HMAC keystream XOR (counter mode, 32-byte blocks) — port of _stream_xor_crypt.
Uint8List streamXorCrypt(List<int> data, List<int> key, List<int> nonce) {
  final out = Uint8List(data.length);
  var counter = 0;
  var offset = 0;
  while (offset < data.length) {
    final counterBytes = Uint8List(4);
    ByteData.view(counterBytes.buffer).setUint32(0, counter);
    final blockInput = <int>[...nonce, ...counterBytes];
    final block = _hmacBytes(key, blockInput);
    final take = block.length > data.length - offset
        ? data.length - offset
        : block.length;
    for (var i = 0; i < take; i++) {
      out[offset + i] = data[offset + i] ^ block[i];
    }
    offset += take;
    counter++;
  }
  return out;
}

bool _constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// seal_text port: enc1:base64urlNoPad(nonce[12]+tag[16]+cipher).
String sealText(String value, List<int> key) {
  final plain = utf8.encode(value);
  if (plain.isEmpty) return '';
  final nonce = secureRandomBytes(12);
  final cipher = streamXorCrypt(plain, key, nonce);
  final tagBytes = _hmacBytes(key, <int>[...nonce, ...cipher]).sublist(0, 16);
  final token = b64UrlNoPad(<int>[...nonce, ...tagBytes, ...cipher]);
  return '$sealedTextPrefix$token';
}

/// unseal_text port. Returns (plaintext, ok).
(String, bool) unsealText(String value, List<int> key) {
  final token = value.trim();
  if (token.isEmpty) return ('', true);
  if (!token.startsWith(sealedTextPrefix)) return (token, true);
  final encoded = token.substring(sealedTextPrefix.length);
  List<int> payload;
  try {
    payload = b64UrlNoPadDecode(encoded);
  } catch (_) {
    return ('', false);
  }
  if (payload.length < 28) return ('', false);
  final nonce = payload.sublist(0, 12);
  final tag = payload.sublist(12, 28);
  final cipher = payload.sublist(28);
  final expected = _hmacBytes(key, <int>[...nonce, ...cipher]).sublist(0, 16);
  if (!_constantTimeEquals(tag, expected)) return ('', false);
  final plain = streamXorCrypt(cipher, key, nonce);
  try {
    return (utf8.decode(plain), true);
  } catch (_) {
    return ('', false);
  }
}