import 'package:equatable/equatable.dart';

/// Filter set for the NCR report (plan V6_ENHANCED §22.4).
///
/// Every field is a *set*, not a single value: the plan calls for multi-select
/// on status/severity/type/category, and a `status = ?` filter would force the
/// auditor to run the query once per status to answer "show me everything open
/// or overdue" - which is the question they actually have.
///
/// Empty string means "no filter". An empty set also means "no filter", so the
/// two are interchangeable to callers and only one of them has to be reasoned
/// about.
class NcrFilters extends Equatable {
  const NcrFilters({
    this.statuses = const {},
    this.severities = const {},
    this.types = const {},
    this.categories = const {},
    this.depts = const {},
    this.inspectorIds = const {},
    this.assignedTo = const {},
    this.capaStatuses = const {},
    this.lotNo = '',
    this.batchNo = '',
    this.poNo = '',
    this.refType = '',
    this.refId = '',
    this.from = '',
    this.to = '',
    this.dateField = NcrDateField.createdAt,
    this.onlyOverdue = false,
    this.limit = 200,
    this.offset = 0,
  });

  /// The plan defaults the range to the last 30 days (§22.4). Left to the
  /// caller rather than baked in as a default value so that "no range" stays
  /// expressible - a factory would silently cap a full-history export.
  factory NcrFilters.last30Days() {
    final now = DateTime.now();
    return NcrFilters(
      from: _day(now.subtract(const Duration(days: 30))),
      to: _day(now),
    );
  }

  /// Everything, no date cap. Used by exports and by "clear filters".
  factory NcrFilters.all() => const NcrFilters(limit: 5000);

  final Set<String> statuses;
  final Set<String> severities;
  final Set<String> types;
  final Set<String> categories;
  final Set<String> depts;
  final Set<String> inspectorIds;
  final Set<String> assignedTo;
  final Set<String> capaStatuses;
  final String lotNo;
  final String batchNo;
  final String poNo;
  final String refType;
  final String refId;

  /// Inclusive `yyyy-MM-dd` bounds, matched against [dateField].
  final String from;
  final String to;
  final String dateField;

  /// Only findings past their due date and still unresolved.
  final bool onlyOverdue;

  final int limit;
  final int offset;

  /// Which timestamp the range applies to.
  static const String dateFieldCreated = 'created_at';
  static const String dateFieldInspection = 'inspection_date';
  static const String dateFieldClosed = 'closed_at';

  static const List<String> dateFields = [
    dateFieldCreated,
    dateFieldInspection,
    dateFieldClosed,
  ];

  /// A filter that would exclude nothing, so the UI can offer a real "reset".
  ///
  /// [onlyOverdue] counts: "open critical only" is still a filter even though
  /// every set is empty.
  bool get isEmpty =>
      statuses.isEmpty &&
      severities.isEmpty &&
      types.isEmpty &&
      categories.isEmpty &&
      depts.isEmpty &&
      inspectorIds.isEmpty &&
      assignedTo.isEmpty &&
      capaStatuses.isEmpty &&
      lotNo.isEmpty &&
      batchNo.isEmpty &&
      poNo.isEmpty &&
      refType.isEmpty &&
      refId.isEmpty &&
      from.isEmpty &&
      to.isEmpty &&
      !onlyOverdue;

  bool get hasDateRange => from.isNotEmpty || to.isNotEmpty;

  /// A one-line description for the PDF/Excel header (§22.7 asks the export to
  /// state the filters it ran under - an export whose scope cannot be
  /// reconstructed is not evidence of anything).
  String get describe {
    if (isEmpty) return 'All non-conformances (no filter)';
    final parts = <String>[];
    void add(String label, Object value) {
      if (value.toString().isNotEmpty) parts.add('$label: $value');
    }

    add('status', statuses.join('/'));
    add('severity', severities.join('/'));
    add('type', types.join('/'));
    add('category', categories.join('/'));
    add('dept', depts.join('/'));
    add('inspector', inspectorIds.join('/'));
    add('assigned to', assignedTo.join('/'));
    add('capa status', capaStatuses.join('/'));
    add('lot', lotNo);
    add('batch', batchNo);
    add('PO', poNo);
    add('ref type', refType);
    add('ref id', refId);
    if (hasDateRange) {
      add(dateField, '${from.isEmpty ? '…' : from}..${to.isEmpty ? '…' : to}');
    }
    if (onlyOverdue) parts.add('overdue only');
    return parts.join(', ');
  }

  /// Any change resets paging: staying on page 4 of a result that now has one
  /// page shows an empty table and reads as "no data".
  NcrFilters copyWith({
    Set<String>? statuses,
    Set<String>? severities,
    Set<String>? types,
    Set<String>? categories,
    Set<String>? depts,
    Set<String>? inspectorIds,
    Set<String>? assignedTo,
    Set<String>? capaStatuses,
    String? lotNo,
    String? batchNo,
    String? poNo,
    String? refType,
    String? refId,
    String? from,
    String? to,
    String? dateField,
    bool? onlyOverdue,
    int? limit,
    int? offset,
  }) => NcrFilters(
    statuses: statuses ?? this.statuses,
    severities: severities ?? this.severities,
    types: types ?? this.types,
    categories: categories ?? this.categories,
    depts: depts ?? this.depts,
    inspectorIds: inspectorIds ?? this.inspectorIds,
    assignedTo: assignedTo ?? this.assignedTo,
    capaStatuses: capaStatuses ?? this.capaStatuses,
    lotNo: lotNo ?? this.lotNo,
    batchNo: batchNo ?? this.batchNo,
    poNo: poNo ?? this.poNo,
    refType: refType ?? this.refType,
    refId: refId ?? this.refId,
    from: from ?? this.from,
    to: to ?? this.to,
    dateField: dateField ?? this.dateField,
    onlyOverdue: onlyOverdue ?? this.onlyOverdue,
    limit: limit ?? this.limit,
    offset: offset ?? 0,
  );

  /// Adds [value] to [current], or removes it when it is already there.
  ///
  /// Returns a new set rather than mutating: filter values live in an
  /// `Equatable` state, so in-place mutation would make `==` report "nothing
  /// changed" and the cubit would skip the reload.
  static Set<String> toggled(Set<String> current, String value) {
    final next = Set<String>.from(current);
    if (!next.remove(value)) next.add(value);
    return next;
  }

  @override
  List<Object?> get props => [
    statuses,
    severities,
    types,
    categories,
    depts,
    inspectorIds,
    assignedTo,
    capaStatuses,
    lotNo,
    batchNo,
    poNo,
    refType,
    refId,
    from,
    to,
    dateField,
    onlyOverdue,
    limit,
    offset,
  ];
}

/// Alias kept as a named constant so call sites read as intent, not as a raw
/// column name.
abstract final class NcrDateField {
  static const String createdAt = NcrFilters.dateFieldCreated;
  static const String inspectionDate = NcrFilters.dateFieldInspection;
  static const String closedAt = NcrFilters.dateFieldClosed;
}

String _day(DateTime when) =>
    '${when.year.toString().padLeft(4, '0')}-'
    '${when.month.toString().padLeft(2, '0')}-'
    '${when.day.toString().padLeft(2, '0')}';
