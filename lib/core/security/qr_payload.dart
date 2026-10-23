import 'dart:convert';

import 'seal_codec.dart';

/// Magic prefix marking a QR printed by this app (inspection reports and
/// sample labels). The scanner accepts **only** these — plus the legacy
/// prefix-less prints described below — and rejects every foreign QR.
///
/// A sealed `enc1:` blob alone says *what* but not *which*: only the device
/// that sealed it can open it, so a phone could never resolve a report
/// printed on another machine. The envelope therefore carries the inspection
/// entry code in plaintext (it is already printed human-readable on the
/// report/label itself, so nothing new leaks) while the sealed body keeps
/// its tamper-evidence for the origin device.
const String appQrMagic = 'ML1.';

/// A parsed app QR: what it points at plus the original body
/// (sealed `enc1:` token or raw JSON) for optional verification.
class AppQrPayload {
  const AppQrPayload({
    required this.entryCode,
    required this.body,
    required this.legacy,
    this.kind = '',
  });

  /// The inspection entry code — or, for `kind == 'equipment'`, the equipment
  /// code (`EQ-0001`). Empty only for legacy sealed prints when the
  /// local secret cannot open them (sealed on another device).
  final String entryCode;

  /// The untouched body: sealed token or raw JSON.
  final String body;

  /// True for prints from before the envelope existed.
  final bool legacy;

  /// Target record family: '' (legacy inspection prints) or 'equipment'.
  /// Empty means inspection — every print made before kinds existed.
  final String kind;
}

/// Record family pointed at by an equipment label QR.
const String appQrKindEquipment = 'equipment';

/// Wraps a generated payload (`sealed token` or raw JSON) with the
/// record pointer. Called by the report/label builders only. [kind] is
/// omitted from the JSON when empty so prints made before kinds existed
/// stay byte-identical.
String encodeAppQrPayload({
  required String entryCode,
  required String body,
  String kind = '',
}) => '$appQrMagic${jsonEncode({
      'v': 1,
      'ec': entryCode,
      if (kind.isNotEmpty) 'kind': kind,
      'body': body,
    })}';

/// Parses scanned text. Returns null for anything that is not an app QR —
/// callers must treat null as "reject", never as data.
AppQrPayload? tryParseAppQr(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return null;
  if (text.startsWith(appQrMagic)) {
    try {
      final decoded = jsonDecode(text.substring(appQrMagic.length));
      if (decoded is! Map) return null;
      return AppQrPayload(
        entryCode: '${decoded['ec'] ?? ''}',
        body: '${decoded['body'] ?? ''}',
        legacy: false,
        kind: '${decoded['kind'] ?? ''}',
      );
    } catch (_) {
      return null;
    }
  }
  // Legacy prints (no envelope): a sealed blob, or raw JSON carrying `ec`.
  if (text.startsWith(sealedTextPrefix)) {
    return AppQrPayload(entryCode: '', body: text, legacy: true);
  }
  if (text.startsWith('{')) {
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map && '${decoded['ec'] ?? ''}'.isNotEmpty) {
        return AppQrPayload(
          entryCode: '${decoded['ec']}',
          body: text,
          legacy: true,
          kind: '${decoded['kind'] ?? ''}',
        );
      }
    } catch (_) {}
  }
  return null;
}
