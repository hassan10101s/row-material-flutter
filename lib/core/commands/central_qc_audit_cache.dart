import 'dart:convert';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../audit/audit_hasher.dart';
import 'qc_audit_contract.dart';

/// A disposable read cache. Original audit fields and hash bytes are never
/// rewritten to match this device's SQL ids or arrival order.
abstract final class CentralQcAuditCache {
  static Map<String, Object?> decode(Map<String, Object?> row) =>
      Map<String, Object?>.from(jsonDecode(row['row_json'] as String) as Map);

  static Future<void> put(
    DatabaseExecutor txn,
    String id,
    int local,
    Map<String, Object?> row,
    Map<String, dynamic> data,
  ) async {
    if (AuditHasher.hash(row) != row['hash'] ||
        qcAuditTargets[data['entityType']] != data['targetEntityType']) {
      throw StateError('Invalid approved QC audit hash or target');
    }
    await txn.insert('central_qc_audits', {
      'entity_id': id,
      'local_ref': local,
      'target_type': data['targetEntityType'],
      'target_global_id': data['targetGlobalId'],
      'audit_kind': data['entityType'],
      'action': data['action'],
      'origin_hash': data['hash'],
      'row_json': jsonEncode(row),
    });
  }

  static Future<String> head(DatabaseExecutor txn) async {
    final rows = await txn.query(
      'central_qc_audits',
      columns: ['origin_hash'],
      orderBy: 'local_ref DESC',
      limit: 1,
    );
    return rows.isEmpty ? '' : rows.single['origin_hash'] as String;
  }

  static Future<List<Map<String, Object?>>> rows(
    DatabaseExecutor txn, {
    String entityType = '',
    String entityId = '',
    String action = '',
    int? id,
    int? limit,
    int offset = 0,
    bool ascending = false,
  }) async {
    final where = <String>[];
    final args = <Object?>[];
    if (id != null) {
      where.add('local_ref = ?');
      args.add(id);
    }
    if (entityType.isNotEmpty) {
      where.add('audit_kind = ?');
      args.add(entityType);
    }
    if (action.isNotEmpty) {
      where.add('action = ?');
      args.add(action);
    }
    if (entityId.isNotEmpty) {
      final targetType = qcAuditTargets[entityType];
      final target = await txn.query(
        'central_entity_identities',
        columns: ['entity_id'],
        where: 'entity_type = ? AND local_ref = ? AND approved_version > 0',
        whereArgs: [targetType, int.tryParse(entityId)],
      );
      if (target.length != 1) return [];
      where.add('target_global_id = ?');
      args.add(target.single['entity_id']);
    }
    return [
      for (final row in await txn.query(
        'central_qc_audits',
        where: where.isEmpty ? null : where.join(' AND '),
        whereArgs: args,
        orderBy: 'local_ref ${ascending ? 'ASC' : 'DESC'}',
        limit: limit,
        offset: offset,
      ))
        decode(row),
    ];
  }

  /// Independent writers may legitimately share the same predecessor. Verify
  /// every original hash and predecessor, without inventing a linear order.
  static Future<AuditChainResult> verify(DatabaseExecutor txn) async {
    final all = await rows(txn, ascending: true);
    final expected =
        ((await txn.rawQuery(
                  "SELECT COUNT(*) AS n FROM central_approved_records WHERE entity_type = 'qcAudit'",
                )).single['n']
                as num)
            .toInt();
    if (expected != all.length) {
      return AuditChainResult(
        isValid: false,
        checked: 0,
        reason: 'Approved QC audit cache is incomplete',
      );
    }
    final hashes = {for (final row in all) row['hash']};
    for (var i = 0; i < all.length; i++) {
      final row = all[i];
      final previous = row['prev_hash'];
      if (AuditHasher.hash(row) != row['hash'] ||
          (previous != null && previous != '' && !hashes.contains(previous))) {
        return AuditChainResult(
          isValid: false,
          checked: i,
          brokenAt: i + 1,
          reason: 'QC audit hash or predecessor is missing',
        );
      }
    }
    return AuditChainResult(
      isValid: true,
      checked: all.length,
      headHash: all.isEmpty ? '' : all.last['hash'] as String,
    );
  }
}
