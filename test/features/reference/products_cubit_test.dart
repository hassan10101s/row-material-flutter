import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/utils/app_exceptions.dart';
import 'package:material_lab/features/lab/domain/lab_result_repository.dart';
import 'package:material_lab/features/reference/presentation/cubit/products_cubit.dart';

class _ProductsRepository implements LabConfigurationRepository {
  Object? loadError;
  Object? createError;

  @override
  Future<List<Map<String, dynamic>>> listProducts() async {
    if (loadError case final error?) throw error;
    return [];
  }

  @override
  Future<List<Map<String, dynamic>>> listAnalyses() async => [];

  @override
  Future<Map<String, dynamic>> createProduct({
    required String name,
    String category = '',
    String description = '',
    List<Map<String, dynamic>>? ranges,
    Map<String, dynamic>? user,
  }) async {
    if (createError case final error?) throw error;
    return {'id': 1};
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('ProductsCubit errors', () {
    test('a successful reload clears a previous loading error', () async {
      final repository = _ProductsRepository()
        ..loadError = StateError('disk unavailable');
      final cubit = ProductsCubit(repo: repository);
      addTearDown(cubit.close);

      await cubit.load();
      expect(cubit.state.error, isNotNull);
      expect(cubit.state.loading, isFalse);

      repository.loadError = null;
      await cubit.load();
      expect(cubit.state.error, isNull);
      expect(cubit.state.loading, isFalse);
    });

    test(
      'a failed write resets loading and remains available to UI feedback',
      () async {
        final repository = _ProductsRepository()
          ..createError = const ValidationError('duplicate product');
        final cubit = ProductsCubit(repo: repository);
        addTearDown(cubit.close);

        await expectLater(
          cubit.create(name: 'Product'),
          throwsA(isA<ValidationError>()),
        );
        expect(cubit.state.loading, isFalse);
        expect(cubit.state.error, isNull);
      },
    );
  });
}
