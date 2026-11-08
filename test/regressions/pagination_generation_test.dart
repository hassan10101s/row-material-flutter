import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:material_lab/core/utils/app_exceptions.dart';
import 'package:material_lab/features/lab/domain/lab_local_repository.dart';
import 'package:material_lab/features/lab/domain/lab_result_repository.dart';
import 'package:material_lab/features/lab/presentation/cubit/analyses_cubit.dart';
import 'package:material_lab/features/lab/presentation/cubit/inventory_cubit.dart';
import 'package:material_lab/features/reference/domain/reference_repository.dart';
import 'package:material_lab/features/reference/presentation/cubit/params_cubit.dart';
import 'package:material_lab/features/reference/presentation/cubit/products_cubit.dart';
import 'package:material_lab/features/reference/presentation/cubit/units_cubit.dart';

class _Reference extends Mock implements ReferenceRepository {}

class _Configuration extends Mock implements LabConfigurationRepository {}

class _Local extends Mock implements LabLocalRepository {}

typedef _Pager = ({
  Future<void> Function() load,
  Future<void> Function() more,
  Future<void> Function(String) search,
  Future<void> Function() close,
  dynamic Function() state,
});

_Pager _pager(
  String kind,
  Completer<List<Map<String, dynamic>>> older,
  Completer<List<Map<String, dynamic>>> latest,
) {
  Future<List<Map<String, dynamic>>> page(Invocation call) {
    final query = call.namedArguments[#query] as String;
    final offset = call.namedArguments[#offset] as int;
    if (query == 'new') {
      return offset == 0
          ? latest.future
          : Future.value([
              {'id': 4},
            ]);
    }
    return offset == 0
        ? Future.value([
            {'id': 1},
          ])
        : older.future;
  }

  switch (kind) {
    case 'units':
      final repo = _Reference();
      when(
        () => repo.listUnitsPaged(
          query: any(named: 'query'),
          limit: 1,
          offset: any(named: 'offset'),
        ),
      ).thenAnswer(page);
      when(
        () => repo.countUnits(query: any(named: 'query')),
      ).thenAnswer((_) async => 2);
      when(() => repo.unitUsageCounts()).thenAnswer((_) async => {});
      final cubit = UnitsCubit(repo: repo, pageSize: 1);
      return (
        load: cubit.load,
        more: cubit.loadMore,
        search: cubit.setQuery,
        close: cubit.close,
        state: () => cubit.state,
      );
    case 'parameters':
      final repo = _Reference();
      when(
        () => repo.listParametersPaged(
          query: any(named: 'query'),
          parameterType: 'chemical',
          limit: 1,
          offset: any(named: 'offset'),
        ),
      ).thenAnswer(page);
      when(
        () => repo.countParameters(
          query: any(named: 'query'),
          parameterType: 'chemical',
        ),
      ).thenAnswer((_) async => 2);
      final cubit = ParamsCubit(
        repo: repo,
        parameterType: 'chemical',
        loadUnits: false,
        pageSize: 1,
      );
      return (
        load: cubit.load,
        more: cubit.loadMore,
        search: cubit.setQuery,
        close: cubit.close,
        state: () => cubit.state,
      );
    case 'products':
      final repo = _Configuration();
      when(
        () => repo.listProductsPaged(
          query: any(named: 'query'),
          limit: 1,
          offset: any(named: 'offset'),
        ),
      ).thenAnswer(page);
      when(
        () => repo.countProducts(query: any(named: 'query')),
      ).thenAnswer((_) async => 2);
      when(() => repo.listAnalyses()).thenAnswer((_) async => []);
      final cubit = ProductsCubit(repo: repo, pageSize: 1);
      return (
        load: cubit.load,
        more: cubit.loadMore,
        search: cubit.setQuery,
        close: cubit.close,
        state: () => cubit.state,
      );
    case 'inventory':
      final repo = _Local();
      when(
        () => repo.listInventoryPaged(
          query: any(named: 'query'),
          limit: 1,
          offset: any(named: 'offset'),
        ),
      ).thenAnswer(page);
      when(
        () => repo.countInventory(query: any(named: 'query')),
      ).thenAnswer((_) async => 2);
      final cubit = InventoryCubit(repo: repo, pageSize: 1);
      return (
        load: cubit.load,
        more: cubit.loadMore,
        search: cubit.setQuery,
        close: cubit.close,
        state: () => cubit.state,
      );
    case 'analyses':
      final repo = _Configuration();
      when(
        () => repo.listAnalysesPaged(
          query: any(named: 'query'),
          limit: 1,
          offset: any(named: 'offset'),
        ),
      ).thenAnswer(page);
      when(
        () => repo.countAnalyses(query: any(named: 'query')),
      ).thenAnswer((_) async => 2);
      final cubit = AnalysesCubit(repo: repo, pageSize: 1);
      return (
        load: cubit.load,
        more: cubit.loadMore,
        search: cubit.setQuery,
        close: cubit.close,
        state: () => cubit.state,
      );
    default:
      throw ArgumentError.value(kind);
  }
}

void main() {
  for (final kind in [
    'units',
    'parameters',
    'products',
    'inventory',
    'analyses',
  ]) {
    group(kind, () {
      late Completer<List<Map<String, dynamic>>> older, latest;
      late _Pager pager;
      setUp(() {
        older = Completer();
        latest = Completer();
        pager = _pager(kind, older, latest);
        addTearDown(pager.close);
      });

      test(
        'an old page cannot alter a new search while its first page is pending',
        () async {
          await pager.load();
          final oldLoad = pager.more();
          final newLoad = pager.search('new');
          expect(pager.state().loadingMore, isFalse);
          older.complete([
            {'id': 2},
          ]);
          await oldLoad;
          expect(pager.state().rows, isEmpty);
          expect(pager.state().loading, isTrue);
          latest.complete([
            {'id': 3},
          ]);
          await newLoad;
          expect(pager.state().query, 'new');
          expect(pager.state().rows, [
            {'id': 3},
          ]);
          await pager.more();
          expect(pager.state().rows, [
            {'id': 3},
            {'id': 4},
          ]);
        },
      );

      for (final error in [
        StateError('old query failed'),
        const ValidationError('old query refused'),
      ]) {
        test(
          'an obsolete ${error.runtimeType} cannot replace a successful search',
          () async {
            await pager.load();
            final oldLoad = pager.more();
            final newLoad = pager.search('new');
            latest.complete([
              {'id': 3},
            ]);
            await newLoad;
            older.completeError(error);
            await oldLoad;
            expect(pager.state().rows, [
              {'id': 3},
            ]);
            expect(pager.state().errorMore, isNull);
            expect(pager.state().loadingMore, isFalse);
            expect(pager.state().hasMore, isTrue);
          },
        );
      }
    });
  }
}
