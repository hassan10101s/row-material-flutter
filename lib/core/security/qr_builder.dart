import 'dart:convert';

import 'qr_payload.dart';
import 'seal_codec.dart';

/// Port of core/utils.py build_qr_payload_text.
///
/// The QR carries the inspection entry code **only**, still sealed: a dense
/// QR packed with the whole report (material, results, history) prints too
/// small for phone cameras to read reliably. Everything else the scanner
/// needs lives in the local database behind that code, so the print stays
/// tiny and scannable.
///
/// The envelope keeps the entry code in plaintext next to the sealed body
/// (see qr_payload.dart): it is already printed human-readable on the
/// report/label itself, and without it a phone could never resolve a print
/// made on another device (only the origin device can unseal).
String buildQrPayloadText({
  required Map<String, dynamic> inspection,
  List<int>? encryptKey,
}) {
  final entryCode = '${inspection['entry_code'] ?? ''}';

  final raw = jsonEncode({'ec': entryCode});
  final String body;
  if (encryptKey != null && encryptKey.isNotEmpty) {
    body = sealText(raw, encryptKey);
  } else {
    body = raw;
  }
  // Envelope with the entry-code pointer: any device can resolve WHICH
  // inspection a print refers to (see qr_payload.dart); the sealed body
  // keeps its tamper-evidence for the origin device.
  return encodeAppQrPayload(entryCode: entryCode, body: body);
}
