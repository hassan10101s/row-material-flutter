import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/commands/domain_manifest.dart';
import '../sync/sync_test_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'every domain and serialized field matches the committed server contract',
    () async {
      final fixture = await openSyncFixture();
      try {
        final actual = await buildDomainManifest(fixture.db);
        final published = jsonDecode(
          await File('functions/domain_manifest.json').readAsString(),
        );
        expect(
          actual,
          published,
          reason:
              'Regenerate the server contract and review permission/schema changes together.',
        );
        final entities = actual['entities'] as Map;
        for (final value in entities.values) {
          expect(value['permission'], isNotNull);
          expect(value['fields'], isNot(contains('passwordHash')));
          expect(value['fields'], isNot(contains('reportHtml')));
        }
      } finally {
        await fixture.dispose();
      }
    },
  );
}
