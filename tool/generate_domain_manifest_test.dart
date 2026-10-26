import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/commands/domain_manifest.dart';
import '../test/sync/sync_test_fixture.dart';
import 'domain_wire_vectors.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'generate the server domain contract from the production SQLite schema',
    () async {
      final fixture = await openSyncFixture();
      try {
        final manifest = await buildDomainManifest(fixture.db);
        await File('functions/domain_manifest.json').writeAsString(
          '${const JsonEncoder.withIndent('  ').convert(manifest)}\n',
        );
        await generateDomainWireVectors(fixture);
      } finally {
        await fixture.dispose();
      }
    },
  );
}
