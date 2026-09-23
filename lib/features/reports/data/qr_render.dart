import 'dart:convert';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:qr/qr.dart';

import '../../../core/utils/app_exceptions.dart';

/// Port of core/utils.py generate_qr_data_uri (PNG bytes, ERROR_CORRECT_M,
/// auto version selection matching python-qrcode fit=True).
Uint8List qrPngBytes(String payloadText, {int scale = 8, int border = 3}) {
  if (payloadText.isEmpty) {
    throw const AppError('QR payload is empty.');
  }
  final (png, _) =
      _renderQrPng(payloadText, scale: scale, border: border, throwOnFailure: true);
  return png!;
}

/// Port of core/utils.py generate_qr_data_uri — returns a PNG data URI plus
/// an optional bilingual warning when the payload had to be truncated to fit
/// a version-40 QR. Never throws; failures surface as `(dataUri: '', warning)`.
({String dataUri, String warning}) generateQrDataUri(String payloadText) {
  if (payloadText.isEmpty) {
    return (dataUri: '', warning: 'QR payload is empty.');
  }
  final (png, truncated) = _renderQrPng(
      payloadText, scale: 8, border: 3, throwOnFailure: false);
  if (png == null) {
    return (
      dataUri: '',
      warning: 'QR generation failed: Data exceeds QR code capacity (version > 40)',
    );
  }
  return (
    dataUri: 'data:image/png;base64,${base64Encode(png)}',
    warning: truncated
        ? 'تحذير: تم اختزال محتوى الباركود لتناسب الحد الأقصى'
        : '',
  );
}

/// Render a PNG for the given text, retrying with a truncated payload when the
/// full one exceeds QR capacity. Mirrors the attempts list in
/// core/utils.py:548-597 (byte-level truncation at utf-8[:2380] + suffix).
(Uint8List?, bool) _renderQrPng(String payloadText,
    {required int scale, required int border, required bool throwOnFailure}) {
  final full = _encodeQrPng(payloadText, scale: scale, border: border);
  if (full != null) return (full, false);

  final payloadBytes = utf8.encode(payloadText);
  if (payloadBytes.length > 2400) {
    final truncatedBytes = payloadBytes.sublist(0, 2380);
    final truncatedText =
        '${utf8.decode(truncatedBytes, allowMalformed: true)}...[truncated]';
    final alt = _encodeQrPng(truncatedText, scale: scale, border: border);
    if (alt != null) return (alt, true);
  }

  if (throwOnFailure) {
    throw const AppError('Data exceeds QR code capacity (version > 40)');
  }
  return (null, false);
}

Uint8List? _encodeQrPng(String payloadText, {required int scale, required int border}) {
  try {
    final code = QrCode.fromData(
      data: payloadText,
      errorCorrectLevel: QrErrorCorrectLevel.M,
    );
    final image = QrImage(code);

    final modules = image.moduleCount;
    final total = modules + 2 * border;
    final width = total * scale;
    final out = img.Image(width: width, height: width);
    img.fill(out, color: img.ColorRgb8(255, 255, 255));
    final black = img.ColorRgb8(0, 0, 0);
    for (var row = 0; row < modules; row++) {
      for (var col = 0; col < modules; col++) {
        if (image.isDark(row, col)) {
          final x1 = (border + col) * scale;
          final y1 = (border + row) * scale;
          img.fillRect(out,
              x1: x1, y1: y1, x2: x1 + scale, y2: y1 + scale, color: black);
        }
      }
    }
    return Uint8List.fromList(img.encodePng(out));
  } catch (_) {
    return null;
  }
}