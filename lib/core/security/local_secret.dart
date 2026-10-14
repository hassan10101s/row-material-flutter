import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'seal_codec.dart';

/// Port of core/utils.py load_or_create_local_secret.
///
/// Security notes (desktop best-practice):
/// - This pepper/QR-seal key is a *local* secret, not a user credential. On
///   Windows (MSIX + plain EXE) it lives at `%APPDATA%\MaterialLab\.secret`.
///   OS-level ACLs of `%APPDATA%` already restrict it to the current user;
///   DPAPI-encryption would require an async plugin at every sync-codec call,
///   so the file stays plaintext by design (same as the Python port).
/// - Writes are atomic (temp + rename) so a crash/AV lock never leaves a
///   half-written secret. A corrupt file falls back to sha256-of-bytes, then
///   to a fresh 32-byte secret — matching the Python recreate behaviour.
class LocalSecret {
  LocalSecret(this._directory);

  final String _directory;
  static const String _fileName = '.secret';

  Future<String> get path async {
    await Directory(_directory).create(recursive: true);
    return p.join(_directory, _fileName);
  }

  Future<Uint8List> load() async {
    final filePath = await path;
    final file = File(filePath);
    if (await file.exists()) {
      try {
        final raw = (await file.readAsString()).trim();
        if (raw.isNotEmpty) {
          final decoded = b64UrlNoPadDecode(raw);
          if (decoded.length >= 16) return decoded;
        }
      } catch (_) {}
      try {
        final rawBytes = await file.readAsBytes();
        if (rawBytes.isNotEmpty) return sha256Bytes(rawBytes);
      } catch (_) {}
    }
    final secret = secureRandomBytes(32);
    // Atomic write: temp + rename so a killed process never leaves a truncated
    // `.secret` (which would silently re-key every QR seal on next boot).
    final tmp = File('$filePath.tmp-${DateTime.now().microsecondsSinceEpoch}');
    await tmp.writeAsString(b64UrlNoPad(secret), flush: true);
    try {
      await tmp.rename(filePath);
    } catch (_) {
      // Cross-volume or locked (AV): copy fallback, best effort.
      try {
        await tmp.copy(filePath);
        await tmp.delete();
      } catch (_) {
        await file.writeAsString(b64UrlNoPad(secret), flush: true);
      }
    }
    return secret;
  }

  /// Read the stored secret as utf8 text (used for display pepper checks).
  Future<String?> readSecretText() async {
    final filePath = await path;
    final file = File(filePath);
    if (!await file.exists()) return null;
    try {
      return (await file.readAsString()).trim();
    } catch (_) {
      return null;
    }
  }
}

/// JSON bytes helpers shared by security layer.
String utf8DecodeSafe(List<int> bytes) {
  try {
    return utf8.decode(bytes);
  } catch (_) {
    return '';
  }
}