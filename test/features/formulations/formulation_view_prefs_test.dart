import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/app_paths.dart';
import 'package:material_lab/di/service_locator.dart';
import 'package:material_lab/features/formulations/presentation/formulation_view_prefs.dart';

class _Paths extends AppPaths {
  _Paths(this.root);
  final Directory root;

  @override
  Future<Directory> orgRoot(String? orgId) async {
    final directory = Directory('${root.path}/${orgId ?? "legacy"}');
    await directory.create(recursive: true);
    return directory;
  }
}

void main() {
  late Directory root;
  late _Paths paths;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('formulation_view_');
    paths = _Paths(root)..orgId = 'org-a';
    getIt.registerSingleton<AppPaths>(paths);
  });

  tearDown(() async {
    await getIt.reset();
    await root.delete(recursive: true);
  });

  test('rapid changes retain the latest view and other formulations', () async {
    await Future.wait([
      FormulationViewPrefs.store(1, {'zoom': 2}, userId: 'alice'),
      FormulationViewPrefs.store(2, {
        'graph': ['fat'],
      }, userId: 'alice'),
      FormulationViewPrefs.store(1, {
        'zoom': 3,
        'donut': 'protein',
      }, userId: 'alice'),
    ]);
    expect(await FormulationViewPrefs.load(1, userId: 'alice'), {
      'zoom': 3,
      'donut': 'protein',
    });
    expect(await FormulationViewPrefs.load(2, userId: 'alice'), {
      'graph': ['fat'],
    });
  });

  test('views stay scoped to the captured organization and user', () async {
    final first = FormulationViewPrefs.store(1, {'zoom': 2}, userId: 'alice');
    paths.orgId = 'org-b';
    final second = FormulationViewPrefs.store(1, {'zoom': 4}, userId: 'alice');
    await Future.wait([first, second]);
    expect(await FormulationViewPrefs.load(1, userId: 'alice'), {'zoom': 4});
    expect(await FormulationViewPrefs.load(1, userId: 'bob'), isNull);
    paths.orgId = 'org-a';
    expect(await FormulationViewPrefs.load(1, userId: 'alice'), {'zoom': 2});
  });
}
