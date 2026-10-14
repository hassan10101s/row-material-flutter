import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/design_system/export/table_html_export.dart';

void main() {
  group('TableHtmlExport.buildHtml', () {
    test('renders title, headers and one row per record', () {
      final html = TableHtmlExport.buildHtml(
        title: 'Inventory',
        headers: ['Name', 'Qty'],
        rows: [
          ['Cement', '50'],
          ['Sand', '20'],
        ],
      );
      expect(html, contains('<title>Inventory</title>'));
      expect(html, contains('<th>Name</th><th>Qty</th>'));
      expect(html, contains('<td>Cement</td>'));
      expect(html, contains('<td>20</td>'));
      // Header row + 2 data rows (each data row starts with the index cell).
      expect('<tr><td>1</td>'.allMatches(html).length, 1);
      expect('<tr><td>2</td>'.allMatches(html).length, 1);
      expect(html, contains('window.print()'));
    });

    test('escapes HTML metacharacters in headers and cells', () {
      final html = TableHtmlExport.buildHtml(
        title: 'A&B',
        headers: ['<Name>'],
        rows: [
          ['"quoted" & <tagged>'],
        ],
      );
      expect(html, contains('A&amp;B'));
      expect(html, contains('&lt;Name&gt;'));
      expect(html, contains('&quot;quoted&quot; &amp; &lt;tagged&gt;'));
      expect(html, isNot(contains('<tagged>')));
    });

    test('empty rows still render a valid document', () {
      final html = TableHtmlExport.buildHtml(
        title: 'Empty',
        headers: ['Name'],
        rows: const [],
      );
      expect(html, contains('<table>'));
      expect(html, contains('<tbody></tbody>'));
    });

    test('stamp is sortable and fixed width', () {
      final a = TableHtmlExport.stamp(DateTime(2026, 1, 2, 3, 4, 5));
      expect(a, '20260102_030405');
      expect(
        TableHtmlExport.stamp(DateTime(2026, 1, 2, 3, 4, 6)).compareTo(a) > 0,
        isTrue,
      );
    });
  });
}
