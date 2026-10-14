import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/constants/app_strings.dart';
import 'package:material_lab/features/lab/presentation/analyses/widgets/analyses_list.dart';
import 'package:material_lab/features/lab/presentation/equipment/equipment_tab.dart';
import 'package:material_lab/features/lab/presentation/inventory/desktop/inventory_tab.dart';

/// Export mappings of the lab register tables: headers + plain-string rows
/// feeding the shared HTML table export. Language-independent assertions
/// (headers are compared against `AppText.t`, not literals).
void main() {
  setUp(() => AppText.useLanguage('en'));
  tearDown(() => AppText.useLanguage('ar'));

  group('inventory table export', () {
    test('headers cover every column', () {
      expect(DesktopInventoryTab.exportHeaders(), hasLength(6));
      expect(
        DesktopInventoryTab.exportHeaders(),
        containsAll(['Name', 'Qty', 'Status']),
      );
    });

    test('status derives from qty vs min (empty / low / ok)', () {
      final rows = DesktopInventoryTab.exportRows([
        {'name': 'A', 'category': 'x', 'unit': 'kg', 'current_qty': 0, 'min_qty': 5},
        {'name': 'B', 'category': 'x', 'unit': 'kg', 'current_qty': 3, 'min_qty': 5},
        {'name': 'C', 'category': 'x', 'unit': 'kg', 'current_qty': 9, 'min_qty': 5},
      ]);
      expect(rows, hasLength(3));
      expect(rows[0].last, 'Empty');
      expect(rows[1].last, 'Low');
      expect(rows[2].last, 'OK');
      expect(rows[0].first, 'A');
    });
  });

  group('analyses table export', () {
    test('items count and fields join map correctly', () {
      expect(AnalysesTable.exportHeaders(), hasLength(4));
      final rows = AnalysesTable.exportRows([
        {
          'name': 'pH',
          'unit': '-',
          'items': [1, 2],
          'dynamic_fields': ['a', 'b'],
        },
        {'name': 'TDS'},
      ]);
      expect(rows, hasLength(2));
      expect(rows[0], ['pH', '-', '2', 'a, b']);
      expect(rows[1], ['TDS', '%', '0', '']);
    });
  });

  group('equipment table export', () {
    test('headers and row mapping cover every column', () {
      expect(EquipmentMasterList.exportHeaders(), hasLength(5));
      final rows = EquipmentMasterList.exportRows([
        {
          'name': 'Oven',
          'code': 'EQ-1',
          'manufacturer': 'Acme',
          'last_calibration_date': '2026-01-01',
          'events_count': 4,
        },
        {'name': 'Scale'},
      ]);
      expect(rows, hasLength(2));
      expect(rows[0], ['Oven', 'EQ-1', 'Acme', '2026-01-01', '4']);
      expect(rows[1], ['Scale', '-', '-', '-', '0']);
    });
  });
}
