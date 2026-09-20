import 'dart:convert';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
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

String _randomSaltHex() {
  final rand = math.Random.secure();
  return List.generate(16, (_) => rand.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

String _pbkdf2DigestHex(List<int> passwordBytes, List<int> salt, int rounds) {
  final derivator = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
    ..init(Pbkdf2Parameters(Uint8List.fromList(salt), rounds, 32));
  final derived = derivator.process(Uint8List.fromList(passwordBytes));
  return _toHex(derived);
}

String _hashResult(
    List<int> material, List<int> salt, int rounds, bool isDeveloper) {
  final digest = _pbkdf2DigestHex(material, salt, rounds);
  final algo = isDeveloper
      ? developerPasswordHashAlgo
      : passwordHashAlgoV2;
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
    final rounds = isDeveloper ? developerPasswordHashRounds : passwordHashRounds;
    final outcome = await _runHash(_HashRequest(
      material: material,
      salt: salt,
      rounds: rounds,
      isDeveloper: isDeveloper,
      verifyDigest: '',
    ));
    return outcome.hash;
  }

  Future<String> buildDeveloperHash(String password) =>
      buildHash(password, isDeveloper: true);

  Future<bool> verify(String password, String storedHash) async {
    if (storedHash.trim().isEmpty) return false;
    final parts = storedHash.split('\$');
    if (parts.length == 4) {
      final algorithm = parts[0];
      final rounds = int.tryParse(parts[1]);
      final salt = _hexToBytes(parts[2]);
      final digest = parts[3];
      if (rounds == null) return false;

      List<int> material;
      if (algorithm == passwordHashAlgoV2 ||
          algorithm == developerPasswordHashAlgo) {
        material = utf8.encode(password + pepper);
      } else if (algorithm == passwordHashAlgoLegacy) {
        material = utf8.encode(password);
      } else {
        return false;
      }
      final outcome = await _runHash(_HashRequest(
        material: material,
        salt: salt,
        rounds: rounds,
        isDeveloper: algorithm == developerPasswordHashAlgo,
        verifyDigest: digest,
      ));
      if (outcome.verified) return true;
    }
    // Legacy fallback: plain SHA-256 hex (64 chars).
    if (storedHash.length == 64 &&
        RegExp(r'^[0-9a-fA-F]+$').hasMatch(storedHash)) {
      final candidate = sha256.convert(utf8.encode(password)).toString();
      return _constantTextEquals(candidate.toLowerCase(), storedHash.toLowerCase());
    }
    return false;
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