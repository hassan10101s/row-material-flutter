import 'dart:convert';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/key_derivators/api.dart';
import 'package:pointycastle/key_derivators/pbkdf2.dart';
import 'package:pointycastle/macs/hmac.dart';

import '../domain/rules.dart';

/// Port of build_password_hash / verify_password from core/utils.py.
/// PBKDF2-HMAC-SHA256 runs inside its own isolate to avoid jank (780k rounds).
String _toHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

List<int> _hexToBytes(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

/// Hex decoder that returns null instead of throwing on malformed input.
///
/// `verify` parses the salt out of an attacker/tamper-controllable stored
/// hash, so it must fail closed (deny the login) rather than surfacing a
/// `FormatException` from the login path.
List<int>? _tryHexToBytes(String hex) {
  if (hex.isEmpty || hex.length.isOdd) return null;
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    final byte = int.tryParse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    if (byte == null) return null;
    out[i] = byte;
  }
  return out;
}

/// Upper bound on the KDF rounds read from a stored hash. A legitimately
/// issued hash uses at most [developerPasswordHashRounds]; anything beyond
/// this is treated as malformed so a tampered row cannot wedge the login
/// path with an unbounded PBKDF2 run (KDF DoS).
const int _maxStoredHashRounds = developerPasswordHashRounds * 4;

String _randomSaltHex() {
  final rand = math.Random.secure();
  return List.generate(
    16,
    (_) => rand.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

String _pbkdf2DigestHex(List<int> passwordBytes, List<int> salt, int rounds) {
  final derivator = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
    ..init(Pbkdf2Parameters(Uint8List.fromList(salt), rounds, 32));
  final derived = derivator.process(Uint8List.fromList(passwordBytes));
  return _toHex(derived);
}

String _hashResult(
  List<int> material,
  List<int> salt,
  int rounds,
  bool isDeveloper,
) {
  final digest = _pbkdf2DigestHex(material, salt, rounds);
  final algo = isDeveloper ? developerPasswordHashAlgo : passwordHashAlgoV2;
  final saltHex = _toHex(salt);
  return '$algo\$$rounds\$$saltHex\$$digest';
}

class _HashRequest {
  final List<int> material;
  final List<int> salt;
  final int rounds;
  final bool isDeveloper;
  final String verifyDigest;
  const _HashRequest({
    required this.material,
    required this.salt,
    required this.rounds,
    required this.isDeveloper,
    required this.verifyDigest,
  });
}

class _HashOutcome {
  final String hash;
  final bool verified;
  const _HashOutcome(this.hash, this.verified);
}

Future<_HashOutcome> _runHash(_HashRequest req) {
  return Isolate.run(() {
    final digest = _pbkdf2DigestHex(req.material, req.salt, req.rounds);
    if (req.verifyDigest.isNotEmpty) {
      return _HashOutcome('', _constantTextEquals(digest, req.verifyDigest));
    }
    return _HashOutcome(
      _hashResult(req.material, req.salt, req.rounds, req.isDeveloper),
      true,
    );
  });
}

bool _constantTextEquals(String a, String b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return diff == 0;
}

class PasswordHasher {
  final String pepper;

  PasswordHasher({this.pepper = ''});

  /// Build a v2 password hash. [isDeveloper] uses the doubled-round dev algo.
  Future<String> buildHash(String password, {bool isDeveloper = false}) async {
    final material = utf8.encode(password + pepper);
    final salt = _hexToBytes(_randomSaltHex());
    final rounds = isDeveloper
        ? developerPasswordHashRounds
        : passwordHashRounds;
    final outcome = await _runHash(
      _HashRequest(
        material: material,
        salt: salt,
        rounds: rounds,
        isDeveloper: isDeveloper,
        verifyDigest: '',
      ),
    );
    return outcome.hash;
  }

  Future<String> buildDeveloperHash(String password) =>
      buildHash(password, isDeveloper: true);

  Future<bool> verify(String password, String storedHash) async {
    if (storedHash.trim().isEmpty) return false;
    final parts = storedHash.split('\$');
    // Only the four-field `algo$rounds$salt$digest` shape is accepted. A bare
    // 64-hex SHA-256 digest is deliberately NOT accepted: it carries no salt
    // and no pepper, so verifying it would let a leaked database be cracked
    // with a precomputed table. Such rows are treated as unverifiable and, per
    // `needsUpgrade`, must be re-hashed on the next successful login.
    if (parts.length != 4) return false;
    final algorithm = parts[0];
    if (algorithm != passwordHashAlgoV2 &&
        algorithm != developerPasswordHashAlgo &&
        algorithm != passwordHashAlgoLegacy) {
      return false;
    }
    final rounds = int.tryParse(parts[1]);
    if (rounds == null || rounds <= 0 || rounds > _maxStoredHashRounds) {
      return false;
    }
    // Fail closed on a malformed salt: return false, never throw out of the
    // login path.
    final salt = _tryHexToBytes(parts[2]);
    if (salt == null) return false;
    final digest = parts[3];

    final material = algorithm == passwordHashAlgoLegacy
        ? utf8.encode(password)
        : utf8.encode(password + pepper);
    final outcome = await _runHash(
      _HashRequest(
        material: material,
        salt: salt,
        rounds: rounds,
        isDeveloper: algorithm == developerPasswordHashAlgo,
        verifyDigest: digest,
      ),
    );
    return outcome.verified;
  }

  /// Whether the stored hash should be upgraded after a successful login.
  bool needsUpgrade(String storedHash) {
    final parts = storedHash.split('\$');
    if (parts.length != 4) return storedHash.isNotEmpty;
    final algorithm = parts[0];
    final rounds = int.tryParse(parts[1]) ?? 0;
    if (algorithm == developerPasswordHashAlgo) {
      return rounds < developerPasswordHashRounds;
    }
    if (algorithm != passwordHashAlgoV2) return true;
    return rounds < passwordHashRounds;
  }
}
