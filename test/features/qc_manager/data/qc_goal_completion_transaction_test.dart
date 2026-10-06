import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/app_paths.dart';
import 'package:material_lab/core/auth/permissions.dart';
import 'package:material_lab/core/database/database_helper.dart';
import 'package:material_lab/core/utils/app_exceptions.dart';
import 'package:material_lab/features/organizations/data/member_write_guard.dart';
import 'package:material_lab/features/qc_manager/data/qc_audit_repo.dart';
import 'package:material_lab/features/qc_manager/data/offline_first_qc_repository.dart';
import 'package:material_lab/features/qc_manager/domain/qc_enums.dart';
import 'package:material_lab/features/qc_manager/domain/qc_goal.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' show Database;

class _TestAppPaths extends AppPaths {
  _TestAppPaths(this.root);

  final String root;

  @override
  Future<Directory> appSupportRoot() async => Directory('$root/MaterialLab');
}

class _Approver implements WriteGuard {
  const _Approver();

  @override
  String get uid => 'u1';
  @override
  String get email => 'u1@example.test';
  @override
  String get organizationId => 'org-1';
  @override
  String get memberId => 'm-1';
  @override
  String get deviceId => 'dev-1';
  @override
  bool get online => true;

  @override
  bool allows(String permissionId) =>
      permissionId == Permission.qcRead.id ||
      permissionId == Permission.qcWrite.id ||
      permissionId == Permission.qcApprove.id;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  DatabaseHelper.ensureDesktopFactory();

  late Directory temporaryDirectory;
  late DatabaseHelper helper;
  late Database database;
  late QcRepositories repositories;

  const timestamp = '2026-01-06T09:30:00Z';

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'qc_goal_completion',
    );
    helper = DatabaseHelper(_TestAppPaths(temporaryDirectory.path));
    database = await helper.database;
    const guard = _Approver();
    repositories = QcRepositories.offlineFirst(
      dbHelper: helper,
      guard: guard,
      actorReader: () =>
          const QcActor(uid: 'u1', name: 'Hana', deviceId: 'device-1'),
    );
  });

  tearDown(() async {
    await database.close();
    if (temporaryDirectory.existsSync()) {
      temporaryDirectory.deleteSync(recursive: true);
    }
  });

  QcGoal makeGoal({
    int? id,
    String status = QcGoalStatus.active,
    String completedBy = '',
    String completedByName = '',
    String completedAt = '',
  }) => QcGoal(
    goalId: id,
    code: 'G-1',
    title: 'Reduce defects',
    startDate: '2026-01-01',
    status: status,
    completedBy: completedBy,
    completedByName: completedByName,
    completedAt: completedAt,
    createdAt: timestamp,
    updatedAt: timestamp,
  );

  test('does not commit completion while an action remains open', () async {
    final goalId = await repositories.goals.createGoal(makeGoal());
    await repositories.goals.addAction(
      QcGoalAction(
        goalId: goalId,
        actionText: 'Verify the process',
        createdAt: timestamp,
        updatedAt: timestamp,
      ),
    );

    await expectLater(
      repositories.goals.saveGoal(
        makeGoal(
          id: goalId,
          status: QcGoalStatus.completed,
          completedBy: 'u1',
          completedByName: 'Hana',
          completedAt: timestamp,
        ),
      ),
      throwsA(isA<ValidationError>()),
    );

    expect(
      (await repositories.goals.getGoal(goalId))!.status,
      QcGoalStatus.active,
    );
    expect(
      await repositories.audit.list(action: QcAuditAction.goalCompleted),
      isEmpty,
    );
  });

  test(
    'commits a valid completion when there are no child work items',
    () async {
      final goalId = await repositories.goals.createGoal(makeGoal());

      await repositories.goals.saveGoal(
        makeGoal(
          id: goalId,
          status: QcGoalStatus.completed,
          completedBy: 'u1',
          completedByName: 'Hana',
          completedAt: timestamp,
        ),
      );

      expect(
        (await repositories.goals.getGoal(goalId))!.status,
        QcGoalStatus.completed,
      );
      expect(
        await repositories.audit.list(action: QcAuditAction.goalCompleted),
        hasLength(1),
      );
    },
  );
}
