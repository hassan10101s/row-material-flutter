import 'qc_enums.dart';
import 'qc_inspection.dart';
import 'qc_template.dart';

/// Domain models and the repository contract for the simple daily/monthly
/// routine lists (QC checklists without versions, publishing or archiving).
///
/// Implementation: `data/routine_lists_repository.dart`
/// (`RoutineListsRepositoryImpl`), which owns the SQL, the write guard and
/// the audit bookkeeping. The presentation layer (cubits + screens under
/// `presentation/routine/`) depends on this contract only.

/// One routine list (a daily/monthly checklist without versions, publishing
/// or archiving) plus its progress in the current period.
class RoutineList {
  const RoutineList({
    required this.template,
    required this.totalItems,
    required this.doneCount,
    required this.sheetId,
  });

  final QcTemplate template;
  final int totalItems;
  final int doneCount;

  /// This period's sheet id, or null when it has not been opened yet.
  final int? sheetId;

  bool get isMonthly => template.recurrence == QcRecurrence.monthly;
  bool get isComplete => totalItems > 0 && doneCount >= totalItems;
}

/// One answered-or-blank row on a routine sheet.
class RoutineRow {
  const RoutineRow({
    required this.item,
    required this.response,
    this.taskLogCount = 0,
    this.lastTaskLogAt = '',
    this.lastTaskLogByName = '',
  });

  final QcItem item;
  final QcResponse response;

  bool get recorded => response.isRecorded;

  /// How many times the per-task "done" button logged this item in this
  /// period (the checkbox stamps one row; the log appends every press).
  final int taskLogCount;

  /// Newest log entry of the row: `yyyy-MM-dd HH:mm:ss[.ms]` and the actor.
  final String lastTaskLogAt;
  final String lastTaskLogByName;

  bool get hasTaskLogs => taskLogCount > 0;

  /// `yyyy-MM-dd HH:mm` of [lastTaskLogAt], or '' when never logged.
  String get lastTaskLogStamp {
    final at = lastTaskLogAt;
    return at.length >= 16 ? at.substring(0, 16) : at;
  }
}

/// One logged completion: a press of the per-task done button. Append-only —
/// unlike [QcResponse] (one row per item per period, overwritten by
/// re-checking), every entry stays: hour + user (answers "each day the task
/// was completed, when and by whom").
class QcTaskLog {
  const QcTaskLog({
    required this.logId,
    required this.inspectionId,
    required this.templateId,
    required this.itemId,
    required this.note,
    required this.loggedBy,
    required this.loggedByName,
    required this.loggedAt,
  });

  final int logId;
  final int inspectionId;
  final int templateId;
  final int itemId;
  final String note;
  final String loggedBy;
  final String loggedByName;
  final String loggedAt;

  static QcTaskLog fromMap(Map<String, dynamic> m) => QcTaskLog(
    logId: (m['log_id'] as num).toInt(),
    inspectionId: (m['inspection_id'] as num).toInt(),
    templateId: (m['template_id'] as num).toInt(),
    itemId: (m['item_id'] as num).toInt(),
    note: '${m['note'] ?? ''}',
    loggedBy: '${m['logged_by'] ?? ''}',
    loggedByName: '${m['logged_by_name'] ?? ''}',
    loggedAt: '${m['logged_at'] ?? ''}',
  );

  /// `yyyy-MM-dd HH:mm` of [loggedAt].
  String get stamp =>
      loggedAt.length >= 16 ? loggedAt.substring(0, 16) : loggedAt;
}

/// A routine sheet: the list, its period and every row.
class RoutineSheet {
  const RoutineSheet({
    required this.inspection,
    required this.template,
    required this.rows,
    required this.current,
  });

  final QcInspection inspection;
  final QcTemplate template;
  final List<RoutineRow> rows;

  /// False for past periods: the sheet is read-only history.
  final bool current;

  int get doneCount => rows.where((r) => r.recorded).length;
  bool get isComplete => rows.isNotEmpty && doneCount == rows.length;
}

/// One history entry: a past (or current) sheet with its scorecard.
class RoutineHistoryEntry {
  const RoutineHistoryEntry({
    required this.inspection,
    required this.templateName,
    required this.recurrence,
    required this.totalCount,
    required this.doneCount,
    required this.people,
  });

  final QcInspection inspection;
  final String templateName;
  final String recurrence;
  final int totalCount;
  final int doneCount;
  final List<String> people;

  bool get isComplete => totalCount > 0 && doneCount >= totalCount;
}

/// One completed item, flat across every list and period — the row of a
/// general "everything done" log (newest first): when, on which list, which
/// item, who and any note. Sourced from recorded `qc_responses` rows
/// (checkbox stamps *and* the per-task done button, which also stamps its
/// response for the period).
class RoutineDoneLog {
  const RoutineDoneLog({
    required this.at,
    required this.templateName,
    required this.itemLabel,
    required this.byName,
    required this.note,
    this.templateId,
    this.inspectionId,
  });

  /// Recorded stamp of the completion, `yyyy-MM-dd HH:mm:ss...`.
  final String at;

  final String templateName;
  final String itemLabel;
  final String byName;
  final String note;

  /// For drill-down (open the sheet) when the query can carry them.
  final int? templateId;
  final int? inspectionId;

  static RoutineDoneLog fromMap(Map<String, dynamic> m) => RoutineDoneLog(
    at: '${m['at'] ?? ''}',
    templateName: '${m['template_name'] ?? '-'}',
    itemLabel: '${m['item_label'] ?? ''}',
    byName: '${m['by_name'] ?? ''}',
    note: '${m['note'] ?? ''}',
    templateId: (m['template_id'] as num?)?.toInt(),
    inspectionId: (m['inspection_id'] as num?)?.toInt(),
  );

  /// `yyyy-MM-dd HH:mm` of [at].
  String get stamp => at.length >= 16 ? at.substring(0, 16) : at;
}

/// Advanced history filters. Every field is optional; empty means "all".
class RoutineHistoryFilters {
  const RoutineHistoryFilters({
    this.templateId,
    this.from,
    this.to,
    this.person = '',
    this.completion = '',
    this.itemQuery = '',
    this.limit = 100,
    this.offset = 0,
  });

  final int? templateId;

  /// Bare `yyyy-MM-dd` bounds (inclusive) on the sheet date.
  final String? from;
  final String? to;

  /// Matches `answered_by` or a substring of `answered_by_name`.
  final String person;

  /// '' | 'complete' | 'incomplete'.
  final String completion;

  /// Substring of the checked item's label.
  final String itemQuery;

  final int limit;
  final int offset;

  RoutineHistoryFilters copyWith({
    int? templateId,
    String? from,
    String? to,
    String? person,
    String? completion,
    String? itemQuery,
    int? limit,
    int? offset,
  }) =>
      RoutineHistoryFilters(
        templateId: templateId ?? this.templateId,
        from: from ?? this.from,
        to: to ?? this.to,
        person: person ?? this.person,
        completion: completion ?? this.completion,
        itemQuery: itemQuery ?? this.itemQuery,
        limit: limit ?? this.limit,
        offset: offset ?? this.offset,
      );
}

/// Simple daily/monthly routine lists over the existing QC checklist tables.
///
/// What is intentionally gone compared with the old template flow: versions,
/// publish/approve/archive lifecycles, scoring and NC generation. A list is
/// edited in place; opening it resolves this period's sheet (auto-created);
/// checking a box stamps who did it; past periods are immutable history.
///
/// QC stays offline-local (no `sync_queue` rows): see the note on the
/// offline-first QC facades about why QC never enqueues.
abstract class RoutineListsRepository {
  /// Every non-deleted list with its progress in the current period.
  /// Templates on `once`/`weekly` behave as daily (period = day).
  Future<List<RoutineList>> listRoutineLists();

  /// Creates a list (published from birth: no draft/publish lifecycle) or
  /// edits one in place (name/dept/recurrence/items). Items are a flat
  /// ordered label list; they live under one implicit section.
  Future<int> saveRoutineList({
    int? templateId,
    required String name,
    String dept = '',
    String recurrence = QcRecurrence.daily,
    List<String> items = const [],
  });

  /// Labels of a list's live items, display order. Used by the editor so
  /// opening it never creates a sheet as a side effect.
  Future<List<String>> listItemLabels(int templateId);

  Future<void> deleteRoutineList(int templateId);

  /// Opens this period's sheet, creating it (with blank rows) on first use.
  /// Tomorrow — or next month — a fresh sheet is created instead, so the
  /// list "resets" by itself and the old sheet becomes history.
  Future<RoutineSheet> openPeriodSheet(int templateId);

  /// Loads any sheet by id (current period or history).
  Future<RoutineSheet> loadSheet(int inspectionId);

  /// Taps a checkbox: an unchecked row records Pass + who/when (and an
  /// optional note); a checked row in the *current* period unchecks back to
  /// blank. Past periods throw: history is immutable.
  Future<RoutineSheet> toggleCheck({
    required int inspectionId,
    required int itemId,
    String note = '',
  });

  /// Presses the per-task "done" button: appends one `qc_task_log` entry
  /// (this moment + who) and — for scorecard consistency — also marks the
  /// checkbox row done for this period with the same stamp.
  Future<RoutineSheet> recordDone({
    required int inspectionId,
    required int itemId,
    String note = '',
  });

  /// Every logged completion of [itemId] (all items when null) on the sheet,
  /// newest first — what the log dialog shows.
  Future<List<QcTaskLog>> taskLogs(int inspectionId, {int? itemId});

  /// Past and current sheets with scorecards, newest first.
  Future<List<RoutineHistoryEntry>> sheetHistory([
    RoutineHistoryFilters filters = const RoutineHistoryFilters(),
  ]);

  /// The general "everything done" log: one flat row per completed item
  /// across all lists and periods, newest first. The `from`/`to` bounds of
  /// [RoutineHistoryFilters] apply to the completion stamp itself, so
  /// defaulting the range to today (or the current month) keeps the freshest
  /// activity first without loading the whole archive.
  Future<List<RoutineDoneLog>> doneLog([
    RoutineHistoryFilters filters = const RoutineHistoryFilters(),
  ]);
}
