import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/commands/command_contract.dart';

void main() {
  test(
    'simple operations use the whole available atomic budget without granting mixed stock writes',
    () {
      List<Map<String, dynamic>> records(String type, int count) => [
        for (var i = 0; i < count; i++) {'entityType': type, 'entityId': '$i'},
      ];
      expect(businessEffectLimit(records('worksheet', 12)), 12);
      expect(businessEffectLimit(records('worksheet', 13)), lessThan(13));
      expect(businessEffectLimit(records('parameter', 6)), 7);
      expect(businessEffectLimit(records('parameter', 7)), lessThan(7));
      expect(businessEffectLimit(records('equipment', 4)), 5);
      expect(businessEffectLimit(records('equipment', 5)), lessThan(5));
      expect(
        businessEffectLimit([
          ...records('worksheet', 5),
          {'entityType': 'inventoryItem'},
        ]),
        4,
      );
      expect(
        businessEffectLimit([
          for (var i = 0; i < 10; i++)
            {
              'entityType': 'equipmentEvent',
              'entityId': '$i',
              'relations': {
                'equipmentId': {
                  'entityType': 'equipment',
                  'entityId': 'parent$i',
                },
              },
            },
        ]),
        lessThan(10),
      );
    },
  );
  test(
    'one product and six existing reference updates fit the proven budget',
    () {
      final writes = [
        {'entityType': 'labProduct', 'entityId': 'p', 'operation': 'update'},
        for (var i = 0; i < 6; i++)
          {
            'entityType': 'labProductAnalysis',
            'entityId': 'r$i',
            'operation': 'update',
            'relations': {
              'productId': {'entityType': 'labProduct', 'entityId': 'p'},
              'analysisId': {'entityType': 'labAnalysis', 'entityId': 'a$i'},
            },
          },
      ];
      expect(businessEffectLimit(writes), 7);
      expect(
        businessEffectLimit([
          ...writes,
          {...writes.last, 'entityId': 'extra'},
        ]),
        7,
      );
      for (final operation in ['create', 'tombstone']) {
        expect(
          businessEffectLimit([
            writes.first,
            {...writes.last, 'operation': operation},
          ]),
          4,
        );
      }
      expect(
        businessEffectLimit([
          ...writes,
          {'entityType': 'labUnit'},
        ]),
        4,
      );
      expect(
        businessEffectLimit([
          writes.first,
          {...writes.last, 'relations': {}},
        ]),
        4,
      );
    },
  );
  test(
    'actual result with two chemical deductions permits nine effects only within its family',
    () {
      final fixture =
          jsonDecode(
                File(
                  'test/security/fixtures/lab_run_two_chemicals.json',
                ).readAsStringSync(),
              )
              as Map;
      final writes = fixture['writes'] as List;
      expect(writes, hasLength(9));
      expect(isLabConsumptionOperation(writes), isTrue);
      expect(businessEffectLimit(writes), 10);
      expect(
        businessEffectLimit([
          ...writes,
          {'entityType': 'sample'},
        ]),
        4,
      );
      expect(businessEffectLimit([...writes, writes.first]), 4);
      final manyLots = [
        ...writes,
        ...List.generate(
          3,
          (i) => {
            'entityType': 'inventoryLot',
            'entityId': 'extra-$i',
            'operation': 'update',
          },
        ),
      ];
      expect(businessEffectLimit(manyLots), lessThan(manyLots.length));
    },
  );
  test(
    'packed consumption reserves proof blocks and distinct inventory reads',
    () {
      Map<String, dynamic> root(
        int count,
        int stocks, {
        bool deleted = false,
      }) => {
        'entityType': 'labAnalysis',
        'entityId': 'root',
        'operation': deleted ? 'tombstone' : 'create',
        'payload': {
          'chemicalDefinitions': List.generate(
            count,
            (i) => {'inventoryId': 'stock-${i % stocks}'},
          ),
        },
      };
      expect(businessEffectLimit([root(7, 7)]), 1);
      expect(businessEffectLimit([root(25, 1)]), 2);
      expect(businessEffectLimit([root(25, 25)]), 0);
      expect(businessEffectLimit([root(25, 25, deleted: true)]), 6);
      expect(businessEffectLimit([root(36, 1)]), 1);
      expect(businessEffectLimit([root(37, 1)]), 0);
    },
  );
  test(
    'one routine list per operation allows ten atomic effects within its family',
    () {
      List<Map<String, dynamic>> list(int items) => [
        {'entityType': 'qcTemplate', 'entityId': 'tpl', 'operation': 'update'},
        {'entityType': 'qcSection', 'entityId': 'sec', 'operation': 'update'},
        for (var i = 0; i < items; i++)
          {
            'entityType': 'qcItem',
            'entityId': 'item-$i',
            'operation': 'update',
          },
        {'entityType': 'qcAudit', 'entityId': 'audit', 'operation': 'update'},
      ];
      expect(isRoutineListOperation(list(7)), isTrue);
      expect(businessEffectLimit(list(7)), 10);
      expect(isRoutineListOperation(list(8)), isTrue);
      expect(businessEffectLimit(list(8)), lessThan(11));
      // A foreign effect drops the operation back to the standard family.
      expect(
        businessEffectLimit([...list(7), {'entityType': 'sample'}]),
        4,
      );
      // Exactly one template per operation; two templates stay standard.
      expect(
        businessEffectLimit([
          ...list(7),
          {'entityType': 'qcTemplate', 'entityId': 'tpl2'},
        ]),
        4,
      );
      // A lone audit without its template is not a routine-list operation.
      expect(
        businessEffectLimit([{'entityType': 'qcAudit'}]),
        4,
      );
    },
  );
  test('Dart and rules generator use the same scoped release limits', () {
    final config =
        jsonDecode(
              File(
                'tool/central_migration/release_limits.json',
              ).readAsStringSync(),
            )
            as Map;
    expect(config['maxBusinessEffects'], maxBusinessEffects);
    expect(config['maxStandardBusinessEffects'], maxStandardBusinessEffects);
    expect(config['maxLabDefinitionEffects'], maxLabDefinitionEffects);
    expect(config['maxLabConsumptionEffects'], maxLabConsumptionEffects);
    expect(config['maxProductReferenceEffects'], maxProductReferenceEffects);
    expect(config['maxSimpleBusinessEffects'], maxSimpleBusinessEffects);
    expect(config['maxChemicalDefinitions'], maxChemicalDefinitions);
    expect(config['chemicalDefinitionBlockSize'], chemicalDefinitionBlockSize);
    expect(
      config['maxChemicalDefinitionProofBlocks'],
      maxChemicalDefinitionProofBlocks,
    );
    expect((config['simpleEntityTypes'] as List).toSet(), simpleEntityTypes);
    expect(
      (config['routineListEntityTypes'] as List).toSet(),
      routineListEntityTypes,
    );
    expect(config['expandedEntityTypes'], [
      'qcCustomTable',
      'qcCustomTableField',
    ]);
  });
  test(
    'only custom-table definitions receive the nine-column atomic extension',
    () {
      final definition = [
        {'entityType': 'qcCustomTable'},
        ...List.generate(9, (_) => {'entityType': 'qcCustomTableField'}),
      ];
      expect(businessEffectLimit(definition), 10);
      for (final entity in ['sample', 'qcAudit', 'inventoryItem']) {
        expect(
          businessEffectLimit([
            {'entityType': entity},
          ]),
          4,
        );
        expect(
          businessEffectLimit([
            ...definition,
            {'entityType': entity},
          ]),
          4,
        );
      }
      expect(businessEffectLimit([null]), 4);
      expect(
        businessEffectLimit([
          {'entityType': 'qcCustomTableRow'},
        ]),
        12,
      );
    },
  );
  test(
    'physical lab effects reserve shared, uniqueness and external-parent rule reads',
    () {
      final writes = [
        {'entityType': 'labAnalysis'},
        ...List.generate(5, (_) => {'entityType': 'labFieldLink'}),
      ];
      expect(businessEffectLimit(writes), 6);
      expect(
        businessEffectLimit([
          {'entityType': 'labAnalysis'},
          {'entityType': 'labAnalysisItem'},
          {'entityType': 'labUnit'},
        ]),
        6,
      );
      expect(
        businessEffectLimit([
          ...writes,
          {'entityType': 'inventoryItem'},
        ]),
        4,
      );
      final parents = List.generate(
        5,
        (i) => {
          'entityType': 'labFieldLink',
          'entityId': 'field-$i',
          'relations': {
            'inventoryId': {
              'entityType': 'inventoryItem',
              'entityId': 'inventory-$i',
            },
          },
        },
      );
      expect(
        businessEffectLimit([
          {'entityType': 'labAnalysis', 'entityId': 'root'},
          ...parents,
        ]),
        4,
      );
      expect(
        businessEffectLimit([
          {'entityType': 'labAnalysis'},
          {'entityType': 'labAnalysis'},
        ]),
        4,
      );
      expect(
        businessEffectLimit([
          {'entityType': 'labFieldLink'},
        ]),
        4,
      );
    },
  );
}
