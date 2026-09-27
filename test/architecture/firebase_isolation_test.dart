import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Path separator as a literal so the test behaves the same on Windows and on
/// the CI runners.
const String sep = r'\';

/// Enforces the boundaries of the offline-first architecture (plan §6.3/§9.2):
///
///  1. no feature module imports the Firebase/Google SDKs - only `lib/core/**`
///     and `lib/core/sync/remote/**` may;
///  2. the features talk to the abstract remote seam, never to
///     `FirestoreDataSource`, so a Django backend can replace Firestore;
///  3. the remote layer never imports sqflite/`DatabaseHelper`.
void main() {
  final lib = Directory('lib');
  late final List<File> dartFiles = lib.existsSync()
      ? lib
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .toList()
      : <File>[];

  const firebasePackages = [
    'package:cloud_firestore/',
    'package:firebase_auth/',
    'package:firebase_core/',
    'package:google_sign_in/',
  ];

  bool isRemoteLayer(String path) =>
      path.startsWith('lib$sep' 'core$sep' 'sync$sep' 'remote$sep') ||
      path == 'lib$sep' 'core$sep' 'firebase$sep' 'firebase_bootstrap.dart' ||
      path == 'lib$sep' 'di$sep' 'service_locator.dart';

  String read(File file) => file.readAsStringSync();

  test('every dart file parses the imports we care about', () {
    expect(lib.existsSync(), isTrue, reason: 'run the tests from the project root');
    expect(dartFiles.length, greaterThan(40));
  });

  test('features never import the Firebase/Google SDKs', () {
    final offenders = <String>[];
    for (final file in dartFiles) {
      if (isRemoteLayer(file.path)) continue;
      if (file.path.startsWith('lib$sep' 'core$sep')) continue;
      final source = read(file);
      for (final pkg in firebasePackages) {
        if (source.contains("import '$pkg")) {
          offenders.add('${file.path} -> $pkg');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: 'route Firebase access through lib/core/sync/remote:\n${offenders.join('\n')}',
    );
  });

  test('feature repositories depend on the remote seam only', () {
    final offenders = <String>[];
    for (final file in dartFiles) {
      if (!file.path.contains('$sep' 'features$sep')) continue;
      // The one adapter that is *supposed* to know about Firestore.
      if (file.path.endsWith('firestore_organization_repository.dart')) continue;
      final source = read(file);
      if (source.contains('FirestoreDataSource') ||
          source.contains('FirestoreOrganizationRepository')) {
        offenders.add(file.path);
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: 'features must talk to the abstract seam only:\n${offenders.join('\n')}',
    );
  });

  test('the remote seam stays free of sqflite imports', () {
    final offenders = <String>[];
    for (final file in dartFiles) {
      // The composition root is the one place allowed to know both worlds.
      if (file.path.startsWith('lib$sep' 'di$sep')) continue;
      if (!isRemoteLayer(file.path)) continue;
      final source = read(file);
      if (source.contains('package:sqflite') || source.contains('DatabaseHelper')) {
        offenders.add(file.path);
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: 'the remote layer must stay storage-agnostic:\n${offenders.join('\n')}',
    );
  });

  test('no feature uses the local password hasher anymore', () {
    final offenders = <String>[];
    for (final file in dartFiles) {
      if (!file.path.contains('$sep' 'features$sep')) continue;
      if (read(file).contains('PasswordHasher(')) offenders.add(file.path);
    }
    expect(offenders, isEmpty,
        reason: 'local credentials were replaced by Google sign-in:\n${offenders.join('\n')}');
  });
}
