import 'dart:convert' as convert;

import 'package:equatable/equatable.dart';

import '../../../core/constants/app_strings.dart';

/// Column input types a user-authored table supports.
///
/// Deliberately narrow: three stable, syncable, filterable types. Column
/// `qc_items.item_type` carries many more, but those render whole widgets
/// (photos, signatures) whose identity cannot yet be reconciled across
/// devices by a pull, so custom tables keep to primitives until one of
/// them is demonstrably needed.
abstract final class QcCustomColType {
  static const String number = 'number';
  static const String text = 'text';
  static const String date = 'date';

  static const List<String> all = [number, text, date];

  static String label(String type) => switch (type) {
    number => AppText.t('رقم', 'Number'),
    text => AppText.t('نص', 'Text'),
    date => AppText.t('تاريخ', 'Date'),
    _ => type,
  };
}

/// A user-authored register (the "table" the settings gear creates).
///
/// No `code`: the chip's identity is its [title] and nothing else needs a
/// second identifier. Uniqueness of a title is enforced at the repository
/// level among alives rows, so soft-deleting a definition frees the title
/// without a schema constraint fighting the tombstone.
class QcCustomTable extends Equatable {
  final int? tableId;

  /// Cross-device identity, a UUID generated at creation. Empty on a model
  /// that has not been written yet.
  final String remoteId;
  final String title;
  final String description;

  /// Display position of the chip in the QC hub row (0-based, appended).
  final int sortOrder;
  final String deletedAt;
  final String createdAt;
  final String updatedAt;
  final String createdBy;
  final String updatedBy;

  /// Optimistic-concurrency counter; bumped by the sync write contract.
  final int version;

  const QcCustomTable({
    this.tableId,
    this.remoteId = '',
    required this.title,
    this.description = '',
    this.sortOrder = 0,
    this.deletedAt = '',
    required this.createdAt,
    required this.updatedAt,
    this.createdBy = '',
    this.updatedBy = '',
    this.version = 1,
  });

  bool get isDeleted => deletedAt.isNotEmpty;

  Map<String, dynamic> toMap({bool withId = true}) => {
    if (withId) 'table_id': tableId,
    'remote_id': remoteId,
    'title': title,
    'description': description.isEmpty ? null : description,
    'sort_order': sortOrder,
    'deleted_at': deletedAt.isEmpty ? null : deletedAt,
    'created_at': createdAt,
    'updated_at': updatedAt,
    'created_by': createdBy.isEmpty ? null : createdBy,
    'updated_by': updatedBy.isEmpty ? null : updatedBy,
    'version': version,
  };

  static QcCustomTable fromMap(Map<String, dynamic> map) => QcCustomTable(
    tableId: (map['table_id'] as num?)?.toInt(),
    remoteId: '${map['remote_id'] ?? ''}',
    title: '${map['title'] ?? ''}',
    description: '${map['description'] ?? ''}',
    sortOrder: (map['sort_order'] as num?)?.toInt() ?? 0,
    deletedAt: '${map['deleted_at'] ?? ''}',
    createdAt: '${map['created_at'] ?? ''}',
    updatedAt: '${map['updated_at'] ?? ''}',
    createdBy: '${map['created_by'] ?? ''}',
    updatedBy: '${map['updated_by'] ?? ''}',
    version: (map['version'] as num?)?.toInt() ?? 1,
  );

  @override
  List<Object?> get props => [
    tableId,
    remoteId,
    title,
    description,
    sortOrder,
    deletedAt,
    createdAt,
    updatedAt,
    createdBy,
    updatedBy,
    version,
  ];
}

/// One typed column of a user-authored table.
///
/// `table_remote_id` is written at creation so a pulled field can be re-
/// attached to the right table on a different device; `values_json` on the
/// rows side is keyed by [remoteId], which means [label] is free to change
/// and even a full re-create orphaning the values is detectable.
class QcCustomTableField extends Equatable {
  final int? fieldId;
  final int? tableId;
  final String tableRemoteId;

  /// Cross-device identity (UUID, generated at creation). [values_json]
  /// keys on the row side point at it.
  final String remoteId;
  final String label;
  final String colType;
  final bool required;
  final int sortOrder;
  final String deletedAt;
  final String createdAt;
  final String updatedAt;
  final String createdBy;
  final String updatedBy;
  final int version;

  const QcCustomTableField({
    this.fieldId,
    this.tableId,
    this.tableRemoteId = '',
    this.remoteId = '',
    required this.label,
    required this.colType,
    this.required = false,
    this.sortOrder = 0,
    this.deletedAt = '',
    required this.createdAt,
    required this.updatedAt,
    this.createdBy = '',
    this.updatedBy = '',
    this.version = 1,
  });

  bool get isDeleted => deletedAt.isNotEmpty;

  Map<String, dynamic> toMap({bool withId = true}) => {
    if (withId) 'field_id': fieldId,
    'table_id': tableId,
    'table_remote_id': tableRemoteId,
    'remote_id': remoteId,
    'label': label,
    'col_type': colType,
    'required': required ? 1 : 0,
    'sort_order': sortOrder,
    'deleted_at': deletedAt.isEmpty ? null : deletedAt,
    'created_at': createdAt,
    'updated_at': updatedAt,
    'created_by': createdBy.isEmpty ? null : createdBy,
    'updated_by': updatedBy.isEmpty ? null : updatedBy,
    'version': version,
  };

  static QcCustomTableField fromMap(Map<String, dynamic> map) =>
      QcCustomTableField(
        fieldId: (map['field_id'] as num?)?.toInt(),
        tableId: (map['table_id'] as num?)?.toInt(),
        tableRemoteId: '${map['table_remote_id'] ?? ''}',
        remoteId: '${map['remote_id'] ?? ''}',
        label: '${map['label'] ?? ''}',
        colType: '${map['col_type'] ?? QcCustomColType.text}',
        required: (map['required'] as num?)?.toInt() != 0,
        sortOrder: (map['sort_order'] as num?)?.toInt() ?? 0,
        deletedAt: '${map['deleted_at'] ?? ''}',
        createdAt: '${map['created_at'] ?? ''}',
        updatedAt: '${map['updated_at'] ?? ''}',
        createdBy: '${map['created_by'] ?? ''}',
        updatedBy: '${map['updated_by'] ?? ''}',
        version: (map['version'] as num?)?.toInt() ?? 1,
      );

  QcCustomTableField copyWith({
    int? fieldId,
    int? tableId,
    String? tableRemoteId,
    String? remoteId,
    String? label,
    String? colType,
    bool? required,
    int? sortOrder,
    String? deletedAt,
    String? createdAt,
    String? updatedAt,
    String? createdBy,
    String? updatedBy,
    int? version,
  }) => QcCustomTableField(
    fieldId: fieldId ?? this.fieldId,
    tableId: tableId ?? this.tableId,
    tableRemoteId: tableRemoteId ?? this.tableRemoteId,
    remoteId: remoteId ?? this.remoteId,
    label: label ?? this.label,
    colType: colType ?? this.colType,
    required: required ?? this.required,
    sortOrder: sortOrder ?? this.sortOrder,
    deletedAt: deletedAt ?? this.deletedAt,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    createdBy: createdBy ?? this.createdBy,
    updatedBy: updatedBy ?? this.updatedBy,
    version: version ?? this.version,
  );

  @override
  List<Object?> get props => [
    fieldId,
    tableId,
    tableRemoteId,
    remoteId,
    label,
    colType,
    required,
    sortOrder,
    deletedAt,
    createdAt,
    updatedAt,
    createdBy,
    updatedBy,
    version,
  ];
}

/// One record written into a user-authored table.
///
/// [values] is the decoded form of `values_json`: keys are the column
/// `remote_id`s (device-independent), values are typed per column —
/// number fields hold a `num`, text fields a `String`, date fields an
/// ISO-8601 `String`. A value whose column was soft-deleted keeps its key:
/// the history must survive the schema the user later renamed.
class QcCustomTableRow extends Equatable {
  final int? rowId;
  final int? tableId;
  final String tableRemoteId;

  /// Cross-device identity of this record (UUID, stamped by the facade at
  /// creation): the tombstone doc id and the pull's `remote_id` lookup both
  /// resolve through it. Without round-tripping it, `toMap` writes no
  /// `remote_id` and every enqueue would mint a brand-new identity —
  /// pushes that match nothing remote.
  final String remoteId;

  /// JSON snapshot of [values], exactly what is stored in `values_json`.
  final String valuesJson;
  final String note;

  /// When the row was recorded and who did it.
  final String recordedAt;
  final String recordedBy;
  final String recordedByName;
  final String deletedAt;
  final String createdAt;
  final String updatedAt;
  final String createdBy;
  final String updatedBy;
  final int version;

  const QcCustomTableRow({
    this.rowId,
    this.tableId,
    this.tableRemoteId = '',
    this.remoteId = '',
    this.valuesJson = '{}',
    this.note = '',
    required this.recordedAt,
    this.recordedBy = '',
    this.recordedByName = '',
    this.deletedAt = '',
    required this.createdAt,
    required this.updatedAt,
    this.createdBy = '',
    this.updatedBy = '',
    this.version = 1,
  });

  static Map<String, dynamic> _decode(String json) {
    if (json.trim().isEmpty || json.trim() == 'null') return const {};
    final decoded = convert.jsonDecode(json);
    return decoded is Map<String, dynamic> ? decoded : const {};
  }

  Map<String, dynamic> get values => _decode(valuesJson);

  bool get isDeleted => deletedAt.isNotEmpty;

  Map<String, dynamic> toMap({bool withId = true}) => {
    if (withId) 'row_id': rowId,
    'table_id': tableId,
    'table_remote_id': tableRemoteId,
    'remote_id': remoteId,
    'values_json': valuesJson.isEmpty ? '{}' : valuesJson,
    'note': note,
    'recorded_at': recordedAt,
    'recorded_by': recordedBy.isEmpty ? null : recordedBy,
    'recorded_by_name': recordedByName,
    'deleted_at': deletedAt.isEmpty ? null : deletedAt,
    'created_at': createdAt,
    'updated_at': updatedAt,
    'created_by': createdBy.isEmpty ? null : createdBy,
    'updated_by': updatedBy.isEmpty ? null : updatedBy,
    'version': version,
  };

  static QcCustomTableRow fromMap(Map<String, dynamic> map) => QcCustomTableRow(
    rowId: (map['row_id'] as num?)?.toInt(),
    tableId: (map['table_id'] as num?)?.toInt(),
    tableRemoteId: '${map['table_remote_id'] ?? ''}',
    remoteId: '${map['remote_id'] ?? ''}',
    valuesJson: '${map['values_json'] ?? '{}'}',
    note: '${map['note'] ?? ''}',
    recordedAt: '${map['recorded_at'] ?? ''}',
    recordedBy: '${map['recorded_by'] ?? ''}',
    recordedByName: '${map['recorded_by_name'] ?? ''}',
    deletedAt: '${map['deleted_at'] ?? ''}',
    createdAt: '${map['created_at'] ?? ''}',
    updatedAt: '${map['updated_at'] ?? ''}',
    createdBy: '${map['created_by'] ?? ''}',
    updatedBy: '${map['updated_by'] ?? ''}',
    version: (map['version'] as num?)?.toInt() ?? 1,
  );

  QcCustomTableRow copyWith({
    int? rowId,
    int? tableId,
    String? tableRemoteId,
    String? remoteId,
    String? valuesJson,
    String? note,
    String? recordedAt,
    String? recordedBy,
    String? recordedByName,
    String? deletedAt,
    String? createdAt,
    String? updatedAt,
    String? createdBy,
    String? updatedBy,
    int? version,
  }) => QcCustomTableRow(
    rowId: rowId ?? this.rowId,
    tableId: tableId ?? this.tableId,
    tableRemoteId: tableRemoteId ?? this.tableRemoteId,
    remoteId: remoteId ?? this.remoteId,
    valuesJson: valuesJson ?? this.valuesJson,
    note: note ?? this.note,
    recordedAt: recordedAt ?? this.recordedAt,
    recordedBy: recordedBy ?? this.recordedBy,
    recordedByName: recordedByName ?? this.recordedByName,
    deletedAt: deletedAt ?? this.deletedAt,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    createdBy: createdBy ?? this.createdBy,
    updatedBy: updatedBy ?? this.updatedBy,
    version: version ?? this.version,
  );

  @override
  List<Object?> get props => [
    rowId,
    tableId,
    tableRemoteId,
    remoteId,
    valuesJson,
    note,
    recordedAt,
    recordedBy,
    recordedByName,
    deletedAt,
    createdAt,
    updatedAt,
    createdBy,
    updatedBy,
    version,
  ];
}
