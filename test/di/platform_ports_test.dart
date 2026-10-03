import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:material_lab/core/platform/auto_backup_scheduler.dart';
import 'package:material_lab/core/platform/file_delivery.dart';
import 'package:material_lab/core/platform/file_delivery_mobile.dart';
import 'package:material_lab/core/platform/folder_picker.dart';
import 'package:material_lab/di/platform_ports.dart';
import 'package:material_lab/di/service_locator.dart' show getIt;

/// A no-op port, so the test can prove a registered double wins.
class _FakeFileDelivery implements FileDelivery {
  @override
  bool get canReveal => true;
  @override
  bool get canShare => true;
  @override
  Future<bool> reveal(String filePath) async => true;
  @override
  Future<bool> share(String filePath, {String? subject}) async => true;
}

class _FakeFolderPicker implements FolderPicker {
  @override
  bool get supported => true;
  @override
  Future<String?> pick({String? startDirectory, String? dialogTitle}) async =>
      '/picked';
}

class _FakeScheduler implements AutoBackupScheduler {
  @override
  bool get isScheduled => true;
  @override
  Future<void> schedule() async {}
  @override
  Future<void> cancel() async {}
}

/// The contract that matters: every resolver is safe to call when the locator
/// is empty. Each of these is called from a path that is already reporting a
/// successful operation to the user, so throwing would replace that success
/// with an error.
void main() {
  final mobile = Platform.isAndroid || Platform.isIOS;
  final cleanups = <void Function()>[];

  void register<T extends Object>(T value) {
    getIt.registerSingleton<T>(value);
    cleanups.add(() => getIt.unregister<T>());
  }

  tearDown(() {
    for (final cleanup in cleanups) {
      cleanup();
    }
    cleanups.clear();
  });

  test('an empty locator yields the adapter for this platform', () {
    expect(fileDelivery().runtimeType,
        mobile ? MobileFileDelivery : DesktopFileDelivery);
    expect(folderPicker().supported, !mobile);
    expect(autoBackupScheduler().isScheduled, Platform.isAndroid);
  });

  test('a registered double wins over the platform default', () {
    register<FileDelivery>(_FakeFileDelivery());
    register<FolderPicker>(_FakeFolderPicker());
    register<AutoBackupScheduler>(_FakeScheduler());

    expect(fileDelivery(), isA<_FakeFileDelivery>());
    expect(folderPicker().pick(), completion('/picked'));
    expect(autoBackupScheduler().isScheduled, isTrue);
  });

  test('resolution does not leave the port registered', () {
    // Reading a port must not materialise it in the locator, or a later
    // `initServiceLocator` would collide with it.
    fileDelivery();
    folderPicker();
    autoBackupScheduler();
    expect(getIt.isRegistered<FileDelivery>(), isFalse);
    expect(getIt.isRegistered<FolderPicker>(), isFalse);
    expect(getIt.isRegistered<AutoBackupScheduler>(), isFalse);
  });
}
