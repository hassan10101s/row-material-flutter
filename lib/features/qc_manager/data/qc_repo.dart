import 'package:sqflite/sqflite.dart';

import '../../../core/audit/audit_hasher.dart';
import '../../../core/database/database_helper.dart';
import '../../../core/utils/app_dates.dart';
import '../domain/qc_audit.dart';
import '../domain/qc_enums.dart';
import '../domain/qc_goal.dart';
import '../domain/qc_inspection.dart';
import '../domain/qc_nc_capa.dart';
import '../domain/qc_sop.dart';
import '../domain/qc_template.dart';

/// Tombstoned rows stay on disk so the deletion can be audited and replicated,
/// but they are not part of the working set. Same expression as
/// `InspectionRepo.aliveFilter`; the QC tables declare `deleted_at TEXT` with no
/// default, so NULL is the alive state.
const String qcAliveFilter = 'deleted_at IS NULL';

/// Joins [clause] onto the alive filter.
String qcAlive(String? clause) => clause == null || clause.isEmpty
    ? qcAliveFilter
    : '($qcAliveFilter) AND ($clause)';

/// Joins [clauses] together for a `where`, or null when there are none.
String? qcWhere(List<String> clauses) =>
    clauses.isEmpty ? null : clauses.join(' AND ');

/// Arguments matching [qcWhere].
List<Object?>? qcArgs(List<Object?> values) => values.isEmpty ? null : values;

List<T> qcDecode<T>(
  List<Map<String, Object?>> rows,
  T Function(Map<String, dynamic>) from,
) => [for (final r in rows) from(Map<String, dynamic>.from(r))];

/// The row as inserted: no primary key, because SQLite assigns it.
Map<String, dynamic> qcInsertable(Map<String, dynamic> row, String pk) {
  final out = Map<String, dynamic>.from(row)..remove(pk);
  out.remove('id');
  return out;
}

/// The row as updated: creation facts are never rewritten.
Map<String, dynamic> qcUpdatable(
  Map<String, dynamic> row,
  String pk, {
  Set<String> alsoImmutable = const {},
}) {
  final frozen = <String>{'created_at', 'created_by', ...alsoImmutable};
  final out = qcInsertable(row, pk)
    ..removeWhere((key, _) => frozen.contains(key));
  // A model omits null optional values from `toMap`, which is what we want: the
  // column keeps whatever it had rather than being silently blanked.
  return out;
}

/// Shared plumbing for the QC local repositories (plan V6_ENHANCED §24 P3).
///
/// ## Why the repositories are thin
/// These classes own the SQL and nothing else: no session, no permission check,
/// no audit entry. That is the facade's job (`offline_first_qc_repository.dart`),
/// and keeping the line sharp is what lets a test drive the SQL without building
/// a signed-in user, and lets the facade guarantee that the write, its audit row
/// and its queue row share one transaction.
///
/// ## Column names come from the models
/// Writes go through `Model.toMap()` rather than a hand-written column list, so
/// a column cannot drift between the model and the SQL - the P2 model/schema
/// test (`qc_model_map_test.dart`) already proves every emitted key is a real
/// column of the real table.
///
/// ## `exec` threading
/// Every method takes an optional `DatabaseExecutor`. When the facade supplies
/// its own transaction, the statement joins it; when it does not, the method
/// opens the connection itself. Opening a second connection while a transaction
/// holds the write lock is how a repository deadlocks against itself.
///
/// The shared helpers are top-level functions rather than statics because Dart
/// does not inherit static members - a static here would be invisible to every
/// subclass and would have to be re-declared five times.
abstract class QcLocalRepo {
  QcLocalRepo(this.dbHelper);

  final DatabaseHelper dbHelper;

  Future<Database> get db => dbHelper.database;

  DatabaseExecutor use(DatabaseExecutor? exec, Database db) => exec ?? db;
}

/// SOPs, their revisions and their read/acknowledgement records.
class QcSopRepo extends QcLocalRepo {
  QcSopRepo(super.dbHelper);

  Future<List<QcSop>> listSops({
    String dept = '',
    String status = '',
    bool includeArchived = false,
    DatabaseExecutor? exec,
  }) async {
    final clauses = <String>[qcAliveFilter];
    final values = <Object?>[];
    if (dept.isNotEmpty) {
      clauses.add('dept = ?');
      values.add(dept);
    }
    if (status.isNotEmpty) {
      clauses.add('status = ?');
      values.add(status);
    }
    if (!includeArchived) {
      // `qc_sops` has no `is_archived` column - archiving is a status, unlike
      // `qc_templates` which has both.
      clauses.add("status <> '${SopStatus.archived}'");
    }
    final rows = await use(exec, await db).query(
      'qc_sops',
      where: qcWhere(clauses),
      whereArgs: qcArgs(values),
      orderBy: 'updated_at DESC, sop_id DESC',
    );
    return qcDecode(rows, QcSop.fromMap);
  }

  Future<QcSop?> getSop(int sopId, {DatabaseExecutor? exec}) async {
    final rows = await use(exec, await db).query(
      'qc_sops',
      where: qcAlive('sop_id = ?'),
      whereArgs: [sopId],
      limit: 1,
    );
    return rows.isEmpty
        ? null
        : QcSop.fromMap(Map<String, dynamic>.from(rows.first));
  }

  Future<QcSop?> getSopByCode(String code, {DatabaseExecutor? exec}) async {
    final rows = await use(
      exec,
      await db,
    ).query('qc_sops', where: qcAlive('code = ?'), whereArgs: [code], limit: 1);
    return rows.isEmpty
        ? null
        : QcSop.fromMap(Map<String, dynamic>.from(rows.first));
  }

  Future<int> createSop(QcSop sop, {DatabaseExecutor? exec}) async {
    final txn = use(exec, await db);
    final code = sop.code.trim();
    final clash = await txn.query(
      'qc_sops',
      where: qcAlive('code = ?'),
      whereArgs: [code],
      limit: 1,
    );
    if (clash.isNotEmpty) {
      throw StateError('A QC SOP with code "$code" already exists');
    }
    return txn.insert(
      'qc_sops',
      qcInsertable(sop.toMap(withId: false), 'sop_id'),
    );
  }

  /// Saves the editable fields of a draft SOP.
  ///
  /// `rev_no`, `status` and the published body are not writable here: a change
  /// to published content is a new revision (`publishSopRevision`), not an edit,
  /// otherwise two readers could hold different "revision 3" bodies.
  Future<void> updateSop(QcSop sop, {DatabaseExecutor? exec}) async {
    final txn = use(exec, await db);
    await txn.update(
      'qc_sops',
      qcUpdatable(
        sop.toMap(withId: false),
        'sop_id',
        alsoImmutable: {
          'code',
          'rev_no',
          'status',
          'content_json',
          'published_at',
        },
      ),
      where: 'sop_id = ?',
      whereArgs: [sop.sopId],
    );
  }

  /// Soft delete. The SOP stays readable so a historical inspection can still be
  /// explained years later.
  Future<void> deleteSop(int sopId, {DatabaseExecutor? exec}) async {
    await use(exec, await db).update(
      'qc_sops',
      {'deleted_at': nowIso()},
      where: qcAlive('sop_id = ?'),
      whereArgs: [sopId],
    );
  }

  /// Publishes the current body as a new revision and supersedes the old one.
  ///
  /// Returns the new `rev_id`. Two things are deliberately derived inside the
  /// caller's transaction rather than trusted from the caller:
  ///
  /// * `rev_no` comes from `max(rev_no)`, so two devices publishing offline
  ///   cannot mint the same revision number.
  /// * the body is copied off the SOP row and `prev_rev_id` is read back from the
  ///   revision actually being superseded, so a revision stays a self-contained
  ///   snapshot. A revision that only stored "see the SOP row" would rewrite the
  ///   history of every inspection that cited it.
  Future<int> publishSopRevision(
    int sopId, {
    required String changeSummary,
    String effectiveFrom = '',
    String editedBy = '',
    String editedByName = '',
    DatabaseExecutor? exec,
  }) async {
    final txn = use(exec, await db);
    final sopRows = await txn.query(
      'qc_sops',
      where: qcAlive('sop_id = ?'),
      whereArgs: [sopId],
      limit: 1,
    );
    if (sopRows.isEmpty) {
      throw StateError('QC SOP $sopId does not exist');
    }
    final sop = QcSop.fromMap(Map<String, dynamic>.from(sopRows.first));

    final head = await txn.query(
      'qc_sop_revisions',
      columns: ['rev_no', 'rev_id'],
      where: 'sop_id = ?',
      whereArgs: [sopId],
      orderBy: 'rev_no DESC',
      limit: 1,
    );
    final headRow = head.firstOrNull;
    final nextRev = ((headRow?['rev_no'] as num?)?.toInt() ?? 0) + 1;
    final prevRevId = (headRow?['rev_id'] as num?)?.toInt();
    final stamp = nowIso();

    final contentHash = AuditHasher.hash({
      'content_text': sop.contentText,
      'file_url': sop.fileUrl,
      'file_name': sop.fileName,
      'mime_type': sop.mimeType,
      'rev_no': nextRev,
    });

    final revision = QcSopRevision(
      sopId: sopId,
      revNo: nextRev,
      contentText: sop.contentText,
      fileUrl: sop.fileUrl,
      fileName: sop.fileName,
      mimeType: sop.mimeType,
      changeReason: changeSummary,
      editedBy: editedBy,
      editedByName: editedByName,
      editedAt: stamp,
      diffSummary: changeSummary,
      prevRevIdRef: prevRevId?.toString() ?? '',
      contentHash: contentHash,
      isPublishedRev: true,
    );

    final revId = await txn.insert(
      'qc_sop_revisions',
      revision.toMap(withId: false),
    );
    await txn.update(
      'qc_sop_revisions',
      {'superseded_at': stamp},
      where: 'sop_id = ? AND rev_no < ? AND superseded_at IS NULL',
      whereArgs: [sopId, nextRev],
    );
    await txn.update(
      'qc_sops',
      {
        'rev_no': nextRev,
        'status': SopStatus.published,
        'published_at': stamp,
        // Empty means "not restated", matching every other optional argument in
        // this file. Blanking the date on a republish would silently revoke an
        // effective date that someone else is still relying on.
        if (effectiveFrom.isNotEmpty) 'effective_date': effectiveFrom,
        'updated_at': stamp,
      },
      where: 'sop_id = ?',
      whereArgs: [sopId],
    );
    return revId;
  }

  Future<List<QcSopRevision>> listSopRevisions(
    int sopId, {
    DatabaseExecutor? exec,
  }) async {
    final rows = await use(exec, await db).query(
      'qc_sop_revisions',
      where: 'sop_id = ?',
      whereArgs: [sopId],
      orderBy: 'rev_no DESC',
    );
    return qcDecode(rows, QcSopRevision.fromMap);
  }

  Future<int> recordSopRead(QcSopRead read, {DatabaseExecutor? exec}) async {
    final txn = use(exec, await db);
    // Re-reading the same revision updates the timestamp instead of adding a
    // row, so "who has acknowledged this" is one row per person per revision.
    final existing = await txn.query(
      'qc_sop_reads',
      where: 'sop_id = ? AND rev_no = ? AND user_id = ?',
      whereArgs: [read.sopId, read.revNo, read.userId],
      limit: 1,
    );
    if (existing.isNotEmpty) {
      await txn.update(
        'qc_sop_reads',
        {'read_at': read.readAt, 'ack_method': read.ackMethod},
        where: 'id = ?',
        whereArgs: [existing.first['id']],
      );
      return (existing.first['id'] as num).toInt();
    }
    return txn.insert('qc_sop_reads', read.toMap(withId: false));
  }

  Future<List<QcSopRead>> listSopReads(
    int sopId, {
    DatabaseExecutor? exec,
  }) async {
    final rows = await use(exec, await db).query(
      'qc_sop_reads',
      where: 'sop_id = ?',
      whereArgs: [sopId],
      orderBy: 'read_at DESC',
    );
    return qcDecode(rows, QcSopRead.fromMap);
  }
}

/// Checklist templates with their ordered sections and items.
class QcTemplateRepo extends QcLocalRepo {
  QcTemplateRepo(super.dbHelper);

  Future<List<QcTemplate>> listTemplates({
    String dept = '',
    bool publishedOnly = false,
    DatabaseExecutor? exec,
  }) async {
    final clauses = <String>[qcAliveFilter];
    final values = <Object?>[];
    if (dept.isNotEmpty) {
      clauses.add('dept = ?');
      values.add(dept);
    }
    if (publishedOnly) {
      clauses.add('is_published = 1');
      clauses.add('is_archived = 0');
    }
    final rows = await use(exec, await db).query(
      'qc_templates',
      where: qcWhere(clauses),
      whereArgs: qcArgs(values),
      orderBy: 'name ASC',
    );
    return qcDecode(rows, QcTemplate.fromMap);
  }

  Future<QcTemplate?> getTemplate(
    int templateId, {
    DatabaseExecutor? exec,
  }) async {
    final rows = await use(exec, await db).query(
      'qc_templates',
      where: qcAlive('template_id = ?'),
      whereArgs: [templateId],
      limit: 1,
    );
    return rows.isEmpty
        ? null
        : QcTemplate.fromMap(Map<String, dynamic>.from(rows.first));
  }

  /// Template plus its sections and items in display order.
  ///
  /// All three queries share the caller's executor so the tree comes from one
  /// snapshot: a checklist edited mid-read must not come back with a section
  /// list from one version and items from another.
  Future<({QcTemplate template, List<QcSection> sections, List<QcItem> items})?>
  getTemplateTree(int templateId, {DatabaseExecutor? exec}) async {
    final txn = use(exec, await db);
    final template = await getTemplate(templateId, exec: txn);
    if (template == null) return null;

    final sectionRows = await txn.query(
      'qc_sections',
      where: qcAlive('template_id = ?'),
      whereArgs: [templateId],
      orderBy: 'order_index ASC, section_id ASC',
    );
    final sections = qcDecode(sectionRows, QcSection.fromMap);

    final itemRows = await txn.query(
      'qc_items',
      where: qcAlive('template_id = ?'),
      whereArgs: [templateId],
      orderBy: 'order_index ASC, item_id ASC',
    );
    final items = qcDecode(itemRows, QcItem.fromMap);

    return (template: template, sections: sections, items: items);
  }

  Future<int> createTemplate(
    QcTemplate template, {
    DatabaseExecutor? exec,
  }) async {
    final txn = use(exec, await db);
    final name = template.name.trim();
    final clash = await txn.query(
      'qc_templates',
      where: qcAlive('dept = ? AND name = ?'),
      whereArgs: [template.dept, name],
      limit: 1,
    );
    if (clash.isNotEmpty) {
      throw StateError(
        'A QC template named "$name" already exists in this department',
      );
    }
    return txn.insert(
      'qc_templates',
      qcInsertable(template.toMap(withId: false), 'template_id'),
    );
  }

  /// Replaces the whole tree atomically.
  ///
  /// Delete-then-insert rather than a diff: a checklist is signed as a unit, and
  /// a half-applied edit would leave items that no longer belong to any section.
  /// It runs inside a transaction so a failure restores the previous version.
  Future<void> saveTemplateTree(
    QcTemplate template,
    List<QcSection> sections,
    List<QcItem> items, {
    DatabaseExecutor? exec,
  }) async {
    if (exec != null) return _writeTree(exec, template, sections, items);
    await (await db).transaction(
      (txn) => _writeTree(txn, template, sections, items),
    );
  }

  Future<void> _writeTree(
    DatabaseExecutor txn,
    QcTemplate template,
    List<QcSection> sections,
    List<QcItem> items,
  ) async {
    final templateId = template.templateId;
    if (templateId == null) {
      throw StateError('saveTemplateTree needs a persisted template');
    }

    if (template.isPublished) {
      throw StateError(
        'A published checklist cannot be edited in place. Duplicate it and '
        'publish the copy as a new version.',
      );
    }

    await txn.update(
      'qc_templates',
      qcUpdatable(template.toMap(withId: false), 'template_id'),
      where: 'template_id = ?',
      whereArgs: [templateId],
    );

    // Retire the old children. `deleted_at` rather than DELETE so an inspection
    // that references an old item still resolves it.
    final stamp = nowIso();
    await txn.update(
      'qc_sections',
      {'deleted_at': stamp},
      where: qcAlive('template_id = ?'),
      whereArgs: [templateId],
    );
    await txn.update(
      'qc_items',
      {'deleted_at': stamp},
      where: qcAlive('template_id = ?'),
      whereArgs: [templateId],
    );

    // Bucket the items by the section they arrived with, and refuse the save if any
    // item points outside the tree. Dropping it silently would shrink a signed
    // checklist without a trace, and the inspection built from it would quietly
    // stop asking a question.
    final bySection = <int, List<QcItem>>{};
    for (final section in sections) {
      final key = section.sectionId;
      if (key == null) {
        throw StateError('Every section needs an id before the tree is saved');
      }
      bySection[key] = <QcItem>[];
    }
    for (final item in items) {
      final bucket = bySection[item.sectionId];
      if (bucket == null) {
        throw StateError(
          'Item "${item.label}" belongs to section ${item.sectionId}, which '
          'is not part of this template. Every item must belong to a section '
          'being saved.',
        );
      }
      bucket.add(item);
    }

    for (final section in sections) {
      final sectionId = await txn.insert(
        'qc_sections',
        qcInsertable(
          section.toMap(withId: false)..['template_id'] = templateId,
          'section_id',
        ),
      );
      for (final item in bySection[section.sectionId]!) {
        await txn.insert(
          'qc_items',
          qcInsertable({
            ...item.toMap(withId: false),
            'template_id': templateId,
            'section_id': sectionId,
          }, 'item_id'),
        );
      }
    }
  }

  Future<void> deleteTemplate(int templateId, {DatabaseExecutor? exec}) async {
    await use(exec, await db).update(
      'qc_templates',
      {'deleted_at': nowIso()},
      where: qcAlive('template_id = ?'),
      whereArgs: [templateId],
    );
  }

  /// Issues a template: stamps it published and freezes it from in-place edits.
  ///
  /// An empty checklist must not be issuable. Publishing is the moment the
  /// checklist starts being performed against, and a signed-but-empty one would
  /// silently pass every inspection run against it.
  Future<void> publishTemplate(
    int templateId, {
    String publishedBy = '',
    String effectiveDate = '',
    DatabaseExecutor? exec,
  }) async {
    final txn = use(exec, await db);
    final counts = await txn.rawQuery(
      'SELECT (SELECT COUNT(*) FROM qc_sections WHERE template_id = ? '
      'AND deleted_at IS NULL) AS sections, '
      '(SELECT COUNT(*) FROM qc_items WHERE template_id = ? '
      'AND deleted_at IS NULL) AS items',
      [templateId, templateId],
    );
    final sections = (counts.first['sections'] as num?)?.toInt() ?? 0;
    final items = (counts.first['items'] as num?)?.toInt() ?? 0;
    if (sections == 0 || items == 0) {
      throw StateError(
        'A checklist cannot be published with no sections or no items',
      );
    }

    final stamp = nowIso();
    final changed = await txn.update(
      'qc_templates',
      {
        'is_published': 1,
        'published_by': publishedBy,
        'published_at': stamp,
        'updated_at': stamp,
        if (effectiveDate.isNotEmpty) 'effective_date': effectiveDate,
      },
      where: qcAlive('template_id = ?'),
      whereArgs: [templateId],
    );
    if (changed == 0) {
      throw StateError('No live QC template with id $templateId');
    }
  }

  /// Retires a template without deleting it, so historical inspections keep
  /// resolving their checklist.
  Future<void> archiveTemplate(int templateId, {DatabaseExecutor? exec}) async {
    final changed = await use(exec, await db).update(
      'qc_templates',
      {'is_archived': 1, 'updated_at': nowIso()},
      where: qcAlive('template_id = ?'),
      whereArgs: [templateId],
    );
    if (changed == 0) {
      throw StateError('No live QC template with id $templateId');
    }
  }

  /// Copies a template and its tree under a new name, so an issued checklist can
  /// be revised without touching the issued one.
  Future<int> duplicateTemplate(
    int templateId,
    String newName, {
    String newCode = '',
    DatabaseExecutor? exec,
  }) async {
    final txn = use(exec, await db);
    final tree = await getTemplateTree(templateId, exec: txn);
    if (tree == null) throw StateError('No QC template with id $templateId');

    final stamp = nowIso();
    final copy = QcTemplate(
      templateId: null,
      code: newCode.isNotEmpty
          ? newCode
          : await _freeTemplateCode(
              txn,
              tree.template.code,
              tree.template.version + 1,
            ),
      name: newName,
      type: tree.template.type,
      dept: tree.template.dept,
      description: tree.template.description,
      version: tree.template.version + 1,
      isPublished: false,
      isArchived: false,
      createdAt: stamp,
      updatedAt: stamp,
    );
    final newId = await txn.insert(
      'qc_templates',
      qcInsertable(copy.toMap(withId: false), 'template_id'),
    );

    for (final section in tree.sections) {
      final newSectionId = await txn.insert(
        'qc_sections',
        qcInsertable({
          ...section.toMap(withId: false),
          'template_id': newId,
          'section_id': null,
        }, 'section_id'),
      );
      for (final item in tree.items.where(
        (i) => i.sectionId == section.sectionId,
      )) {
        await txn.insert(
          'qc_items',
          qcInsertable({
            ...item.toMap(withId: false),
            'template_id': newId,
            'section_id': newSectionId,
            'item_id': null,
          }, 'item_id'),
        );
      }
    }
    return newId;
  }

  /// Picks a code for a duplicated checklist that no row is using.
  ///
  /// `qc_templates.code` is UNIQUE across the whole table, not just the live
  /// rows, so a deleted template still holds its code - checking only live rows
  /// would hand back a code the insert then rejects. Deriving `-v2`, `-v3` keeps
  /// the versions of one checklist visibly related, which matters more than
  /// looking tidy when someone is looking for "the v2 of the weld check".
  static Future<String> _freeTemplateCode(
    DatabaseExecutor txn,
    String code,
    int version,
  ) async {
    if (code.isEmpty) return '';
    final taken = <String>{};
    for (final row in await txn.query('qc_templates', columns: ['code'])) {
      taken.add('${row['code'] ?? ''}');
    }
    if (!taken.contains(code)) return code;

    final base = '$code-v$version';
    if (!taken.contains(base)) return base;
    for (var n = 2; n < 1000; n++) {
      final candidate = '$base.$n';
      if (!taken.contains(candidate)) return candidate;
    }
    throw StateError('Could not find a free code for template "$code"');
  }
}

/// Inspections and the per-item responses that make up their score.
class QcInspectionRepo extends QcLocalRepo {
  QcInspectionRepo(super.dbHelper);

  Future<List<QcInspection>> listInspections({
    int? templateId,
    String status = '',
    String refType = '',
    String refId = '',
    String lotNo = '',
    String dept = '',
    int limit = 100,
    int offset = 0,
    DatabaseExecutor? exec,
  }) async {
    final clauses = <String>[qcAliveFilter];
    final values = <Object?>[];
    if (templateId != null) {
      clauses.add('template_id = ?');
      values.add(templateId);
    }
    if (status.isNotEmpty) {
      clauses.add('status = ?');
      values.add(status);
    }
    if (refType.isNotEmpty) {
      clauses.add('ref_type = ?');
      values.add(refType);
    }
    if (refId.isNotEmpty) {
      clauses.add('ref_id = ?');
      values.add(refId);
    }
    if (lotNo.isNotEmpty) {
      clauses.add('lot_no LIKE ?');
      values.add('%$lotNo%');
    }
    if (dept.isNotEmpty) {
      clauses.add('dept = ?');
      values.add(dept);
    }
    final rows = await use(exec, await db).query(
      'qc_inspections',
      where: qcWhere(clauses),
      whereArgs: qcArgs(values),
      orderBy: 'inspection_date DESC, inspection_id DESC',
      limit: limit,
      offset: offset,
    );
    return qcDecode(rows, QcInspection.fromMap);
  }

  Future<QcInspection?> getInspection(
    int inspectionId, {
    DatabaseExecutor? exec,
  }) async {
    final rows = await use(exec, await db).query(
      'qc_inspections',
      where: qcAlive('inspection_id = ?'),
      whereArgs: [inspectionId],
      limit: 1,
    );
    return rows.isEmpty
        ? null
        : QcInspection.fromMap(Map<String, dynamic>.from(rows.first));
  }

  Future<int> countInspections({
    String status = '',
    String refType = '',
    String refId = '',
    DatabaseExecutor? exec,
  }) async {
    final clauses = <String>[qcAliveFilter];
    final values = <Object?>[];
    if (status.isNotEmpty) {
      clauses.add('status = ?');
      values.add(status);
    }
    if (refType.isNotEmpty) {
      clauses.add('ref_type = ?');
      values.add(refType);
    }
    if (refId.isNotEmpty) {
      clauses.add('ref_id = ?');
      values.add(refId);
    }
    final rows = await use(exec, await db).rawQuery(
      'SELECT COUNT(*) AS n FROM qc_inspections'
      '${qcWhere(clauses) == null ? '' : ' WHERE ${qcWhere(clauses)}'}',
      qcArgs(values),
    );
    return (rows.first['n'] as num?)?.toInt() ?? 0;
  }

  /// Creates the inspection and one unanswered `qc_responses` row per item of
  /// the template.
  ///
  /// Seeding the responses up front is deliberate: scoring, progress bars and
  /// "3 of 12 answered" all become plain counts instead of each needing to
  /// reconcile "missing row" with "not answered".
  Future<int> createInspection(
    QcInspection inspection, {
    DatabaseExecutor? exec,
  }) async {
    Future<int> run(DatabaseExecutor txn) async {
      final inspectionId = await txn.insert(
        'qc_inspections',
        qcInsertable(inspection.toMap(withId: false), 'inspection_id'),
      );
      final itemRows = await txn.query(
        'qc_items',
        where: qcAlive('template_id = ?'),
        whereArgs: [inspection.templateId],
        orderBy: 'order_index ASC',
      );
      final stamp = nowIso();
      for (final item in qcDecode(itemRows, QcItem.fromMap)) {
        await txn.insert('qc_responses', {
          'inspection_id': inspectionId,
          'item_id': item.itemId,
          'section_id': item.sectionId,
          'result': QcResponseResult.na,
          'created_at': stamp,
          'updated_at': stamp,
        });
      }
      return inspectionId;
    }

    return exec == null ? (await db).transaction(run) : run(exec);
  }

  Future<void> saveInspection(
    QcInspection inspection, {
    DatabaseExecutor? exec,
  }) async {
    await use(exec, await db).update(
      'qc_inspections',
      qcUpdatable(inspection.toMap(withId: false), 'inspection_id'),
      where: 'inspection_id = ?',
      whereArgs: [inspection.inspectionId],
    );
  }

  Future<void> deleteInspection(
    int inspectionId, {
    DatabaseExecutor? exec,
  }) async {
    await use(exec, await db).update(
      'qc_inspections',
      {'deleted_at': nowIso()},
      where: qcAlive('inspection_id = ?'),
      whereArgs: [inspectionId],
    );
  }

  Future<List<QcResponse>> listResponses(
    int inspectionId, {
    DatabaseExecutor? exec,
  }) async {
    final rows = await use(exec, await db).query(
      'qc_responses',
      where: 'inspection_id = ?',
      whereArgs: [inspectionId],
      orderBy: 'resp_id ASC',
    );
    return qcDecode(rows, QcResponse.fromMap);
  }

  /// Answers one item, then recomputes the inspection's score and result.
  ///
  /// The recompute is part of the same transaction: a response that is stored
  /// without its effect on the score would leave the header claiming the
  /// inspection passed while an item says it failed.
  Future<void> answerResponse(
    QcResponse response, {
    DatabaseExecutor? exec,
  }) async {
    Future<void> run(DatabaseExecutor txn) async {
      await txn.update(
        'qc_responses',
        qcUpdatable(response.toMap(withId: false), 'resp_id'),
        where: 'resp_id = ?',
        whereArgs: [response.respId],
      );
      await QcInspectionRepo.recompute(txn, response.inspectionId);
    }

    if (exec != null) return run(exec);
    await (await db).transaction(run);
  }

  /// Recomputes `result_overall` / `score_pct` / NC counts for one inspection.
  ///
  /// Static rather than private because the NC repository owns the other half of
  /// the dependency: a finding changing the verdict is exactly the same
  /// recomputation, and duplicating it would let the two drift.
  static Future<void> recompute(DatabaseExecutor txn, int inspectionId) async {
    final responses = await txn.query(
      'qc_responses',
      where: 'inspection_id = ?',
      whereArgs: [inspectionId],
    );
    final applicable = responses
        .where((r) => r['result'] != QcResponseResult.na)
        .toList();
    final failed = applicable
        .where((r) => QcResponseResult.isFail('${r['result']}'))
        .length;

    // Score is over applicable items only: counting N/A as a pass would let a
    // checklist inflate its own score by skipping the hard questions.
    final score = applicable.isEmpty
        ? null
        : ((applicable.length - failed) / applicable.length) * 100;

    // Only findings that are still live *and* unresolved get a say. A closed or
    // rejected NC stays on the record but must stop failing the sheet - otherwise
    // a sheet can never recover from a finding that was properly resolved.
    final findings = await txn.query(
      'qc_findings_nc',
      where: qcAlive('inspection_id = ? AND status NOT IN (?, ?)'),
      whereArgs: [inspectionId, NcStatus.closed, NcStatus.rejected],
    );
    final ncCounts = <String, int>{
      NcSeverity.critical: 0,
      NcSeverity.major: 0,
      NcSeverity.minor: 0,
    };
    for (final f in findings) {
      final severity = '${f['severity']}';
      if (ncCounts.containsKey(severity)) {
        ncCounts[severity] = ncCounts[severity]! + 1;
      }
    }

    final critical = ncCounts[NcSeverity.critical]!;
    final major = ncCounts[NcSeverity.major]!;
    // The explicit flag is the only thing that makes a failed item *critical*:
    // the default of 0 has to mean "not critical", so this must not also treat a
    // missing value as critical or every failure would fail its whole sheet.
    final hasCriticalFailure = responses.any(
      (r) =>
          '${r['result']}' == QcResponseResult.fail &&
          (r['is_critical_failure'] as num?)?.toInt() == 1,
    );

    // The domain helper owns the NC-driven policy so the screen and this write
    // cannot disagree about what "Conditional" means. It has no opinion about a
    // plain failed item, though, and a sheet with a failed answer must never
    // come back `Pass` just because nobody raised an NC against it yet.
    final fromNc = QcOverallResult.fromCounts(
      hasCriticalFailure: hasCriticalFailure,
      criticalCount: critical,
      majorCount: major,
    );
    final overall = fromNc == QcOverallResult.pass && failed > 0
        ? QcOverallResult.conditional
        : fromNc;

    await txn.update(
      'qc_inspections',
      {
        'result_overall': overall,
        'score_pct': ?score,
        'has_nc': (findings.isNotEmpty || failed > 0) ? 1 : 0,
        'nc_count': ncCounts.values.fold<int>(0, (a, b) => a + b),
        'critical_nc_count': critical,
        'major_nc_count': major,
        'minor_nc_count': ncCounts[NcSeverity.minor],
      },
      where: 'inspection_id = ?',
      whereArgs: [inspectionId],
    );
  }

  Future<List<QcFindingNc>> listFindings(
    int inspectionId, {
    DatabaseExecutor? exec,
  }) async {
    final rows = await use(exec, await db).query(
      'qc_findings_nc',
      where: qcAlive('inspection_id = ?'),
      whereArgs: [inspectionId],
      orderBy: 'finding_id ASC',
    );
    return qcDecode(rows, QcFindingNc.fromMap);
  }
}

/// Non-conformances, CAPA and the defect-code catalogue.
class QcNcCapaRepo extends QcLocalRepo {
  QcNcCapaRepo(super.dbHelper);

  Future<List<QcFindingNc>> listFindings({
    String status = '',
    String severity = '',
    String assignedTo = '',
    String inspectionId = '',
    bool overdueOnly = false,
    int limit = 200,
    int offset = 0,
    DatabaseExecutor? exec,
  }) async {
    final clauses = <String>[qcAliveFilter];
    final values = <Object?>[];
    if (status.isNotEmpty) {
      clauses.add('status = ?');
      values.add(status);
    }
    if (severity.isNotEmpty) {
      clauses.add('severity = ?');
      values.add(severity);
    }
    if (assignedTo.isNotEmpty) {
      clauses.add('assigned_to = ?');
      values.add(assignedTo);
    }
    if (inspectionId.isNotEmpty) {
      clauses.add('inspection_id = ?');
      values.add(int.parse(inspectionId));
    }
    if (overdueOnly) {
      // "Open" is a status set, not one value, and only open rows can be late.
      clauses.add(
        "status NOT IN ('Closed','Cancelled') AND due_date <> '' AND due_date < ?",
      );
      values.add(qcToday());
    }
    final rows = await use(exec, await db).query(
      'qc_findings_nc',
      where: qcWhere(clauses),
      whereArgs: qcArgs(values),
      orderBy: 'finding_id DESC',
      limit: limit,
      offset: offset,
    );
    return qcDecode(rows, QcFindingNc.fromMap);
  }

  Future<QcFindingNc?> getFinding(
    int findingId, {
    DatabaseExecutor? exec,
  }) async {
    final rows = await use(exec, await db).query(
      'qc_findings_nc',
      where: qcAlive('finding_id = ?'),
      whereArgs: [findingId],
      limit: 1,
    );
    return rows.isEmpty
        ? null
        : QcFindingNc.fromMap(Map<String, dynamic>.from(rows.first));
  }

  /// Raising, editing or closing an NC changes the verdict on the sheet it
  /// belongs to, so every one of these has to land together with the recompute.
  /// Leaving that to the caller is how a sheet ends up claiming `Pass` while a
  /// Critical NC sits open against it - the counts would only ever be right if
  /// some other screen remembered to fix them.
  ///
  /// The three share one shape: do the write, then recompute, inside a single
  /// transaction so a reader never sees the intermediate state.
  Future<int> createFinding(
    QcFindingNc finding, {
    DatabaseExecutor? exec,
  }) async {
    Future<int> run(DatabaseExecutor txn) async {
      final findingId = await txn.insert(
        'qc_findings_nc',
        qcInsertable(finding.toMap(withId: false), 'finding_id'),
      );
      await QcInspectionRepo.recompute(txn, finding.inspectionId);
      return findingId;
    }

    return exec == null ? (await db).transaction(run) : run(exec);
  }

  Future<void> saveFinding(
    QcFindingNc finding, {
    DatabaseExecutor? exec,
  }) async {
    Future<void> run(DatabaseExecutor txn) async {
      await txn.update(
        'qc_findings_nc',
        qcUpdatable(finding.toMap(withId: false), 'finding_id'),
        where: 'finding_id = ?',
        whereArgs: [finding.findingId],
      );
      await QcInspectionRepo.recompute(txn, finding.inspectionId);
    }

    if (exec != null) return run(exec);
    await (await db).transaction(run);
  }

  Future<void> deleteFinding(int findingId, {DatabaseExecutor? exec}) async {
    // The parent is read first: after the tombstone there is no live row left
    // to ask, and we still need it to know which sheet to recompute.
    final owner = await use(exec, await db).query(
      'qc_findings_nc',
      columns: ['inspection_id'],
      where: 'finding_id = ?',
      whereArgs: [findingId],
      limit: 1,
    );
    if (owner.isEmpty) return;
    final inspectionId = (owner.first['inspection_id'] as num).toInt();

    Future<void> run(DatabaseExecutor txn) async {
      await txn.update(
        'qc_findings_nc',
        {'deleted_at': nowIso()},
        where: qcAlive('finding_id = ?'),
        whereArgs: [findingId],
      );
      await QcInspectionRepo.recompute(txn, inspectionId);
    }

    if (exec != null) return run(exec);
    await (await db).transaction(run);
  }

  Future<List<QcCapa>> listCapa({
    String status = '',
    String findingId = '',
    DatabaseExecutor? exec,
  }) async {
    final clauses = <String>[];
    final values = <Object?>[];
    if (status.isNotEmpty) {
      clauses.add('status = ?');
      values.add(status);
    }
    if (findingId.isNotEmpty) {
      clauses.add('finding_id = ?');
      values.add(int.parse(findingId));
    }
    final rows = await use(exec, await db).query(
      'qc_capa',
      where: qcWhere(clauses),
      whereArgs: qcArgs(values),
      orderBy: 'capa_id DESC',
    );
    return qcDecode(rows, QcCapa.fromMap);
  }

  Future<QcCapa?> getCapa(int capaId, {DatabaseExecutor? exec}) async {
    final rows = await use(exec, await db).query(
      'qc_capa',
      where: qcAlive('capa_id = ?'),
      whereArgs: [capaId],
      limit: 1,
    );
    return rows.isEmpty
        ? null
        : QcCapa.fromMap(Map<String, dynamic>.from(rows.first));
  }

  Future<int> createCapa(QcCapa capa, {DatabaseExecutor? exec}) async {
    final txn = use(exec, await db);
    final existing = await txn.query(
      'qc_capa',
      where: 'finding_id = ?',
      whereArgs: [capa.findingId],
      limit: 1,
    );
    if (existing.isNotEmpty) {
      throw StateError('A CAPA already exists for finding ${capa.findingId}');
    }
    return txn.insert(
      'qc_capa',
      qcInsertable(capa.toMap(withId: false), 'capa_id'),
    );
  }

  Future<void> saveCapa(QcCapa capa, {DatabaseExecutor? exec}) async {
    await use(exec, await db).update(
      'qc_capa',
      qcUpdatable(capa.toMap(withId: false), 'capa_id'),
      where: 'capa_id = ?',
      whereArgs: [capa.capaId],
    );
  }

  Future<List<QcDefectCode>> listDefectCodes({
    String category = '',
    DatabaseExecutor? exec,
  }) async {
    final rows = await use(exec, await db).query(
      'qc_defect_codes',
      where: category.isEmpty
          ? 'is_active = 1'
          : 'is_active = 1 AND category = ?',
      whereArgs: category.isEmpty ? const [] : [category],
      orderBy: 'code ASC',
    );
    return qcDecode(rows, QcDefectCode.fromMap);
  }
}

/// Goals, the people assigned to them and the actions they owe.
class QcGoalRepo extends QcLocalRepo {
  QcGoalRepo(super.dbHelper);

  Future<List<QcGoal>> listGoals({
    String status = '',
    String dept = '',
    String ownerId = '',
    bool overdueOnly = false,
    int limit = 100,
    int offset = 0,
    DatabaseExecutor? exec,
  }) async {
    final clauses = <String>[qcAliveFilter];
    final values = <Object?>[];
    if (status.isNotEmpty) {
      clauses.add('status = ?');
      values.add(status);
    }
    if (dept.isNotEmpty) {
      clauses.add('dept = ?');
      values.add(dept);
    }
    if (ownerId.isNotEmpty) {
      clauses.add('owner_id = ?');
      values.add(ownerId);
    }
    if (overdueOnly) {
      clauses.add(
        "status NOT IN ('Completed','Cancelled') AND due_date <> '' AND due_date < ?",
      );
      values.add(qcToday());
    }
    final rows = await use(exec, await db).query(
      'qc_goals',
      where: qcWhere(clauses),
      whereArgs: qcArgs(values),
      orderBy: 'due_date ASC, goal_id DESC',
      limit: limit,
      offset: offset,
    );
    return qcDecode(rows, QcGoal.fromMap);
  }

  Future<QcGoal?> getGoal(int goalId, {DatabaseExecutor? exec}) async {
    final rows = await use(exec, await db).query(
      'qc_goals',
      where: qcAlive('goal_id = ?'),
      whereArgs: [goalId],
      limit: 1,
    );
    return rows.isEmpty
        ? null
        : QcGoal.fromMap(Map<String, dynamic>.from(rows.first));
  }

  Future<int> createGoal(QcGoal goal, {DatabaseExecutor? exec}) async {
    final txn = use(exec, await db);
    final code = goal.code.trim();
    final clash = await txn.query(
      'qc_goals',
      where: qcAlive('code = ?'),
      whereArgs: [code],
      limit: 1,
    );
    if (clash.isNotEmpty) {
      throw StateError('A QC goal with code "$code" already exists');
    }
    return txn.insert(
      'qc_goals',
      qcInsertable(goal.toMap(withId: false), 'goal_id'),
    );
  }

  /// Saves a goal.
  ///
  /// `completed_by` / `completed_at` are writable here but only meaningful once
  /// the goal reaches a closed status - `OfflineFirstQcGoalRepository` enforces
  /// that pairing, because "Completed" without a finisher is exactly the state
  /// this feature exists to prevent.
  ///
  /// Two things happen beyond the plain column write:
  ///
  /// * `version` is bumped by the statement itself (`version = version + 1`)
  ///   rather than by a value the caller sent. Read-modify-write in Dart would
  ///   let two devices that both read version 4 both write version 5, and the
  ///   counter would stop meaning anything; letting SQLite do the arithmetic
  ///   inside the same statement keeps it monotonic.
  /// * A recorded completion is not reassignable. The first person to finish a
  ///   goal owns that record - reopening is a state change with its own audit
  ///   entry, but silently swapping the name would rewrite the one fact the
  ///   whole feature exists to record.
  Future<void> saveGoal(QcGoal goal, {DatabaseExecutor? exec}) async {
    final id = goal.goalId;
    if (id == null) {
      throw StateError('Cannot save a QC goal with no id');
    }
    final txn = use(exec, await db);
    final existing = await txn.query(
      'qc_goals',
      columns: ['completed_by', 'completed_by_name'],
      where: 'goal_id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (existing.isEmpty) {
      throw StateError('No QC goal with id $id');
    }
    final recordedFinisher = '${existing.first['completed_by'] ?? ''}';
    if (recordedFinisher.isNotEmpty && goal.completedBy != recordedFinisher) {
      throw StateError(
        'QC goal $id was already completed by '
        '${existing.first['completed_by_name'] ?? recordedFinisher}; '
        'reopen it before recording a different finisher',
      );
    }
    final values = qcUpdatable(goal.toMap(withId: false), 'goal_id')
      // The bump is done by the statement, not by a number the caller sent.
      ..remove('version');
    final assignments = values.keys.map((key) => '$key = ?').join(', ');
    await txn.rawUpdate(
      'UPDATE qc_goals SET $assignments, version = version + 1 WHERE goal_id = ?',
      [...values.values, id],
    );
  }

  Future<void> deleteGoal(int goalId, {DatabaseExecutor? exec}) async {
    await use(exec, await db).update(
      'qc_goals',
      {'deleted_at': nowIso()},
      where: qcAlive('goal_id = ?'),
      whereArgs: [goalId],
    );
  }

  Future<List<QcGoalAssignment>> listAssignments(
    int goalId, {
    DatabaseExecutor? exec,
  }) async {
    final rows = await use(exec, await db).query(
      'qc_goal_assignments',
      where: qcAlive('goal_id = ?'),
      whereArgs: [goalId],
      orderBy: 'assigned_at ASC, assign_id ASC',
    );
    return qcDecode(rows, QcGoalAssignment.fromMap);
  }

  /// Assigns a person to a goal.
  ///
  /// The `UNIQUE(goal_id, assignee_id)` index is the real guard against double
  /// counting - re-assigning is an *update*, not a second row, so progress
  /// cannot count the same person twice.
  Future<void> assignGoal(
    QcGoalAssignment assignment, {
    DatabaseExecutor? exec,
  }) async {
    final txn = use(exec, await db);
    final existing = await txn.query(
      'qc_goal_assignments',
      where: 'goal_id = ? AND assignee_id = ?',
      whereArgs: [assignment.goalId, assignment.assigneeId],
      limit: 1,
    );
    if (existing.isNotEmpty) {
      await txn.update(
        'qc_goal_assignments',
        qcUpdatable(assignment.toMap(withId: false), 'assign_id'),
        where: 'assign_id = ?',
        whereArgs: [existing.first['assign_id']],
      );
      return;
    }
    await txn.insert(
      'qc_goal_assignments',
      qcInsertable(assignment.toMap(withId: false), 'assign_id'),
    );
  }

  Future<void> updateAssignment(
    QcGoalAssignment assignment, {
    DatabaseExecutor? exec,
  }) async {
    await use(exec, await db).update(
      'qc_goal_assignments',
      qcUpdatable(assignment.toMap(withId: false), 'assign_id'),
      where: 'assign_id = ?',
      whereArgs: [assignment.assignId],
    );
  }

  /// Unassigns by tombstone rather than `DELETE`, like every other removal here:
  /// the row is part of the goal's history and still has to replicate and audit.
  Future<void> removeAssignment(int assignId, {DatabaseExecutor? exec}) async {
    await use(exec, await db).update(
      'qc_goal_assignments',
      {'deleted_at': nowIso()},
      where: qcAlive('assign_id = ?'),
      whereArgs: [assignId],
    );
  }

  Future<List<QcGoalAction>> listActions(
    int goalId, {
    DatabaseExecutor? exec,
  }) async {
    final rows = await use(exec, await db).query(
      'qc_goal_actions',
      where: qcAlive('goal_id = ?'),
      whereArgs: [goalId],
      orderBy: 'due_date ASC, action_id ASC',
    );
    return qcDecode(rows, QcGoalAction.fromMap);
  }

  Future<int> addAction(QcGoalAction action, {DatabaseExecutor? exec}) async {
    return use(exec, await db).insert(
      'qc_goal_actions',
      qcInsertable(action.toMap(withId: false), 'action_id'),
    );
  }

  Future<void> saveAction(QcGoalAction action, {DatabaseExecutor? exec}) async {
    await use(exec, await db).update(
      'qc_goal_actions',
      qcUpdatable(action.toMap(withId: false), 'action_id'),
      where: 'action_id = ?',
      whereArgs: [action.actionId],
    );
  }

  /// A measured target on a goal. `target` is a number rather than free text so
  /// progress is a comparison, not a reading of a sentence.
  Future<int> addKpi(QcGoalKpi kpi, {DatabaseExecutor? exec}) async {
    return use(
      exec,
      await db,
    ).insert('qc_goal_kpis', qcInsertable(kpi.toMap(withId: false), 'kpi_id'));
  }

  Future<void> saveKpi(QcGoalKpi kpi, {DatabaseExecutor? exec}) async {
    await use(exec, await db).update(
      'qc_goal_kpis',
      qcUpdatable(kpi.toMap(withId: false), 'kpi_id'),
      where: 'kpi_id = ?',
      whereArgs: [kpi.kpiId],
    );
  }

  Future<void> deleteKpi(int kpiId, {DatabaseExecutor? exec}) async {
    await use(exec, await db).update(
      'qc_goal_kpis',
      {'deleted_at': nowIso()},
      where: qcAlive('kpi_id = ?'),
      whereArgs: [kpiId],
    );
  }

  Future<List<QcGoalKpi>> listKpis(int goalId, {DatabaseExecutor? exec}) async {
    final rows = await use(exec, await db).query(
      'qc_goal_kpis',
      where: qcAlive('goal_id = ?'),
      whereArgs: [goalId],
      orderBy: 'kpi_id ASC',
    );
    return qcDecode(rows, QcGoalKpi.fromMap);
  }

  /// Ties a goal to the SOP, NC, inspection or template it exists to serve.
  Future<int> addLink(QcGoalLink link, {DatabaseExecutor? exec}) async {
    return use(exec, await db).insert(
      'qc_goal_links',
      qcInsertable(link.toMap(withId: false), 'link_id'),
    );
  }

  Future<void> deleteLink(int linkId, {DatabaseExecutor? exec}) async {
    await use(exec, await db).update(
      'qc_goal_links',
      {'deleted_at': nowIso()},
      where: qcAlive('link_id = ?'),
      whereArgs: [linkId],
    );
  }

  /// Goal plus every child row, for the detail screen.
  ///
  /// One executor for all six reads so the summary counters and the rows they
  /// describe come from the same snapshot - a progress bar reading 3/5 next to a
  /// list of 4 actions is worse than a slightly stale total.
  Future<QcGoalBundle?> getGoalBundle(
    int goalId, {
    DatabaseExecutor? exec,
  }) async {
    final txn = use(exec, await db);
    final goal = await getGoal(goalId, exec: txn);
    if (goal == null) return null;

    Future<List<T>> child<T>(
      String table,
      T Function(Map<String, dynamic>) from,
    ) async => qcDecode(
      await txn.query(
        table,
        where: qcAlive('goal_id = ?'),
        whereArgs: [goalId],
      ),
      from,
    );

    return QcGoalBundle(
      goal: goal,
      assignments: await child('qc_goal_assignments', QcGoalAssignment.fromMap),
      actions: await child('qc_goal_actions', QcGoalAction.fromMap),
      kpis: await child('qc_goal_kpis', QcGoalKpi.fromMap),
      links: await child('qc_goal_links', QcGoalLink.fromMap),
    );
  }
}
