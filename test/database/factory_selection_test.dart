import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:material_lab/core/database/database_helper.dart';

/// The one place the app picks a SQLite driver, and the one piece of platform
/// branching that is *not* behind a port. It stayed inline deliberately — see
/// PLAN_V4 §5.5 — so these tests exist to keep that decision honest.
void main() {
  final desktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  tearDown(() {
    // Leave the global as a later `initServiceLocator` expects to find it.
    databaseFactoryOrNull = databaseFactoryFfi;
    DatabaseHelper.resetDesktopFactoryForTesting();
  });

  test('selecting a driver is idempotent, because the global is shared', () {
    databaseFactoryOrNull = databaseFactoryFfi;
    DatabaseHelper.resetDesktopFactoryForTesting();

    DatabaseHelper.ensureDesktopFactory();
    final first = databaseFactoryOrNull;
    DatabaseHelper.ensureDesktopFactory();

    // A second call must not reassign: `databaseFactory =` prints a warning and
    // takes over from handles that are already open through the first factory.
    expect(databaseFactoryOrNull, same(first));
  });

  test('on desktop the FFI factory is installed', () {
    databaseFactoryOrNull = null;
    DatabaseHelper.resetDesktopFactoryForTesting();

    DatabaseHelper.ensureDesktopFactory();

    if (desktop) {
      expect(databaseFactoryOrNull, isNotNull);
    } else {
      // A phone must be left alone: `sqfliteFfiInit` on Android would install a
      // driver that cannot load libsqlite3, replacing the native factory the
      // plugin registrant already installed.
      expect(databaseFactoryOrNull, isNull);
    }
  });

  test('on mobile the factory installed by the plugin registrant survives', () {
    // Stand-in for `SqflitePlugin.registerWith`, which does
    // `databaseFactoryOrNull ??= databaseFactorySqflitePlugin`.
    final fromPlugin = databaseFactoryFfi;
    databaseFactoryOrNull = fromPlugin;
    DatabaseHelper.resetDesktopFactoryForTesting();

    DatabaseHelper.ensureDesktopFactory();

    expect(databaseFactoryOrNull, same(fromPlugin));
  });
}
