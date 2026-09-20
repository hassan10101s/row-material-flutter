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
  final QrCode code;
  try {
    code = QrCode.fromData(
      data: payloadText,
      errorCorrectLevel: QrErrorCorrectLevel.M,
    );
  } catch (_) {
    throw const AppError('QR payload exceeds capacity.');
  }
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
}