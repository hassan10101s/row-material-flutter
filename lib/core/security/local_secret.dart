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
/// - Creation stages and flushes a temporary file, then exclusively claims
///   the final path before publishing it. A concurrent creator must read the
///   winner's key. A crash between claim and publication fails closed on the
///   empty reservation; an existing key is never overwritten or regenerated.
/// - A corrupt/unreadable/too-short file fails **closed** with a
///   [LocalSecretException]. It is never replaced by a derived
///   (`sha256(fileBytes)`) or a fresh key, because either would silently
///   re-key QR seals and invalidate every stored password hash.
class LocalSecret {
  LocalSecret(this._directory);

  final String _directory;
  static const String _fileName = '.secret';
  static final Map<String, Future<(Uint8List, String)>> _loads = {};

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
    final directory = await Directory(_directory).create(recursive: true);
    return _cachedPath = p.join(
      await directory.resolveSymbolicLinks(),
      _fileName,
    );
  }

  /// Reads the local secret, creating a fresh 32-byte one on first run.
  ///
  /// Throws [LocalSecretException] if a secret exists but cannot be parsed,
  /// rather than silently re-keying (see the class docs).
  Future<Uint8List> load() async {
    final cached = _cachedBytes;
    if (cached != null) return cached;
    final filePath = await path;
    // Coalesce all instances in this isolate, not just calls on this object.
    // File.create(exclusive: true) below arbitrates other isolates/processes.
    final pending = _loads.putIfAbsent(filePath, () => _loadFromDisk(filePath));
    try {
      final (bytes, rawText) = await pending;
      _cachedBytes = bytes;
      _cachedText = rawText;
      return bytes;
    } finally {
      if (identical(_loads[filePath], pending)) _loads.remove(filePath);
    }
  }

  Future<(Uint8List, String)> _loadFromDisk(String filePath) async {
    final file = File(filePath);
    return await file.exists()
        ? _readExisting(file)
        : _createNew(file, filePath);
  }

  Future<(Uint8List, String)> _readExisting(File file) async {
    var raw = '';
    // Windows may briefly refuse a read while another isolate atomically
    // publishes the winning key. Retry reads only; never replace an existing
    // reservation, regenerate a key or derive one from corrupt bytes.
    for (var attempt = 0; attempt <= 50; attempt++) {
      try {
        raw = (await file.readAsString()).trim();
        if (raw.isNotEmpty) break;
      } on FileSystemException {
        if (attempt == 50) {
          throw LocalSecretException(
            'the local secret file could not be read: ${file.path}',
          );
        }
      } on Object {
        throw LocalSecretException(
          'the local secret file could not be read: ${file.path}',
        );
      }
      if (attempt < 50) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
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

  Future<(Uint8List, String)> _createNew(File file, String filePath) async {
    final secret = secureRandomBytes(32);
    final text = b64UrlNoPad(secret);
    final tmp = File(
      '$filePath.tmp-$pid-${b64UrlNoPad(secureRandomBytes(12))}',
    );
    await tmp.create(exclusive: true);
    try {
      await tmp.writeAsString(text, flush: true);
      try {
        // Keep claim/publication contiguous. Unlike rename alone, exclusive
        // creation cannot replace another creator's already-published key.
        file.createSync(exclusive: true);
      } on FileSystemException {
        if (!await file.exists()) rethrow;
        return await _readExisting(file);
      }
      try {
        tmp.renameSync(filePath);
      } on FileSystemException {
        throw LocalSecretException(
          'the local secret could not be published: $filePath',
        );
      }
      return (secret, text);
    } finally {
      try {
        if (await tmp.exists()) await tmp.delete();
      } on FileSystemException {
        // An AV-held temporary file must not replace the original error/key.
      }
    }
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
