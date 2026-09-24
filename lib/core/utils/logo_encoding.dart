import 'dart:convert';
import 'dart:io';
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
String encodeReportLogoDataUri(String path) {
  final file = File(path);
  if (!file.existsSync()) throw NotFoundError(AppErrors.logoNotFound);
  final bytes = file.readAsBytesSync();
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