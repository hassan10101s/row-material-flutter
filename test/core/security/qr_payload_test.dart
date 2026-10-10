import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/security/qr_builder.dart';
import 'package:material_lab/core/security/qr_payload.dart';
import 'package:material_lab/core/security/seal_codec.dart';

void main() {
  group('encodeAppQrPayload / tryParseAppQr', () {
    test('round-trips the entry code and the untouched body', () {
      const body = 'enc1:abc123';
      final text = encodeAppQrPayload(entryCode: 'R-9', body: body);
      expect(text, startsWith(appQrMagic));
      final parsed = tryParseAppQr(text);
      expect(parsed, isNotNull);
      expect(parsed!.entryCode, 'R-9');
      expect(parsed.body, body);
      expect(parsed.legacy, isFalse);
    });

    test('sealed bodies verify with the sealing key', () {
      final key = List<int>.generate(32, (i) => i + 1);
      const raw = '{"ec":"R-9","m":"Cement"}';
      final text = encodeAppQrPayload(
        entryCode: 'R-9',
        body: sealText(raw, key),
      );
      final parsed = tryParseAppQr(text)!;
      final (plain, ok) = unsealText(parsed.body, key);
      expect(ok, isTrue);
      expect(plain, raw);
      expect((jsonDecode(plain) as Map)['ec'], 'R-9');
    });

    test('wrong key fails closed', () {
      final key = List<int>.generate(32, (i) => i + 1);
      final other = List<int>.generate(32, (i) => 99 - i);
      final text = encodeAppQrPayload(
        entryCode: 'R-9',
        body: sealText('{"ec":"R-9"}', key),
      );
      final parsed = tryParseAppQr(text)!;
      expect(unsealText(parsed.body, other).$2, isFalse);
      // The pointer survives even when verification fails: the device can
      // still resolve WHICH inspection the print refers to.
      expect(parsed.entryCode, 'R-9');
    });

    test('legacy sealed blob parses with an empty pointer', () {
      final parsed = tryParseAppQr('enc1:sometoken');
      expect(parsed, isNotNull);
      expect(parsed!.entryCode, isEmpty);
      expect(parsed.body, 'enc1:sometoken');
      expect(parsed.legacy, isTrue);
    });

    test('legacy raw JSON parses with its own ec', () {
      final parsed = tryParseAppQr('{"ec":"R-9","m":"Cement"}');
      expect(parsed, isNotNull);
      expect(parsed!.entryCode, 'R-9');
      expect(parsed.legacy, isTrue);
    });

    test('foreign codes are rejected', () {
      expect(tryParseAppQr(''), isNull);
      expect(tryParseAppQr('HELLO'), isNull);
      expect(tryParseAppQr('https://example.com/x'), isNull);
      expect(tryParseAppQr('ML2.{"v":1}'), isNull);
      expect(tryParseAppQr('ML1.'), isNull);
      expect(tryParseAppQr('ML1.not-json'), isNull);
      expect(tryParseAppQr('ML1.[1,2]'), isNull);
      expect(tryParseAppQr('{"noec":1}'), isNull);
    });

    test('surrounding whitespace is tolerated', () {
      final text = encodeAppQrPayload(entryCode: 'R-9', body: '{}');
      expect(tryParseAppQr('  $text\n')!.entryCode, 'R-9');
    });
  });

  group('buildQrPayloadText (slim entry-code pointer)', () {
    const inspection = {
      'entry_code': 'PPRO-20260927-001',
      'material_name': 'Protein 21% with a very long name that must not bloat the code',
      'supplier': 'Some supplier',
      'chemical_results': {'Protein': '21', 'Fat': '5', 'Fiber': '3'},
    };

    test('carries only the entry code, sealed', () {
      final key = List<int>.generate(32, (i) => i + 1);
      final text = buildQrPayloadText(
        inspection: inspection,
        encryptKey: key,
      );
      final parsed = tryParseAppQr(text)!;
      expect(parsed.entryCode, 'PPRO-20260927-001');
      // Sealed body holds nothing but the code.
      final (plain, ok) = unsealText(parsed.body, key);
      expect(ok, isTrue);
      expect(jsonDecode(plain), {'ec': 'PPRO-20260927-001'});
    });

    test('stays tiny and self-contained without a key', () {
      final text = buildQrPayloadText(inspection: inspection);
      // Slim enough for a low-density, camera-friendly QR.
      expect(text.length, lessThan(120));
      final parsed = tryParseAppQr(text)!;
      expect(parsed.entryCode, 'PPRO-20260927-001');
      expect(jsonDecode(parsed.body), {'ec': 'PPRO-20260927-001'});
    });

    test('legacy fat prints still parse (backward compatible)', () {
      const fat =
          '{"ec":"R-9","m":"Cement","ph":{"color":["Light gray"]},"ch":{"Moisture":["6"]}}';
      final parsed = tryParseAppQr(fat)!;
      expect(parsed.entryCode, 'R-9');
      expect(parsed.legacy, isTrue);
    });
  });
}
