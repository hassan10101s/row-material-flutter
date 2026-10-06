import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/app_paths.dart';
import 'package:material_lab/core/database/database_helper.dart';
import 'package:material_lab/features/qc_manager/data/qc_repo.dart';
import 'package:material_lab/features/qc_manager/domain/qc_goal.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' show Database;

class _TestAppPaths extends AppPaths {
  _TestAppPaths(this.root);

  final String root;

  @override
  Future<Directory> appSupportRoot() async => Directory('$root/MaterialLab');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  DatabaseHelper.ensureDesktopFactory();

  late Directory temporaryDirectory;
  late DatabaseHelper helper;
  late Database database;

  const timestamp = '2026-01-06T09:30:00Z';

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'qc_goal_kpi_persistence',
    );
    helper = DatabaseHelper(_TestAppPaths(temporaryDirectory.path));
    database = await helper.database;
  });

  tearDown(() async {
    await database.close();
    if (temporaryDirectory.existsSync()) {
      temporaryDirectory.deleteSync(recursive: true);
    }
  });

  test('persists a lower-is-better KPI direction across database reopen', () async {
    final goals = QcGoalRepo(helper);
    final goalId = await goals.createGoal(
      QcGoal(
        code: 'G-1',
        title: 'Reduce defect rate',
        startDate: '2026-01-01',
        createdAt: timestamp,
        updatedAt: timestamp,
      ),
    );
    await goals.addKpi(
      QcGoalKpi(
        goalId: goalId,
        name: 'Defect rate',
        target: 2,
        actual: 1,
        unit: '%',
        higherIsBetter: false,
        createdAt: timestamp,
        updatedAt: timestamp,
      ),
    );

    await database.close();
    helper = DatabaseHelper(_TestAppPaths(temporaryDirectory.path));
    database = await helper.database;

    final persisted = (await QcGoalRepo(helper).listKpis(goalId)).single;
    expect(persisted.higherIsBetter, isFalse);
    expect(persisted.isMet, isTrue);
    expect(persisted.actual, 1);
  });
}
