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

  test('every emitted audit action is accepted by the server contract', () {
    final source = File('lib/core/sync/audit_logger.dart').readAsStringSync();
    final actions = RegExp(
      r"static const String \w+ = '([A-Z_]+)'",
    ).allMatches(source).map((match) => match.group(1)!);
    final start = rules.indexOf('function validAuditAction');
    final block = rules.substring(
      start,
      rules.indexOf('function activeOwnedDevice', start),
    );
    for (final action in actions) {
      expect(
        block.contains("'$action'"),
        isTrue,
        reason: 'audit action $action would strand its outbox entry',
      );
    }
  });

  test('the rules file declares all roles', () {
    expect(ruleMatrix.keys.toSet(), AppRoles.all.toSet());
  });

  test('every role matches the Dart permission matrix', () {
    for (final role in AppRoles.all) {
      expect(
        ruleMatrix[role],
        rolePermissions(role).map((p) => p.id).toSet(),
        reason:
            'role `$role` differs between permissions.dart and firestore.rules',
      );
    }
  });

  test('bounded permission fast paths exactly match the role matrix', () {
    final start = rules.indexOf('function rolePermissionGranted');
    final block = rules.substring(start, rules.indexOf('\n    }', start));
    final groups = RegExp(
      r'perm in \[([^\]]+)\]\s*\? role in \[([^\]]+)\]',
    ).allMatches(block);
    expect(groups.length, 3);
    List<String> strings(String value) =>
        RegExp("'([^']+)'").allMatches(value).map((m) => m.group(1)!).toList();
    for (final group in groups) {
      final allowed = strings(group.group(2)!);
      for (final permission in strings(group.group(1)!)) {
        for (final role in AppRoles.all) {
          expect(
            allowed.contains(role),
            ruleMatrix[role]!.contains(permission),
            reason: '$role / $permission',
          );
        }
      }
    }
  });

  test('an unknown role gets no permission in the rules either', () {
    expect(_roleBlockFor(rules, 'superuser'), isNull);
  });

  test('the catch-all deny stays at the end of the rules', () {
    final lastMatch = RegExp(
      r'match /\{document=\*\*\} \{ allow read, write: if false; \}',
    ).allMatches(rules).toList();
    expect(
      lastMatch.length,
      greaterThanOrEqualTo(2),
      reason: 'both the organization catch-all and the global one are required',
    );
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
      'pushTokens', 'syncReceipts', 'entries',
      'parameters', 'materialBounds', 'organizationSettings',
      'qcSops', 'qcSopRevisions', 'qcSopReads',
      // Comprehensive sync (plan §7).
      'inventoryItems',
      'inventoryTransactions',
      'inventoryLots',
      'consumption',
      'stockAdjustments',
      'equipment',
      'equipmentEvents',
      'worksheets',
      'referenceMaterials',
      'productBatchSamples',
      // QC user-authored tables (definition / columns / records).
      'qcCustomTables',
      'qcCustomTableFields',
      'qcCustomTableRows',
      'qcTemplates', 'qcSections', 'qcItems', 'qcInspections', 'qcResponses',
      'qcTaskLogs', 'qcFindingsNc', 'qcCapa', 'qcAudits',
      // Direct protocol metadata: independently linked to the same atomic
      // business effects, receipts and sequence by the rules.
      'commandReceipts', 'changeEvents', 'counters', 'notifyRequests',
      // Migration-built unique-admission index (same trust boundary).
      'uniqueReservations',
      'analysisDefinitionProofs',
      // Write-only proof of all after-images in an 11/12-effect simple commit.
      'simpleOperationProofs',
      // Session-bound reveal and explicitly authorized privacy maintenance.
      'secureVisibility', 'secureControl',
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
