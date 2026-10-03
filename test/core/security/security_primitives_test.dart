import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
// `sealedTextPrefix` is declared in BOTH `rules.dart` and `seal_codec.dart`
// with the same value - a duplicated constant, the same defect class as the
// duplicated decision labels. Hidden here so this test pins the codec's copy.
import 'package:material_lab/core/domain/rules.dart' hide sealedTextPrefix;
import 'package:material_lab/core/security/local_secret.dart';
import 'package:material_lab/core/security/password_hash.dart';
import 'package:material_lab/core/security/seal_codec.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/key_derivators/api.dart';
import 'package:pointycastle/key_derivators/pbkdf2.dart';
import 'package:pointycastle/macs/hmac.dart';

/// The security primitives that had **no** behavioural test at all.
///
/// Both are load-bearing and both fail silently, which is exactly the
/// combination that rots: `verify` returns `false` for a malformed stored
/// hash, `unsealText` returns `('', false)` rather than the ciphertext, and
/// `LocalSecret.load` derives a fallback secret from whatever bytes it finds. A
/// regression in any of those degrades into "the user is silently denied" or
/// "a tampered value is accepted", with no crash and no log to notice it by.
///
/// Nothing here needs a device, a network, or the Firestore emulator.
void main() {
  // PBKDF2 at the real 390k rounds costs ~15s per call, which blows the 30s
  // default per-test timeout. Only the tests that genuinely need a real hash
  // pay for it; everything else rebuilds the stored-hash format by hand with 16
  // rounds, which is behaviourally identical.
  const slow = Timeout(Duration(minutes: 4));

  String hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  String pbkdf2(String material, List<int> salt, int rounds) {
    final derivator = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
      ..init(Pbkdf2Parameters(Uint8List.fromList(salt), rounds, 32));
    return hex(derivator.process(Uint8List.fromList(utf8.encode(material))));
  }

  /// A stored hash built with a tiny round count, so `verify` can be exercised
  /// without paying the real rounds on every assertion.
  ///
  /// [pepper] must match the verifying hasher: the pepper is appended to the
  /// password *before* the KDF and is not recoverable from the stored hash. The
  /// legacy algorithm is pepper-free, so [pepper] is ignored for it.
  String cheapHash(
    String password,
    List<int> salt, {
    String? algo,
    int? rounds,
    String pepper = '',
  }) {
    final algorithm = algo ?? passwordHashAlgoV2;
    final r = rounds ?? 16;
    final material = algorithm == passwordHashAlgoLegacy
        ? password
        : '$password$pepper';
    return '$algorithm\$$r\$${hex(salt)}\$${pbkdf2(material, salt, r)}';
  }

  /// Overwrite one field of a stored hash (`algo$rounds$salt$digest`) while
  /// leaving the digest untouched, to prove which fields `verify` actually
  /// binds to.
  String replaceField(String hash, int index, String value) =>
      (hash.split(r'$')..[index] = value).join(r'$');

  group('PasswordHasher.buildHash', () {
    test('emits algo, rounds, salt and digest, and verifies against the pepper',
        () async {
      final hasher = PasswordHasher(pepper: 'pep');
      final hash = await hasher.buildHash('correct horse');

      final parts = hash.split(r'$');
      expect(parts, hasLength(4));
      expect(parts[0], passwordHashAlgoV2);
      expect(parts[1], '$passwordHashRounds');
      expect(parts[2], hasLength(32), reason: '16 random bytes, hex encoded');
      expect(parts[3], hasLength(64), reason: 'SHA-256 digest, hex encoded');

      expect(await hasher.verify('correct horse', hash), isTrue);
      expect(await PasswordHasher(pepper: 'other').verify('correct horse', hash),
          isFalse,
          reason: 'the pepper is folded into the KDF material');
      expect(await hasher.verify('wrong horse', hash), isFalse);
    }, timeout: slow);

    test('salts every hash, so one password never yields the same hash twice',
        () async {
      final hasher = PasswordHasher(pepper: 'pep');
      final a = await hasher.buildHash('same');
      final b = await hasher.buildHash('same');

      expect(a.split(r'$')[2], isNot(b.split(r'$')[2]),
          reason: 'a shared salt would make every account rainbow-tableable');
      expect(a.split(r'$')[3], isNot(b.split(r'$')[3]));
    }, timeout: slow);

    test('the developer algo is the expensive one', () {
      // Asserted on the constants rather than by running a 780k-round hash,
      // which would add ~45s to the suite for no extra signal. `needsUpgrade`
      // below proves the dev algo is judged against its own floor.
      expect(developerPasswordHashAlgo, isNot(passwordHashAlgoV2));
      expect(developerPasswordHashAlgo, contains('dev'));
      expect(developerPasswordHashRounds, passwordHashRounds * 2);
    });
  });

  group('PasswordHasher.verify', () {
    final hasher = PasswordHasher(pepper: 'pep');
    final salt = List<int>.generate(16, (i) => i);

    test('accepts the right password', () async {
      expect(await hasher.verify('right', cheapHash('right', salt, pepper: 'pep')),
          isTrue);
    });

    test('rejects the wrong password', () async {
      expect(
          await hasher.verify('wrong', cheapHash('right', salt, pepper: 'pep')),
          isFalse);
    });

    test('rejects a missing or blank stored hash without hashing', () async {
      expect(await hasher.verify('x', ''), isFalse);
      expect(await hasher.verify('x', '   '), isFalse);
    });

    test('the pepper is part of the material, not just decoration', () async {
      // If this did not hold, rotating the pepper would be a no-op and a
      // leaked DB could be attacked with a pepper-free dictionary.
      final hash = cheapHash('right', salt, pepper: 'pep');
      expect(await hasher.verify('right', hash), isTrue);
      expect(await PasswordHasher(pepper: 'other').verify('right', hash),
          isFalse);
      expect(await PasswordHasher().verify('right', hash), isFalse,
          reason: 'a hasher with no pepper must not match a peppered hash');
    });

    test('a legacy hash is pepper-free and still verifies', () async {
      final legacy = cheapHash('right', salt, algo: passwordHashAlgoLegacy);
      expect(await hasher.verify('right', legacy), isTrue,
          reason: 'existing accounts must keep working after an upgrade');
      expect(await hasher.verify('wrong', legacy), isFalse);
    });

    test('a v2 hash built without the pepper is rejected', () async {
      expect(await hasher.verify('right', cheapHash('right', salt)), isFalse);
    });

    test('an unknown algorithm is rejected rather than guessed', () async {
      final bogus = cheapHash('right', salt, algo: 'md5_something');
      expect(await hasher.verify('right', bogus), isFalse);
    });

    test('the round count is taken from the stored hash, not the constant',
        () async {
      // Label the hash with a different round count than its digest was built
      // with. If verify read `parts[1]`, this must fail.
      final honest = cheapHash('right', salt, pepper: 'pep');
      expect(await hasher.verify('right', honest), isTrue);
      expect(await hasher.verify('right', replaceField(honest, 1, '17')), isFalse);
      expect(await hasher.verify('right', replaceField(honest, 1, '160000')),
          isFalse);
    });

    test('the salt is taken from the stored hash, not a fixed one', () async {
      final honest = cheapHash('right', salt, pepper: 'pep');
      final otherSalt = List<int>.generate(16, (i) => 255 - i);
      expect(await hasher.verify('right', honest), isTrue);
      expect(await hasher.verify('right', replaceField(honest, 2, hex(otherSalt))),
          isFalse,
          reason: 'a digest computed over another salt must not verify');
    });

    test('a bare SHA-256 hex digest still verifies, for pre-PBKDF2 rows',
        () async {
      final sha = sha256.convert(utf8.encode('legacy-plain')).toString();
      expect(sha, hasLength(64));
      expect(await hasher.verify('legacy-plain', sha), isTrue);
      expect(await hasher.verify('other', sha), isFalse);
      expect(await hasher.verify('legacy-plain', sha.toUpperCase()), isTrue,
          reason: 'hex comparison is case-insensitive');
    });

    test('a SHA-256 candidate of the wrong length is rejected', () async {
      expect(await hasher.verify('x', 'abc123'), isFalse);
      expect(await hasher.verify('x', 'z' * 64), isFalse,
          reason: 'non-hex of the right length must not slip through');
    });

    test('the pre-PBKDF2 SHA-256 branch ignores the pepper', () async {
      // Pinned deliberately, not endorsed: because that branch hashes the raw
      // password, rotating the pepper cannot invalidate a stolen DB that still
      // holds legacy digests.
      final sha = sha256.convert(utf8.encode('right')).toString();
      expect(await hasher.verify('right', sha), isTrue);
      expect(await PasswordHasher(pepper: 'other').verify('right', sha), isTrue);
    });

    test('a non-numeric round count is rejected without hashing', () async {
      final hash = 'pbkdf2_sha256_v2\$notanumber\$${hex(salt)}\$${'0' * 64}';
      expect(await hasher.verify('x', hash), isFalse);
    });

    test('a truncated digest is rejected', () async {
      final full = cheapHash('right', salt, pepper: 'pep');
      expect(
        await hasher.verify('right', full.replaceFirst(RegExp(r'[0-9a-f]{64}$'), 'abc')),
        isFalse,
      );
    });

    test('a malformed salt hex throws instead of returning false', () async {
      // PINNED DEFECT, not endorsed. `_hexToBytes` uses
      // `int.parse(..., radix: 16)` with no guard, so a single corrupt stored
      // hash takes the login path down with a FormatException instead of
      // simply denying the login. The correct behaviour is `false`.
      const corrupt = r'pbkdf2_sha256_v2$16$zzzz$0000000000000000000000000000000000000000000000000000000000000000';
      Object? caught;
      try {
        await hasher.verify('x', corrupt);
      } catch (error) {
        caught = error;
      }
      expect(caught, isA<FormatException>(),
          reason: 'PINNED DEFECT: verify must return false, not throw');
    });
  });

  group('PasswordHasher.needsUpgrade', () {
    final hasher = PasswordHasher();
    const tail = r'$aa$0000000000000000000000000000000000000000000000000000000000000000';

    test('an empty hash needs no upgrade', () {
      expect(hasher.needsUpgrade(''), isFalse);
    });

    test('a current v2 hash needs no upgrade', () {
      expect(
        hasher.needsUpgrade(
            '$passwordHashAlgoV2\$$passwordHashRounds$tail'),
        isFalse,
      );
    });

    test('a v2 hash with fewer rounds needs an upgrade', () {
      expect(hasher.needsUpgrade('$passwordHashAlgoV2\$100000$tail'), isTrue);
    });

    test('a legacy hash always needs an upgrade', () {
      expect(
        hasher.needsUpgrade('$passwordHashAlgoLegacy\$390000$tail'),
        isTrue,
      );
    });

    test('a dev hash is judged against the dev round count', () {
      // The dev floor is double the v2 floor, so the same round count is fine
      // for a dev hash and a downgrade for a v2 hash.
      expect(
        hasher.needsUpgrade(
            '$developerPasswordHashAlgo\$$developerPasswordHashRounds$tail'),
        isFalse,
      );
      expect(hasher.needsUpgrade('$developerPasswordHashAlgo\$390000$tail'),
          isTrue);
    });

    test('an unparseable round count is treated as needing an upgrade', () {
      expect(hasher.needsUpgrade('$passwordHashAlgoV2\$abc$tail'), isTrue);
    });

    test('a bare SHA-256 hash is malformed here and needs an upgrade', () {
      expect(hasher.needsUpgrade('a' * 64), isTrue);
    });
  });

  group('sealText / unsealText', () {
    final key = List<int>.generate(32, (i) => (i * 7) % 256);

    test('round-trips a value', () {
      final sealed = sealText('hello 世界', key);
      expect(sealed, startsWith(sealedTextPrefix));
      final (plain, ok) = unsealText(sealed, key);
      expect(ok, isTrue);
      expect(plain, 'hello 世界');
    });

    test('uses a fresh nonce, so identical plaintext seals differently', () {
      expect(sealText('same', key), isNot(sealText('same', key)));
      final a = unsealText(sealText('same', key), key);
      final b = unsealText(sealText('same', key), key);
      expect(a.$2, isTrue);
      expect(b.$2, isTrue);
      expect(a.$1, b.$1);
    });

    test('round-trips an empty string as empty, not as a failure', () {
      expect(sealText('', key), '');
      final (plain, ok) = unsealText('', key);
      expect(ok, isTrue);
      expect(plain, isEmpty);
    });

    test('a wrong key fails closed', () {
      final sealed = sealText('secret', key);
      final wrongKey = List<int>.generate(32, (i) => (i * 7 + 1) % 256);
      final (plain, ok) = unsealText(sealed, wrongKey);
      expect(ok, isFalse);
      expect(plain, isEmpty, reason: 'must never return a partial plaintext');
    });

    test('a tampered ciphertext fails closed', () {
      final sealed = sealText('secret payload', key);
      final bytes = b64UrlNoPadDecode(sealed.substring(sealedTextPrefix.length));
      bytes[bytes.length - 1] ^= 0xFF;
      final tampered = '$sealedTextPrefix${b64UrlNoPad(bytes)}';

      final (plain, ok) = unsealText(tampered, key);
      expect(ok, isFalse);
      expect(plain, isEmpty);
    });

    test('a tampered nonce fails closed, because the nonce is authenticated', () {
      final sealed = sealText('secret payload', key);
      final bytes = b64UrlNoPadDecode(sealed.substring(sealedTextPrefix.length));
      bytes[0] ^= 0x01;
      expect(unsealText('$sealedTextPrefix${b64UrlNoPad(bytes)}', key).$2,
          isFalse);
    });

    test('a tampered tag fails closed', () {
      final sealed = sealText('secret payload', key);
      final bytes = b64UrlNoPadDecode(sealed.substring(sealedTextPrefix.length));
      bytes[14] ^= 0x80;
      expect(unsealText('$sealedTextPrefix${b64UrlNoPad(bytes)}', key).$2,
          isFalse);
    });

    test('an unsealed plaintext is rejected, not trusted', () {
      // The regression this guards: `unseal_text` used to return
      // `(token, true)` for non-`enc1:` input, so anyone able to write the
      // settings row could hand over a plaintext value and have it accepted
      // as authentic.
      final (plain, ok) = unsealText('not-sealed-at-all', key);
      expect(ok, isFalse);
      expect(plain, isEmpty);
    });

    test('a malformed token fails closed rather than throwing', () {
      expect(unsealText('${sealedTextPrefix}abc', key).$2, isFalse);
      expect(unsealText('$sealedTextPrefix!!!!not base64!!!!', key).$2,
          isFalse);
    });

    test('a token shorter than nonce+tag fails closed', () {
      final short = b64UrlNoPad(List<int>.filled(27, 1));
      expect(unsealText('$sealedTextPrefix$short', key).$2, isFalse);
    });

    test('plaintext spanning multiple keystream blocks round-trips', () {
      // The keystream is 32-byte blocks, so anything past the first must still
      // round-trip. This catches an off-by-one in the counter loop.
      final long = 'x' * 500;
      final (plain, ok) = unsealText(sealText(long, key), key);
      expect(ok, isTrue);
      expect(plain, long);
    });

    test('unicode survives the round trip byte-for-byte', () {
      const value = 'عيّنة تجريبية — قلم 0.5 كغ';
      expect(unsealText(sealText(value, key), key).$1, value);
    });
  });

  group('seal_codec helpers', () {
    test('base64url round-trips without padding', () {
      for (final length in [1, 2, 3, 16, 31, 32]) {
        final bytes = List<int>.generate(length, (i) => (i * 31) % 256);
        final encoded = b64UrlNoPad(bytes);
        expect(encoded, isNot(contains('=')));
        expect(b64UrlNoPadDecode(encoded), bytes);
      }
    });

    test('secureRandomBytes is the requested length and not all zeroes', () {
      final a = secureRandomBytes(32);
      expect(a, hasLength(32));
      expect(a.any((b) => b != 0), isTrue);
      expect(a, isNot(secureRandomBytes(32)));
    });

    test('sha256Bytes matches a known vector', () {
      expect(
        hex(sha256Bytes(utf8.encode('abc'))),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
    });

    test('streamXorCrypt is an involution under the same key and nonce', () {
      final nonce = secureRandomBytes(12);
      final plain = utf8.encode('the quick brown fox');
      final once = streamXorCrypt(plain, key256, nonce);
      expect(streamXorCrypt(once, key256, nonce), plain);
      expect(once, isNot(List<int>.from(plain)));
    });

    test('a different key produces a different keystream', () {
      final nonce = secureRandomBytes(12);
      final plain = utf8.encode('same input');
      expect(streamXorCrypt(plain, key256, nonce),
          isNot(streamXorCrypt(plain, List<int>.filled(32, 9), nonce)));
    });

    test('utf8DecodeSafe returns empty on invalid bytes', () {
      expect(utf8DecodeSafe(utf8.encode('valid')), 'valid');
      expect(utf8DecodeSafe(<int>[0xC3, 0x28]), isEmpty);
    });
  });

  group('LocalSecret', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('matlab_secret');
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('creates a 32-byte secret on first load and reuses it after', () async {
      final secret = LocalSecret(tmp.path);
      final first = await secret.load();
      expect(first, hasLength(32));

      expect(await secret.load(), first,
          reason: 'rotating the key would orphan every sealed value');
    });

    test('two instances in the same directory share one secret', () async {
      expect(await LocalSecret(tmp.path).load(), await LocalSecret(tmp.path).load());
    });

    test('different directories get different secrets', () async {
      final other = await Directory.systemTemp.createTemp('matlab_secret_other');
      addTearDown(() async {
        if (await other.exists()) await other.delete(recursive: true);
      });
      expect(await LocalSecret(tmp.path).load(), isNot(await LocalSecret(other.path).load()));
    });

    test('creates the directory when it does not exist', () async {
      final nested = '${tmp.path}${Platform.pathSeparator}deep'
          '${Platform.pathSeparator}nested';
      expect(await Directory(nested).exists(), isFalse);
      expect(await LocalSecret(nested).load(), hasLength(32));
      expect(await Directory(nested).exists(), isTrue);
    });

    test('readSecretText returns null before the file exists', () async {
      expect(await LocalSecret(tmp.path).readSecretText(), isNull);
    });

    test('readSecretText returns the stored text once written', () async {
      final file = File('${tmp.path}${Platform.pathSeparator}.secret');
      await file.writeAsString('stored-text\n');
      expect(await LocalSecret(tmp.path).readSecretText(), 'stored-text');
    });

    test('a corrupt secret file yields a secret DERIVED from its bytes', () async {
      // PINNED DEFECT, not endorsed. `load()` cannot parse the file, so it
      // falls back to `sha256(fileBytes)`. That is deterministic and
      // computable by anyone who can read the file, so a tampered or truncated
      // secret file silently downgrades the local secret from random to
      // guessable instead of regenerating it or reporting the corruption.
      final file = File('${tmp.path}${Platform.pathSeparator}.secret');
      await file.writeAsString('hunter2');

      expect(await LocalSecret(tmp.path).load(), sha256Bytes(utf8.encode('hunter2')));
      expect(await LocalSecret(tmp.path).load(), await LocalSecret(tmp.path).load(),
          reason: 'at least it is stable across reloads');
    });

    test('a too-short base64 secret falls through to a 32-byte digest', () async {
      // Decodes cleanly but is under the 16-byte floor, so it must not be
      // returned as-is.
      final file = File('${tmp.path}${Platform.pathSeparator}.secret');
      await file.writeAsString(b64UrlNoPad(List<int>.filled(8, 7)));

      final secret = await LocalSecret(tmp.path).load();
      expect(secret, hasLength(32));
      expect(secret, isNot(List<int>.filled(8, 7)));
    });

    test('a valid stored secret is used verbatim', () async {
      final secret = secureRandomBytes(32);
      final file = File('${tmp.path}${Platform.pathSeparator}.secret');
      await file.writeAsString(b64UrlNoPad(secret));

      expect(await LocalSecret(tmp.path).load(), secret);
    });
  });
}

/// Shared by the `streamXorCrypt` tests so they do not each rebuild a key.
final key256 = List<int>.generate(32, (i) => (i * 7) % 256);
