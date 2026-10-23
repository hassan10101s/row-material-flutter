import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'seal_codec.dart';

/// Raised when the on-disk local secret exists but cannot be used.
///
/// A corrupt/unreadable secret is a hard failure, never a silent reset: the
/// file is both the password-KDF pepper and the QR-seal key, so regenerating
/// or deriving from it would either let an attacker who can write the file
/// choose a known key or invalidate every previously sealed value and every
/// password hash.
class LocalSecretException implements Exception {
  LocalSecretException(this.message);

  final String message;

  @override
  String toString() => 'LocalSecretException: $message';
}

/// Port of core/utils.py load_or_create_local_secret.
///
/// Security notes (desktop best-practice):
/// - This pepper/QR-seal key is a *local* secret, not a user credential. On
///   Windows (MSIX + plain EXE) it lives at `%APPDATA%\MaterialLab\.secret`.
///   OS-level ACLs of `%APPDATA%` already restrict it to the current user;
///   DPAPI-encryption would require an async plugin at every sync-codec call,
///   so the file stays plaintext by design (same as the Python port).
/// - Writes are atomic (temp + rename) so a crash/AV lock never leaves a
///   half-written secret.
/// - A corrupt/unreadable/too-short file fails **closed** with a
///   [LocalSecretException]. It is never replaced by a derived
///   (`sha256(fileBytes)`) or a fresh key, because either would silently
///   re-key QR seals and invalidate every stored password hash.
class LocalSecret {
  LocalSecret(this._directory);

  final String _directory;
  static const String _fileName = '.secret';

  // Process-lifetime cache of the secret file contents. The secret is
  // immutable once created (re-keying would invalidate every stored password
  // hash and QR seal), so after the first load the bytes are served from
  // memory instead of re-reading the file on every seal/hash call — the
  // report flow used to read it several times per generated PDF.
  Uint8List? _cachedBytes;
  String? _cachedText;
  String? _cachedPath;

  Future<String> get path async {
    final cached = _cachedPath;
    if (cached != null) return cached;
    await Directory(_directory).create(recursive: true);
    return _cachedPath = p.join(_directory, _fileName);
  }

  /// Reads the local secret, creating a fresh 32-byte one on first run.
  ///
  /// Throws [LocalSecretException] if a secret exists but cannot be parsed,
  /// rather than silently re-keying (see the class docs).
  Future<Uint8List> load() async {
    final cached = _cachedBytes;
    if (cached != null) return cached;
    final filePath = await path;
    final file = File(filePath);
    if (await file.exists()) {
      final (bytes, rawText) = await _readExisting(file);
      _cachedBytes = bytes;
      _cachedText = rawText;
      return bytes;
    }
    final bytes = await _createNew(file, filePath);
    _cachedBytes = bytes;
    _cachedText = b64UrlNoPad(bytes);
    return bytes;
  }

  Future<(Uint8List, String)> _readExisting(File file) async {
    String raw;
    try {
      raw = (await file.readAsString()).trim();
    } catch (_) {
      throw LocalSecretException(
        'the local secret file could not be read: ${file.path}',
      );
    }
    if (raw.isEmpty) {
      throw LocalSecretException(
        'the local secret file is empty: ${file.path}',
      );
    }
    Uint8List decoded;
    try {
      decoded = b64UrlNoPadDecode(raw);
    } catch (_) {
      throw LocalSecretException(
        'the local secret file is not valid base64url: ${file.path}',
      );
    }
    if (decoded.length < 16) {
      throw LocalSecretException(
        'the local secret file is too short (${decoded.length} bytes, '
        'minimum 16): ${file.path}',
      );
    }
    return (decoded, raw);
  }

  Future<Uint8List> _createNew(File file, String filePath) async {
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
  ///
  /// Unlike [load] this returns whatever the file contains — even text that
  /// is not valid base64url — and null when the file is missing; it must
  /// never create the secret as a side effect.
  Future<String?> readSecretText() async {
    final cached = _cachedText;
    if (cached != null) return cached;
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