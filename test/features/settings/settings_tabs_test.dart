import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/features/settings/presentation/settings/settings_screen.dart';

void main() {
  group('SettingsTab', () {
    test('every tab has a unique, URL-safe key', () {
      final keys = SettingsTab.values.map((tab) => tab.key).toList();
      expect(keys.toSet().length, keys.length, reason: 'keys drive ?tab=');
      for (final key in keys) {
        expect(key, matches(RegExp(r'^[a-z][a-z0-9_]*$')), reason: key);
      }
    });

    test('every tab carries an Arabic and an English label', () {
      for (final tab in SettingsTab.values) {
        expect(tab.label, isNotEmpty, reason: tab.key);
        expect(tab.subtitle, isNotEmpty, reason: tab.key);
      }
    });

    test('Sync and Members are settings sections, not their own route', () {
      // `/settings?tab=sync` is what the top-bar sync badge deep-links to, and
      // `/settings?tab=members` is where the roster moved.
      expect(SettingsTab.fromKey('sync'), SettingsTab.sync);
      expect(SettingsTab.fromKey('members'), SettingsTab.members);
    });

    test('an unknown or missing tab falls back to the general section', () {
      expect(SettingsTab.fromKey(null), SettingsTab.general);
      expect(SettingsTab.fromKey(''), SettingsTab.general);
      expect(SettingsTab.fromKey('nope'), SettingsTab.general);
      expect(SettingsTab.fromKey('members;drop'), SettingsTab.general);
    });

    test('the key is what fromKey reads back', () {
      for (final tab in SettingsTab.values) {
        expect(SettingsTab.fromKey(tab.key), tab);
      }
    });
  });
}
