import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:material_lab/core/utils/app_exceptions.dart';
import 'package:material_lab/features/qc_manager/domain/qc_repositories.dart';
import 'package:material_lab/features/qc_manager/presentation/cubit/qc_custom_tables_cubit.dart';

class _RepoMock extends Mock implements QcCustomTablesRepository {}

void main() {
  test('failed table deletion is not reported as saved', () async {
    final repo = _RepoMock();
    when(() => repo.deleteTable(any())).thenAnswer((_) async {
      throw const ValidationError('Delete the records first.');
    });
    final cubit = QcCustomTablesCubit(repo: repo);
    addTearDown(cubit.close);

    expect(await cubit.deleteTable(1), isFalse);
    expect(cubit.state.saved, isFalse);
    expect(cubit.state.error, 'Delete the records first.');
  });
}
