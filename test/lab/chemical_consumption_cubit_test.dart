import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:material_lab/features/lab/domain/chemical_consumption_report.dart';
import 'package:material_lab/features/lab/domain/lab_local_repository.dart';
import 'package:material_lab/features/lab/presentation/cubit/chemical_consumption_cubit.dart';
import 'package:material_lab/core/sync/sync_data_changes.dart';

class _Repo extends Mock implements LabLocalRepository {}

void main() {
  setUpAll(
    () => registerFallbackValue(
      ConsumptionPeriod(DateTime(2026), DateTime(2026)),
    ),
  );
  test(
    'late responses cannot overwrite a newer chemical/period selection; sync preserves filters',
    () async {
      final repo = _Repo();
      final first = Completer<ChemicalConsumptionReport>();
      when(
        () => repo.chemicalConsumptionReport(
          period: any(named: 'period'),
          inventoryId: any(named: 'inventoryId'),
        ),
      ).thenAnswer((call) async {
        final period = call.namedArguments[#period] as ConsumptionPeriod;
        final id = call.namedArguments[#inventoryId] as int?;
        if (id == null) return first.future;
        return ChemicalConsumptionReport(
          period: period,
          inventoryId: id,
          chemicals: const [],
        );
      });
      final cubit = ChemicalConsumptionCubit(
        repo: repo,
        today: DateTime(2026, 11, 1),
      );
      final pending = cubit.refresh();
      await cubit.selectChemical(2);
      final period = cubit.state.period;
      first.complete(
        ChemicalConsumptionReport(period: period, chemicals: const []),
      );
      await pending;
      expect(cubit.state.inventoryId, 2);
      expect(cubit.state.report!.inventoryId, 2);
      SyncDataChanges.notify();
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.inventoryId, 2);
      expect(cubit.state.period.label, '2026-08-01 - 2026-11-01');
      await cubit.close();
    },
  );
}
