import 'dart:convert';
import 'package:http/http.dart' as http;
import '../network/transient_network_error.dart';

class DirectStoreError implements Exception {
  const DirectStoreError(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => '$code: $message';
}

class DirectDocument {
  const DirectDocument(
    this.name,
    this.data,
    this.updateTime, [
    this.encodedFields,
  ]);
  final String name;
  final Map<String, dynamic> data;
  final String updateTime;
  final Map<String, dynamic>? encodedFields;
  String get id => name.split('/').last;
}

/// An explicit Firestore reference (not a string), used by rules to bind
/// business effects to the same atomic change event.
class DirectReference {
  const DirectReference(this.name);
  final String name;
}

/// Transport counters are diagnostics, not Firebase billing totals (rules and
/// index reads are metered by Firebase independently).
class DirectUsage {
  int requests = 0;
  int documentsRead = 0;
  int documentsWritten = 0;
  int responseBytes = 0;
  Map<String, int> toJson() => {
    'requests': requests,
    'documentsRead': documentsRead,
    'documentsWritten': documentsWritten,
    'responseBytes': responseBytes,
  };
}

class DirectReadHead {
  const DirectReadHead(this.document, this.readTime);
  final DirectDocument? document;
  final String readTime;
}

class FirestoreDirectStore {
  FirestoreDirectStore({
    required this.projectId,
    required this.tokenProvider,
    http.Client? client,
    Uri? endpoint,
    this.readTimeout = const Duration(seconds: 20),
    this.readRetryDelay = const Duration(milliseconds: 250),
  }) : client = client ?? http.Client(),
       endpoint = endpoint ?? Uri.parse('https://firestore.googleapis.com') {
    if (!RegExp(r'^[a-z0-9-]+$').hasMatch(projectId)) {
      throw ArgumentError('Invalid project');
    }
    if (this.endpoint.toString() != 'https://firestore.googleapis.com' &&
        !(projectId.startsWith('demo-') &&
            this.endpoint.scheme == 'http' &&
            const {'127.0.0.1', 'localhost'}.contains(this.endpoint.host))) {
      throw ArgumentError(
        'Only the official endpoint or a demo localhost emulator is allowed',
      );
    }
  }
  final String projectId;
  final Future<String?> Function() tokenProvider;
  final http.Client client;
  final Uri endpoint;
  final Duration readTimeout;
  final Duration readRetryDelay;
  final DirectUsage usage = DirectUsage();
  bool quotaPaused = false;
  void resumeQuota() => quotaPaused = false;
  String get documents => 'projects/$projectId/databases/(default)/documents';
  String name(String path) => '$documents/$path';
  void close() => client.close();

  Future<dynamic> request(
    String path, {
    String method = 'POST',
    Map<String, dynamic>? body,
    Map<String, String>? query,
  }) async {
    if (quotaPaused) {
      throw const DirectStoreError(
        'RESOURCE_EXHAUSTED',
        'القراءة والإرسال متوقفان حتى إعادة المحاولة يدويًا بعد توفر الحصة.',
      );
    }
    final token = await tokenProvider();
    if (token == null || token.isEmpty) {
      throw const DirectStoreError('UNAUTHENTICATED', 'سجّل الدخول أولًا.');
    }
    final uri = endpoint.replace(path: '/v1/$path', queryParameters: query);
    // Only explicitly identified reads can be replayed after an interrupted
    // HTTP connection. A commit/begin/rollback never enters this retry path.
    final readOnly =
        method == 'GET' ||
        path.endsWith(':batchGet') ||
        path.endsWith(':runQuery');
    for (var attempt = 0; ; attempt++) {
      try {
        return await _requestOnce(uri, method, body, token, readOnly);
      } catch (error) {
        final temporary =
            isTransientNetworkFailure(error) ||
            (error is DirectStoreError &&
                const {
                  'UNAVAILABLE',
                  'DEADLINE_EXCEEDED',
                  'INTERNAL',
                }.contains(error.code));
        if (!temporary) rethrow;
        if (readOnly && attempt == 0) {
          await Future<void>.delayed(readRetryDelay);
          continue;
        }
        throw TransientNetworkError(error);
      }
    }
  }

  Future<dynamic> _requestOnce(
    Uri uri,
    String method,
    Map<String, dynamic>? body,
    String token,
    bool readOnly,
  ) async {
    final req = http.Request(method, uri)
      ..headers.addAll({
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      });
    if (body != null) req.body = jsonEncode(body);
    usage.requests++;
    final timeout = readOnly ? readTimeout : const Duration(seconds: 45);
    Future<http.Response> sendResponse() async =>
        http.Response.fromStream(await client.send(req));
    final response = await sendResponse().timeout(timeout);
    usage.responseBytes += response.bodyBytes.length;
    final decoded = response.body.isEmpty ? null : jsonDecode(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final error = decoded is Map ? decoded['error'] : null;
      if (error is Map && error['status'] == 'RESOURCE_EXHAUSTED') {
        quotaPaused = true;
      }
      throw DirectStoreError(
        error is Map ? '${error['status'] ?? 'UNAVAILABLE'}' : 'UNAVAILABLE',
        error is Map ? '${error['message'] ?? ''}' : 'تعذر الاتصال بالسيرفر.',
      );
    }
    return decoded;
  }

  Future<String> begin({String? retryTransaction}) async =>
      ((await request(
                '$documents:beginTransaction',
                body: {
                  'options': {
                    'readWrite': <String, dynamic>{
                      // Firebase ID tokens are third-party auth. The current
                      // Firestore contract requires explicit optimistic mode;
                      // the transaction still checks its complete read set.
                      'concurrencyMode': 'OPTIMISTIC',
                      'retryTransaction': ?retryTransaction,
                    },
                  },
                },
              ))
              as Map)['transaction']
          as String;
  Future<void> rollback(String transaction) async {
    await request('$documents:rollback', body: {'transaction': transaction});
  }

  Future<DirectDocument?> get(
    String path, {
    String? transaction,
    String? readTime,
  }) async {
    if (transaction != null) {
      final response = await request(
        '$documents:batchGet',
        body: {
          'documents': [name(path)],
          'transaction': transaction,
        },
      );
      if (response is! List ||
          response.length != 1 ||
          response.single is! Map) {
        throw const FormatException('Invalid transactional read');
      }
      final row = response.single as Map;
      usage.documentsRead++;
      if (row['missing'] == name(path)) return null;
      if (row['found'] is! Map) {
        throw const FormatException('Missing transactional record');
      }
      return parseDocument(Map<String, dynamic>.from(row['found'] as Map));
    }
    try {
      final doc = await request(
        name(path),
        method: 'GET',
        query: readTime == null ? null : {'readTime': readTime},
      );
      usage.documentsRead++;
      return parseDocument(Map<String, dynamic>.from(doc as Map));
    } on DirectStoreError catch (error) {
      if (error.code == 'NOT_FOUND') {
        usage.documentsRead++;
        return null;
      }
      rethrow;
    }
  }

  /// A server timestamp and its counter value from the SAME read. Never use
  /// the device clock to construct a snapshot boundary.
  Future<DirectReadHead> head(String path) async {
    final response = await request(
      '$documents:batchGet',
      body: {
        'documents': [name(path)],
      },
    );
    if (response is! List || response.length != 1 || response.single is! Map) {
      throw const FormatException('Invalid head response');
    }
    final row = response.single as Map;
    final time = row['readTime'];
    if (time is! String || DateTime.tryParse(time) == null) {
      throw const FormatException('Missing server read time');
    }
    usage.documentsRead++;
    return DirectReadHead(
      row['found'] is Map
          ? parseDocument(Map<String, dynamic>.from(row['found'] as Map))
          : null,
      time,
    );
  }

  Future<List<DirectDocument>> getMany(
    List<String> paths, {
    String? readTime,
  }) async {
    if (paths.isEmpty) return [];
    final response = await request(
      '$documents:batchGet',
      body: {
        'documents': paths.toSet().map(name).toList(),
        'readTime': ?readTime,
      },
    );
    if (response is! List) throw const FormatException('Invalid batch read');
    final docs = <DirectDocument>[];
    for (final row in response) {
      if (row is! Map) throw const FormatException('Invalid batch row');
      usage.documentsRead++;
      if (row['found'] is Map) {
        docs.add(parseDocument(Map<String, dynamic>.from(row['found'] as Map)));
      }
    }
    return docs;
  }

  /// Complete, path-keyed transaction read. An omitted response is a broken
  /// read, never evidence that a document (especially a reservation) is absent.
  Future<Map<String, DirectDocument?>> getManyInTransaction(
    List<String> paths, {
    required String transaction,
  }) async {
    final expected = paths.map(name).toSet();
    if (expected.isEmpty) return {};
    final response = await request(
      '$documents:batchGet',
      body: {'documents': expected.toList(), 'transaction': transaction},
    );
    if (response is! List) throw const FormatException('Invalid batch read');
    final result = <String, DirectDocument?>{};
    for (final row in response) {
      if (row is! Map || (row['found'] is Map) == (row['missing'] is String)) {
        throw const FormatException('Invalid transactional batch row');
      }
      final found = row['found'];
      final path = found is Map ? found['name'] : row['missing'];
      if (path is! String ||
          !expected.contains(path) ||
          result.containsKey(path)) {
        throw const FormatException('Unexpected transactional document');
      }
      result[path] = found is Map
          ? parseDocument(Map<String, dynamic>.from(found))
          : null;
      usage.documentsRead++;
    }
    if (result.length != expected.length) {
      throw const FormatException('Incomplete transactional batch read');
    }
    return {for (final path in paths.toSet()) path: result[name(path)]};
  }

  Future<List<DirectDocument>> query(
    String collection, {
    String? after,
    String? configType,
    int limit = 20,
    String? transaction,
    String? readTime,
  }) async {
    final parts = collection.split('/');
    final collectionId = parts.removeLast();
    final parent = parts.isEmpty ? documents : name(parts.join('/'));
    final response = await request(
      '$parent:runQuery',
      body: {
        'transaction': ?transaction,
        'readTime': ?readTime,
        'structuredQuery': {
          'from': [
            {'collectionId': collectionId},
          ],
          if (configType != null)
            'where': {
              'fieldFilter': {
                'field': {'fieldPath': 'configType'},
                'op': 'EQUAL',
                'value': encode(configType),
              },
            },
          'orderBy': [
            {
              'field': {'fieldPath': '__name__'},
              'direction': 'ASCENDING',
            },
          ],
          if (after != null)
            'startAt': {
              'values': [
                {'referenceValue': name('$collection/$after')},
              ],
              'before': false,
            },
          'limit': limit,
        },
      },
    );
    final docs = [
      for (final row in response as List)
        if (row is Map && row['document'] is Map)
          parseDocument(Map<String, dynamic>.from(row['document'] as Map)),
    ];
    usage.documentsRead += docs.isEmpty ? 1 : docs.length;
    return docs;
  }

  Future<Map<String, dynamic>> commit(
    List<Map<String, dynamic>> writes,
    String transaction,
  ) async {
    if (writes.isEmpty || writes.length > 450) {
      throw const DirectStoreError(
        'INVALID_ARGUMENT',
        'حجم العملية يتجاوز حد الحفظ الذري.',
      );
    }
    final result = Map<String, dynamic>.from(
      await request(
            '$documents:commit',
            body: {'writes': writes, 'transaction': transaction},
          )
          as Map,
    );
    usage.documentsWritten += writes.length;
    return result;
  }

  Map<String, dynamic> write(
    String path,
    Map<String, dynamic> data, {
    DirectDocument? current,
    List<String> timestamps = const [],
  }) => {
    'update': {
      'name': name(path),
      'fields': {
        for (final entry in data.entries)
          if (!timestamps.contains(entry.key))
            entry.key:
                current?.encodedFields != null &&
                    current!.data[entry.key] == entry.value &&
                    current.encodedFields!.containsKey(entry.key)
                ? current.encodedFields![entry.key]
                : encode(entry.value),
      },
    },
    'currentDocument': current == null
        ? {'exists': false}
        : {'updateTime': current.updateTime},
    if (timestamps.isNotEmpty)
      'updateTransforms': [
        for (final field in timestamps)
          {'fieldPath': field, 'setToServerValue': 'REQUEST_TIME'},
      ],
  };

  static DirectDocument parseDocument(Map<String, dynamic> doc) =>
      DirectDocument(
        doc['name'] as String,
        {
          for (final entry in (doc['fields'] as Map? ?? {}).entries)
            '${entry.key}': decode(
              Map<String, dynamic>.from(entry.value as Map),
            ),
        },
        doc['updateTime'] as String,
        Map<String, dynamic>.from(doc['fields'] as Map? ?? {}),
      );
  static Map<String, dynamic> encode(Object? value) {
    if (value == null) return {'nullValue': null};
    if (value is DirectReference) return {'referenceValue': value.name};
    if (value is bool) return {'booleanValue': value};
    if (value is int) return {'integerValue': '$value'};
    if (value is double && value.isFinite) return {'doubleValue': value};
    if (value is String) return {'stringValue': value};
    if (value is DateTime) {
      return {'timestampValue': value.toUtc().toIso8601String()};
    }
    if (value is Map) {
      return {
        'mapValue': {
          'fields': {
            for (final e in value.entries) '${e.key}': encode(e.value),
          },
        },
      };
    }
    if (value is List) {
      return {
        'arrayValue': {'values': value.map(encode).toList()},
      };
    }
    throw const FormatException('Unsupported Firestore value');
  }

  static dynamic decode(Map<String, dynamic> v) {
    if (v.containsKey('nullValue')) return null;
    if (v.containsKey('stringValue')) return v['stringValue'];
    if (v.containsKey('booleanValue')) return v['booleanValue'];
    if (v.containsKey('integerValue')) return int.parse('${v['integerValue']}');
    if (v.containsKey('doubleValue')) {
      return (v['doubleValue'] as num).toDouble();
    }
    if (v.containsKey('timestampValue')) return v['timestampValue'];
    if (v.containsKey('referenceValue')) {
      // Read models serialize references as their fully-qualified names.
      // Writes must explicitly opt into a typed reference via DirectReference.
      return v['referenceValue'] as String;
    }
    if (v.containsKey('arrayValue')) {
      return [
        for (final x in ((v['arrayValue'] as Map)['values'] as List? ?? []))
          decode(Map<String, dynamic>.from(x as Map)),
      ];
    }
    if (v.containsKey('mapValue')) {
      return {
        for (final e
            in ((v['mapValue'] as Map)['fields'] as Map? ?? {}).entries)
          '${e.key}': decode(Map<String, dynamic>.from(e.value as Map)),
      };
    }
    throw const FormatException('Unsupported Firestore wire value');
  }
}
