import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:material_lab/core/app_paths.dart';
import 'package:material_lab/core/database/database_helper.dart';
import 'package:material_lab/core/security/local_secret.dart';
import 'package:material_lab/core/utils/logo_encoding.dart';
import 'package:material_lab/features/settings/data/settings_repo.dart';

class _FakeAppPaths extends AppPaths {
  _FakeAppPaths(this.base);
  final String base;
  @override
  Future<Directory> appSupportRoot() async => Directory('$base/MaterialLab');
}

late Directory _tmp;
late DatabaseHelper _dbHelper;
late SettingsRepo _repo;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    DatabaseHelper.ensureDesktopFactory();
    _tmp = await Directory.systemTemp.createTemp('matlab_logo_test');
    _dbHelper = DatabaseHelper(_FakeAppPaths(_tmp.path));
    final secret = LocalSecret(_tmp.path);
    _repo = SettingsRepo(
        dbHelper: _dbHelper, secret: secret, paths: _FakeAppPaths(_tmp.path));
    await _repo.ensureDefaults();
  });

  tearDownAll(() async {
    await _dbHelper.close();
    if (_tmp.existsSync()) _tmp.deleteSync(recursive: true);
  });

  test('encodeReportLogoDataUri produces a decodable PNG data URI', () async {
    final image = img.Image(width: 800, height: 400);
    img.fill(image, color: img.ColorRgb8(2, 132, 199));
    final pngPath = '${_tmp.path}/logo.png';
    File(pngPath).writeAsBytesSync(img.encodePng(image));

    final dataUri = encodeReportLogoDataUri(pngPath);
    expect(dataUri, startsWith('data:image/png;base64,'));
    final bytes = base64Decode(dataUri.substring(dataUri.indexOf(',') + 1));
    final decoded = img.decodeImage(bytes);
    expect(decoded, isNotNull);
    // Oversized input is scaled down to the configured max width.
    expect(decoded!.width, lessThanOrEqualTo(appLogoMaxWidth));
  });

  test('setReportLogo/clearReportLogo persist and clear both keys', () async {
    final dataUri = 'data:image/png;base64,abc';
    await _repo.setReportLogo('C:/logos/custom.png', dataUri);
    expect(await _repo.getReportLogoPath(), 'C:/logos/custom.png');
    expect(await _repo.getReportLogoDataUri(), dataUri);

    await _repo.clearReportLogo();
    expect(await _repo.getReportLogoPath(), '');
    expect(await _repo.getReportLogoDataUri(), '');
  });
}