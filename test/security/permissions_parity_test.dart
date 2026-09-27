import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/auth/permissions.dart';

/// Guards the single source of truth: the role -> permission matrix in
/// `lib/core/auth/permissions.dart` and the one mirrored inside
/// `firestore.rules` (`rolePermissions(role)`) must never drift apart
/// (plan §7.1 / §10).
void main() {
  final rulesFile = File('firestore.rules');

  late String rules;
  late Map<String, Set<String>> ruleMatrix;

  setUpAll(() {
    expect(
      rulesFile.existsSync(),
      isTrue,
      reason: 'firestore.rules is missing from the repository root',
    );
    rules = rulesFile.readAsStringSync();
    ruleMatrix = _parseRuleMatrix(rules);
  });

  test('the rules file declares all four roles', () {
    expect(ruleMatrix.keys.toSet(), AppRoles.all.toSet());
  });

  test('every role matches the Dart permission matrix', () {
    for (final role in AppRoles.all) {
      expect(
        ruleMatrix[role],
        rolePermissions(role).map((p) => p.id).toSet(),
        reason: 'role `$role` differs between permissions.dart and firestore.rules',
      );
    }
  });

  test('an unknown role gets no permission in the rules either', () {
    expect(_roleBlockFor(rules, 'superuser'), isNull);
  });

  test('the catch-all deny stays at the end of the rules', () {
    final lastMatch = RegExp(r'match /\{document=\*\*\} \{ allow read, write: if false; \}')
        .allMatches(rules)
        .toList();
    expect(lastMatch.length, greaterThanOrEqualTo(2),
        reason: 'both the organization catch-all and the global one are required');
    final tail = rules.substring(lastMatch.last.end);
    expect(
      tail.replaceAll('}', '').trim(),
      isEmpty,
      reason: 'nothing but closing braces may follow the catch-all deny',
    );
  });

  test('no rule grants write access to an unknown collection', () {
    final allowedCollections = RegExp(r'match /([a-zA-Z]+)/\{')
        .allMatches(rules)
        .map((m) => m.group(1)!)
        .where((name) => name != 'databases')
        .toSet();
    const expected = {
      'users',
      'organizations',
      'meta',
      'invites',
      'members',
      'samples',
      'qualityChecks',
      'labResults',
      'labConfig',
      'devices',
      'auditLogs',
    };
    expect(allowedCollections.difference(expected), isEmpty);
  });
}

/// Extracts the ternary list literal of `rolePermissions(role)` from the rules
/// file: `role == 'admin' ? [ ... ] : role == 'qm' ? [ ... ] : ...`.
Map<String, Set<String>> _parseRuleMatrix(String rules) {
  final start = rules.indexOf('function rolePermissions(role)');
  expect(start, greaterThan(-1), reason: 'rolePermissions() is missing');
  final body = rules.substring(start);
  final out = <String, Set<String>>{};
  final pattern = RegExp(r"role == '([a-z_]+)' \? \[(.*?)\]", dotAll: true);
  for (final match in pattern.allMatches(body)) {
    out[match.group(1)!] = match
        .group(2)!
        .split(',')
        .map((s) => s.trim().replaceAll("'", ''))
        .where((s) => s.isNotEmpty)
        .toSet();
  }
  return out;
}

String? _roleBlockFor(String rules, String role) {
  final pattern = RegExp("role == '$role' \\\\?");
  return pattern.hasMatch(rules) ? role : null;
}
