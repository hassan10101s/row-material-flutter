import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('feature screens compose the shared design-system controls', () {
    // Keep the actual Material implementations in the design system. A new
    // screen must opt into the common geometry, states and adaptive chrome.
    final rawControls = RegExp(
      r'\b(?:TextField|TextFormField|DropdownButtonFormField|DropdownButton|'
      r'DataTable|PaginatedDataTable|Card|AlertDialog|SimpleDialog|'
      r'ElevatedButton|FilledButton|OutlinedButton|TextButton|AppBar)'
      r'(?:<[^;()]+>)?\s*(?:\.[a-zA-Z]+)?\s*\(',
    );
    final rawSheets = RegExp(r'\bshowModalBottomSheet\s*(?:<[^>]+>)?\s*\(');
    final violations = <String>[];
    for (final file
        in Directory('lib/features')
            .listSync(recursive: true)
            .whereType<File>()
            .where(
              (f) =>
                  f.path.endsWith('.dart') && f.path.contains('presentation'),
            )) {
      final code = file
          .readAsStringSync()
          .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '')
          .split('\n')
          .where((line) => !line.trimLeft().startsWith('//'))
          .join('\n');
      for (final pattern in [rawControls, rawSheets]) {
        for (final match in pattern.allMatches(code)) {
          violations.add('${file.path}: ${match.group(0)}');
        }
      }
    }
    expect(violations, isEmpty, reason: violations.join('\n'));
  });
}
