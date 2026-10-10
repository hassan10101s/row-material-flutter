import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../constants/app_errors.dart';
import 'app_exceptions.dart';

/// Top width (px) used when scaling a report logo down before encoding.
const int appLogoMaxWidth = 400;

/// Reads a logo image from [path], scales it down (preserving aspect ratio) to
/// at most [appLogoMaxWidth] px wide, and encodes it as a PNG data URI.
///
/// Returns the data URI (`data:image/png;base64,...`) which reports consume via
/// the `report_logo_data_uri` setting.
///
/// Synchronous legacy path (kept for callers already off the UI thread).
/// Prefer [encodeReportLogoDataUriAsync] from UI code: decode + resize +
/// PNG-encode run in an isolate instead of blocking the main thread.
String encodeReportLogoDataUri(String path) {
  final file = File(path);
  if (!file.existsSync()) throw NotFoundError(AppErrors.logoNotFound);
  final bytes = file.readAsBytesSync();
  return encodeReportLogoBytesDataUri(bytes);
}

/// Pure-bytes worker shared by the sync and async entry points.
String encodeReportLogoBytesDataUri(Uint8List bytes) {
  if (bytes.isEmpty) throw ValidationError(AppErrors.logoEmpty);
  final decoded = img.decodeImage(bytes);
  if (decoded == null) {
    throw ValidationError(AppErrors.logoFormat);
  }
  var image = decoded;
  if (image.width > appLogoMaxWidth) {
    image = img.copyResize(
      image,
      width: appLogoMaxWidth,
      interpolation: img.Interpolation.linear,
    );
  }
  final encoded = img.encodePng(image);
  return 'data:image/png;base64,${base64Encode(Uint8List.fromList(encoded))}';
}

/// Async UI-safe entry point: file I/O stays async and the heavy
/// decode/resize/encode step runs in [Isolate.run].
Future<String> encodeReportLogoDataUriAsync(String path) async {
  final file = File(path);
  if (!await file.exists()) throw NotFoundError(AppErrors.logoNotFound);
  final bytes = await file.readAsBytes();
  if (bytes.isEmpty) throw ValidationError(AppErrors.logoEmpty);
  return Isolate.run(() => encodeReportLogoBytesDataUri(bytes));
}