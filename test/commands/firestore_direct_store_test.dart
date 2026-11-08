import 'dart:convert';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_lab/core/commands/firestore_direct_store.dart';
import 'package:material_lab/core/network/transient_network_error.dart';

void main() {
  test(
    'transaction batch maps unordered found and missing paths without losing metadata',
    () async {
      late FirestoreDirectStore store;
      store = FirestoreDirectStore(
        projectId: 'demo-materiallab',
        tokenProvider: () async => 'token',
        client: MockClient((request) async {
          final body = jsonDecode(request.body) as Map;
          expect(body['transaction'], 'tx');
          expect(body.containsKey('readTime'), isFalse);
          expect(body['documents'], [
            store.name('items/a'),
            store.name('items/b'),
          ]);
          return http.Response(
            jsonEncode([
              {'missing': store.name('items/b')},
              {
                'found': {
                  'name': store.name('items/a'),
                  'fields': {
                    'version': {'integerValue': '3'},
                  },
                  'updateTime': '2026-11-02T00:00:00Z',
                },
              },
            ]),
            200,
          );
        }),
      );
      addTearDown(store.close);
      final docs = await store.getManyInTransaction([
        'items/a',
        'items/b',
        'items/a',
      ], transaction: 'tx');
      expect(docs.keys, ['items/a', 'items/b']);
      expect(docs['items/b'], isNull);
      expect(docs['items/a']!.data['version'], 3);
      expect(docs['items/a']!.updateTime, '2026-11-02T00:00:00Z');
      expect(docs['items/a']!.encodedFields, isNotNull);
      expect(store.usage.documentsRead, 2);
      expect(store.usage.requests, 1);
      expect(await store.getManyInTransaction([], transaction: 'tx'), isEmpty);
      expect(store.usage.requests, 1);
    },
  );

  for (final invalid in [
    'omitted',
    'duplicate',
    'unexpected',
    'ambiguous',
    'malformed',
  ]) {
    test(
      'transaction batch rejects $invalid response before it can imply absence',
      () async {
        late FirestoreDirectStore store;
        store = FirestoreDirectStore(
          projectId: 'demo-materiallab',
          tokenProvider: () async => 'token',
          client: MockClient((_) async {
            final missing = {'missing': store.name('items/a')};
            final response = switch (invalid) {
              'omitted' => [],
              'duplicate' => [missing, missing],
              'unexpected' => [
                {'missing': store.name('items/other')},
              ],
              'ambiguous' => [
                {
                  ...missing,
                  'found': {'name': store.name('items/a')},
                },
              ],
              _ => [{}],
            };
            return http.Response(jsonEncode(response), 200);
          }),
        );
        addTearDown(store.close);
        await expectLater(
          store.getManyInTransaction(['items/a'], transaction: 'tx'),
          throwsFormatException,
        );
        expect(store.usage.documentsWritten, 0);
      },
    );
  }

  test(
    'an interrupted batch read retries once and never creates a write',
    () async {
      var calls = 0;
      final store = FirestoreDirectStore(
        projectId: 'demo-materiallab',
        tokenProvider: () async => 'token',
        readRetryDelay: Duration.zero,
        client: MockClient((request) async {
          calls++;
          expect(request.url.path, endsWith(':batchGet'));
          if (calls == 1) {
            throw http.ClientException(
              'Connection closed before full header was received',
            );
          }
          return http.Response('[]', 200);
        }),
      );
      addTearDown(store.close);
      expect(
        await store.request(
          '${store.documents}:batchGet',
          body: {'documents': []},
        ),
        isEmpty,
      );
      expect(calls, 2);
      expect(store.usage.documentsWritten, 0);
    },
  );

  test('uncertain mutations never retry at the HTTP layer', () async {
    var calls = 0;
    final store = FirestoreDirectStore(
      projectId: 'demo-materiallab',
      tokenProvider: () async => 'token',
      readRetryDelay: Duration.zero,
      client: MockClient((_) async {
        calls++;
        throw http.ClientException('Reply lost after possible commit');
      }),
    );
    addTearDown(store.close);
    await expectLater(
      store.request('${store.documents}:commit', body: {'writes': []}),
      throwsA(isA<TransientNetworkError>()),
    );
    expect(calls, 1);
  });

  test(
    'continued read timeouts stop after two attempts with a safe message',
    () async {
      var calls = 0;
      final store = FirestoreDirectStore(
        projectId: 'demo-materiallab',
        tokenProvider: () async => 'token',
        readRetryDelay: Duration.zero,
        readTimeout: const Duration(milliseconds: 10),
        client: MockClient((_) async {
          calls++;
          await Completer<void>().future;
          return http.Response('{}', 200);
        }),
      );
      addTearDown(store.close);
      await expectLater(
        store.request('organizations/org', method: 'GET'),
        throwsA(
          isA<TransientNetworkError>().having(
            (e) => e.userMessage,
            'safe message',
            isNot(contains('firestore.googleapis.com')),
          ),
        ),
      );
      expect(calls, 2);
    },
  );
  test(
    'quota exhaustion stops network calls until explicit manual resume',
    () async {
      var calls = 0;
      final store = FirestoreDirectStore(
        projectId: 'demo-materiallab',
        tokenProvider: () async => 'token',
        client: MockClient((request) async {
          calls++;
          return calls == 1
              ? http.Response(
                  jsonEncode({
                    'error': {'status': 'RESOURCE_EXHAUSTED'},
                  }),
                  429,
                )
              : http.Response('{}', 200);
        }),
      );
      addTearDown(store.close);
      final exhausted = isA<DirectStoreError>().having(
        (e) => e.code,
        'code',
        'RESOURCE_EXHAUSTED',
      );
      await expectLater(store.get('organizations/org'), throwsA(exhausted));
      for (var i = 0; i < 20; i++) {
        await expectLater(store.get('organizations/org'), throwsA(exhausted));
      }
      expect(calls, 1);
      expect(store.quotaPaused, isTrue);
      store.resumeQuota();
      await store.request('unused');
      expect(calls, 2);
    },
  );
}
