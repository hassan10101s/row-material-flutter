import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_lab/core/auth/app_session.dart';
import 'package:material_lab/core/auth/session_source.dart';
import 'package:material_lab/core/commands/firestore_direct_admission.dart';
import 'package:material_lab/core/commands/firestore_direct_store.dart';
import 'package:material_lab/core/commands/firestore_direct_sync_reader.dart';

void main() {
  test(
    'a missing live counter cannot masquerade as an empty archive',
    () async {
      var requests = 0;
      final store = FirestoreDirectStore(
        projectId: 'demo-materiallab',
        tokenProvider: () async => 'test-token',
        client: MockClient((request) async {
          requests++;
          expect(request.url.path, endsWith(':batchGet'));
          return http.Response(
            jsonEncode([
              {
                'missing': 'organizations/org/counters/changeSequence',
                'readTime': '2026-10-28T00:00:00Z',
              },
            ]),
            200,
          );
        }),
      );
      addTearDown(store.close);
      final reader = FirestoreDirectSyncReader(
        store: store,
        source: SessionSource(
          () => const AppSession(
            uid: 'user',
            organizationId: 'org',
            deviceId: 'device',
            role: 'admin',
            status: 'active',
          ),
        ),
        manifest: () async => {},
      );
      await expectLater(
        reader.readHead(),
        throwsA(
          isA<DirectAdmissionFailure>().having(
            (e) => e.message,
            'explicit readiness reason',
            contains('عداد التغييرات غير موجود'),
          ),
        ),
      );
      expect(requests, 1);
      expect(store.usage.documentsWritten, 0);
    },
  );
}
