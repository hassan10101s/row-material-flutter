import '../database/database_helper.dart';

/// The same durable entity locks used by the authoring gateway. Other records
/// and navigation remain available while a request awaits a definitive result.
class PendingEntityActions {
  const PendingEntityActions(this.databaseHelper);
  final DatabaseHelper databaseHelper;
  Future<Set<int>> localReferences(String entityType) async {
    final db = await databaseHelper.readDatabase;
    final rows = await db.rawQuery(
      'SELECT i.local_ref FROM central_command_entities l '
      'JOIN central_entity_identities i ON i.entity_type = l.entity_type AND i.entity_id = l.entity_id '
      'WHERE l.entity_type = ?',
      [entityType],
    );
    return {for (final row in rows) int.parse('${row['local_ref']}')};
  }
}
