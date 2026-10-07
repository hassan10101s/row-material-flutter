import 'package:equatable/equatable.dart';

import '../../../core/utils/app_format.dart';
import 'qc_enums.dart';

/// A reusable checklist template (features/qc_manager/domain).
///
/// Editing a published template never mutates it: the repository copies it into
/// a fresh draft at `version + 1`. [version] is therefore part of the identity
/// of an inspection - [QcInspection.templateVersion] records which revision of
/// the template a sheet was actually filled against.
class QcTemplate extends Equatable {
  final int? templateId;
  final String name;
  final String code;
  final String type;
  final String dept;
  final String site;
  final String category;
  final String description;
  final int version;
  final bool isPublished;
  final bool isArchived;
  final String deletedAt;

  final bool requiresApprovalOnSubmit;
  final bool allowNa;
  final bool enforceEvidenceOnFail;

  /// Blocks submission outright while any critical item is failing.
  final bool blockSubmitIfCriticalFail;
  final String ownerId;
  final String publishedBy;
  final String publishedAt;
  final String effectiveDate;
  final String expiryDate;
  final String tags;
  final String createdAt;
  final String updatedAt;
  final String createdBy;
  final String updatedBy;

  /// Why this version differs from the last - mandatory on a published change.
  final String revisionNote;

  /// Simplified periodic tasks (plan §3): 'once' | 'daily' | 'weekly' | 'monthly'.
  /// 'once' = quality checklist on a shipment; others = recurring task list.
  final String recurrence;

  const QcTemplate({
    this.templateId,
    required this.name,
    this.code = '',
    this.type = QcTemplateType.other,
    this.dept = '',
    this.site = '',
    this.category = '',
    this.description = '',
    this.version = 1,
    this.isPublished = false,
    this.isArchived = false,
    this.deletedAt = '',
    this.requiresApprovalOnSubmit = false,
    this.allowNa = true,
    this.enforceEvidenceOnFail = true,
    this.blockSubmitIfCriticalFail = true,
    this.ownerId = '',
    this.publishedBy = '',
    this.publishedAt = '',
    this.effectiveDate = '',
    this.expiryDate = '',
    this.tags = '',
    required this.createdAt,
    required this.updatedAt,
    this.createdBy = '',
    this.updatedBy = '',
    this.revisionNote = '',
    this.recurrence = QcRecurrence.once,
  });

  bool get isDeleted => deletedAt.isNotEmpty;

  /// Selectable for a new inspection: published, not archived, in date.
  bool get isAvailable =>
      isPublished && !isArchived && !isDeleted && !isExpired;

  bool get isExpired => qcIsPastDue(expiryDate);

  bool get isEffectiveNow => qcIsEffectiveFrom(effectiveDate);

  /// Periodic task list vs one-off quality checklist.
  bool get isPeriodic => QcRecurrence.isPeriodic(recurrence);
  bool get isOneShot => !isPeriodic;

  List<String> get tagList => _splitTags(tags);

  @override
  List<Object?> get props => [
    templateId,
    name,
    code,
    type,
    dept,
    site,
    category,
    description,
    version,
    isPublished,
    isArchived,
    deletedAt,
    requiresApprovalOnSubmit,
    allowNa,
    enforceEvidenceOnFail,
    blockSubmitIfCriticalFail,
    ownerId,
    publishedBy,
    publishedAt,
    effectiveDate,
    expiryDate,
    tags,
    createdAt,
    updatedAt,
    createdBy,
    updatedBy,
    revisionNote,
    recurrence,
  ];

  factory QcTemplate.fromMap(Map<String, dynamic> m) => QcTemplate(
    templateId: (m['template_id'] as num?)?.toInt(),
    name: '${m['name'] ?? ''}',
    code: '${m['code'] ?? ''}',
    type: QcTemplateType.normalize('${m['type'] ?? ''}'),
    dept: '${m['dept'] ?? ''}',
    site: '${m['site'] ?? ''}',
    category: '${m['category'] ?? ''}',
    description: '${m['description'] ?? ''}',
    version: (m['version'] as num?)?.toInt() ?? 1,
    isPublished: (m['is_published'] as num?)?.toInt() == 1,
    isArchived: (m['is_archived'] as num?)?.toInt() == 1,
    deletedAt: '${m['deleted_at'] ?? ''}',
    requiresApprovalOnSubmit:
        (m['requires_approval_on_submit'] as num?)?.toInt() == 1,
    allowNa: (m['allow_na'] as num?)?.toInt() != 0,
    enforceEvidenceOnFail:
        (m['enforce_evidence_on_fail'] as num?)?.toInt() != 0,
    blockSubmitIfCriticalFail:
        (m['block_submit_if_critical_fail'] as num?)?.toInt() != 0,
    ownerId: '${m['owner_id'] ?? ''}',
    publishedBy: '${m['published_by'] ?? ''}',
    publishedAt: '${m['published_at'] ?? ''}',
    effectiveDate: '${m['effective_date'] ?? ''}',
    expiryDate: '${m['expiry_date'] ?? ''}',
    tags: '${m['tags'] ?? ''}',
    createdAt: '${m['created_at'] ?? ''}',
    updatedAt: '${m['updated_at'] ?? ''}',
    createdBy: '${m['created_by'] ?? ''}',
    updatedBy: '${m['updated_by'] ?? ''}',
    revisionNote: '${m['revision_note'] ?? ''}',
    recurrence: QcRecurrence.normalize('${m['recurrence'] ?? 'once'}'),
  );

  Map<String, dynamic> toMap({bool withId = true}) => {
    if (withId && templateId != null) 'template_id': templateId,
    'name': name,
    'code': code,
    'type': type,
    'dept': dept,
    'site': site,
    'category': category,
    'description': description,
    'version': version,
    'is_published': isPublished ? 1 : 0,
    'is_archived': isArchived ? 1 : 0,
    if (deletedAt.isNotEmpty) 'deleted_at': deletedAt,
    'requires_approval_on_submit': requiresApprovalOnSubmit ? 1 : 0,
    'allow_na': allowNa ? 1 : 0,
    'enforce_evidence_on_fail': enforceEvidenceOnFail ? 1 : 0,
    'block_submit_if_critical_fail': blockSubmitIfCriticalFail ? 1 : 0,
    'owner_id': ownerId,
    'published_by': publishedBy,
    'published_at': publishedAt,
    'effective_date': effectiveDate,
    'expiry_date': expiryDate,
    'tags': tags,
    'created_at': createdAt,
    'updated_at': updatedAt,
    'created_by': createdBy,
    'updated_by': updatedBy,
    'revision_note': revisionNote,
    'recurrence': recurrence,
  };

  /// The copy that becomes a new draft version, carrying the structure across
  /// but dropping the published state so it cannot be re-published unreviewed.
  QcTemplate asDraftVersion({String? note}) => QcTemplate(
    templateId: templateId,
    name: name,
    code: code,
    type: type,
    dept: dept,
    site: site,
    category: category,
    description: description,
    version: version + 1,
    isPublished: false,
    isArchived: false,
    requiresApprovalOnSubmit: requiresApprovalOnSubmit,
    allowNa: allowNa,
    enforceEvidenceOnFail: enforceEvidenceOnFail,
    blockSubmitIfCriticalFail: blockSubmitIfCriticalFail,
    ownerId: ownerId,
    effectiveDate: effectiveDate,
    expiryDate: expiryDate,
    tags: tags,
    createdAt: createdAt,
    updatedAt: updatedAt,
    createdBy: createdBy,
    updatedBy: updatedBy,
    revisionNote: note ?? revisionNote,
    recurrence: recurrence,
  );
}

extension QcTemplateRecurrenceX on QcTemplate {
  QcTemplate copyWithRecurrence({String? recurrence}) => QcTemplate(
    templateId: templateId,
    name: name,
    code: code,
    type: type,
    dept: dept,
    site: site,
    category: category,
    description: description,
    version: version,
    isPublished: isPublished,
    isArchived: isArchived,
    deletedAt: deletedAt,
    requiresApprovalOnSubmit: requiresApprovalOnSubmit,
    allowNa: allowNa,
    enforceEvidenceOnFail: enforceEvidenceOnFail,
    blockSubmitIfCriticalFail: blockSubmitIfCriticalFail,
    ownerId: ownerId,
    publishedBy: publishedBy,
    publishedAt: publishedAt,
    effectiveDate: effectiveDate,
    expiryDate: expiryDate,
    tags: tags,
    createdAt: createdAt,
    updatedAt: updatedAt,
    createdBy: createdBy,
    updatedBy: updatedBy,
    revisionNote: revisionNote,
    recurrence: recurrence ?? this.recurrence,
  );
}

/// A grouping of items inside a template.
class QcSection extends Equatable {
  final int? sectionId;
  final int templateId;
  final String title;
  final String description;
  final int orderIndex;
  final bool isCollapsible;

  /// When true every item in the section must be answered.
  final bool requiredAll;

  /// JSON predicate deciding whether the section applies at all.
  final String conditionalRuleJson;

  /// Set when a template edit retires this section. It stays on disk because an
  /// inspection performed last quarter still points at its items.
  final String deletedAt;

  bool get isDeleted => deletedAt.isNotEmpty;

  const QcSection({
    this.sectionId,
    required this.templateId,
    required this.title,
    this.description = '',
    this.orderIndex = 0,
    this.isCollapsible = true,
    this.requiredAll = false,
    this.conditionalRuleJson = '',
    this.deletedAt = '',
  });

  @override
  List<Object?> get props => [
    sectionId,
    templateId,
    title,
    description,
    orderIndex,
    isCollapsible,
    requiredAll,
    conditionalRuleJson,
    deletedAt,
  ];

  factory QcSection.fromMap(Map<String, dynamic> m) => QcSection(
    sectionId: (m['section_id'] as num?)?.toInt(),
    templateId: (m['template_id'] as num?)?.toInt() ?? 0,
    title: '${m['title'] ?? ''}',
    description: '${m['description'] ?? ''}',
    orderIndex: (m['order_index'] as num?)?.toInt() ?? 0,
    isCollapsible: (m['is_collapsible'] as num?)?.toInt() != 0,
    requiredAll: (m['required_all'] as num?)?.toInt() == 1,
    conditionalRuleJson: '${m['conditional_rule_json'] ?? ''}',
    deletedAt: '${m['deleted_at'] ?? ''}',
  );

  Map<String, dynamic> toMap({bool withId = true}) => {
    if (withId && sectionId != null) 'section_id': sectionId,
    'template_id': templateId,
    'title': title,
    'description': description,
    'order_index': orderIndex,
    'is_collapsible': isCollapsible ? 1 : 0,
    'required_all': requiredAll ? 1 : 0,
    'conditional_rule_json': conditionalRuleJson,
    if (deletedAt.isNotEmpty) 'deleted_at': deletedAt,
  };

  QcSection copyWith({
    int? sectionId,
    int? templateId,
    String? title,
    String? description,
    int? orderIndex,
    bool? isCollapsible,
    bool? requiredAll,
    String? conditionalRuleJson,
    String? deletedAt,
  }) => QcSection(
    sectionId: sectionId ?? this.sectionId,
    templateId: templateId ?? this.templateId,
    title: title ?? this.title,
    description: description ?? this.description,
    orderIndex: orderIndex ?? this.orderIndex,
    isCollapsible: isCollapsible ?? this.isCollapsible,
    requiredAll: requiredAll ?? this.requiredAll,
    conditionalRuleJson: conditionalRuleJson ?? this.conditionalRuleJson,
    deletedAt: deletedAt ?? this.deletedAt,
  );
}

/// One check on a checklist.
class QcItem extends Equatable {
  final int? itemId;
  final int sectionId;
  final int templateId;
  final String label;
  final String itemType;
  final int orderIndex;
  final bool required;
  final bool allowNa;
  final bool isCritical;

  /// Demands a photo/note/signature whenever this item fails.
  final bool requireEvidenceIfFail;

  /// Demands evidence once the response value crosses `requireEvidenceIfValue`.
  final bool requireEvidenceIfValue;
  final String defaultValue;

  /// JSON array of permitted values for dropdown/multi-select.
  final String optionsJson;
  final String unit;
  final double? minValue;
  final double? maxValue;
  final double? tolerance;
  final String toleranceType;

  /// JSON predicate for extra validation, beyond min/max.
  final String validationRuleJson;

  /// JSON predicate deciding whether the item is shown for this response set.
  final String conditionalShowJson;

  /// JSON describing when a numeric reading counts as a failure.
  final String failTriggerJson;
  final String helpText;
  final String defectCode;

  /// Set when a template edit retires this item. Kept so an inspection that
  /// answered it can still show the question it answered.
  final String deletedAt;

  bool get isDeleted => deletedAt.isNotEmpty;

  const QcItem({
    this.itemId,
    required this.sectionId,
    required this.templateId,
    required this.label,
    this.itemType = QcItemType.passFail,
    this.orderIndex = 0,
    this.required = true,
    this.allowNa = true,
    this.isCritical = false,
    this.requireEvidenceIfFail = true,
    this.requireEvidenceIfValue = false,
    this.defaultValue = '',
    this.optionsJson = '',
    this.unit = '',
    this.minValue,
    this.maxValue,
    this.tolerance,
    this.toleranceType = 'abs',
    this.validationRuleJson = '',
    this.conditionalShowJson = '',
    this.failTriggerJson = '',
    this.helpText = '',
    this.defectCode = '',
    this.deletedAt = '',
  });

  bool get isNumeric => QcItemType.isNumeric(itemType);

  bool get hasBounds => minValue != null || maxValue != null;

  /// A failing item that is also critical is what raises a Critical NC and
  /// fails the whole sheet.
  bool get raisesCriticalNc => isCritical && requireEvidenceIfFail;

  List<String> get options => _splitOptions(optionsJson);

  /// The pass band for a measured value, with [tolerance] already applied.
  ///
  /// Returns null when the item declares no bounds at all, which means "the
  /// measurement is recorded but cannot fail on its own" - the inspector's
  /// own judgement then decides pass/fail.
  ///
  /// The reading of `tolerance` is the only interpretation the schema supports:
  /// there is no nominal/target column, so an absolute tolerance widens the
  /// declared band by that many units and a relative one (`tolerance_type = 'rel'`,
  /// stored as a percentage) widens it by that percentage of the bound being
  /// relaxed. One-sided bounds widen on the measured side only, so a minimum of
  /// 10 with an absolute tolerance of 0.5 accepts 9.5 upwards but still refuses
  /// a value with no upper limit being read as unbounded.
  ({double? lo, double? hi})? get acceptanceBand {
    if (!hasBounds) return null;
    var lo = minValue;
    var hi = maxValue;
    final tol = tolerance;
    if (tol == null || tol <= 0) return (lo: lo, hi: hi);
    final relative = toleranceType == 'rel';
    if (lo != null) lo -= relative ? lo * tol / 100 : tol;
    if (hi != null) hi += relative ? hi * tol / 100 : tol;
    // A relative tolerance on a negative bound must widen the other way, and a
    // band that crossed over would accept literally anything.
    if (lo != null && hi != null && lo > hi) return (lo: lo, hi: hi);
    return (lo: lo, hi: hi);
  }

  /// Whether a measured [value] sits inside this item's acceptance band.
  ///
  /// `true` for an item with no band: nothing was declared, so nothing is
  /// refused here.
  bool accepts(double value) {
    final band = acceptanceBand;
    if (band == null) return true;
    if (band.lo != null && value < band.lo!) return false;
    if (band.hi != null && value > band.hi!) return false;
    return true;
  }

  /// A human-readable description of the band, for the item's help line.
  String get boundsLabel {
    final band = acceptanceBand;
    if (band == null) return '';
    final lo = band.lo;
    final hi = band.hi;
    if (lo != null && hi != null) return '$lo – $hi$unit';
    if (lo != null) return '≥ $lo$unit';
    if (hi != null) return '≤ $hi$unit';
    return '';
  }

  /// Whether a failure on this item must carry evidence before the sheet can
  /// be submitted.
  ///
  /// Photo and signature items carry their own evidence, so the obligation is
  /// satisfied by answering them at all. Everything else has to bring notes.
  bool get needsEvidenceOnFail =>
      requireEvidenceIfFail && !QcItemType.isEvidence(itemType);

  @override
  List<Object?> get props => [
    itemId,
    sectionId,
    templateId,
    label,
    itemType,
    orderIndex,
    required,
    allowNa,
    isCritical,
    requireEvidenceIfFail,
    requireEvidenceIfValue,
    defaultValue,
    optionsJson,
    unit,
    minValue,
    maxValue,
    tolerance,
    toleranceType,
    validationRuleJson,
    conditionalShowJson,
    failTriggerJson,
    helpText,
    defectCode,
    deletedAt,
  ];

  factory QcItem.fromMap(Map<String, dynamic> m) => QcItem(
    itemId: (m['item_id'] as num?)?.toInt(),
    sectionId: (m['section_id'] as num?)?.toInt() ?? 0,
    templateId: (m['template_id'] as num?)?.toInt() ?? 0,
    label: '${m['label'] ?? ''}',
    itemType: QcItemType.normalize('${m['item_type'] ?? ''}'),
    orderIndex: (m['order_index'] as num?)?.toInt() ?? 0,
    required: (m['required'] as num?)?.toInt() != 0,
    allowNa: (m['allow_na'] as num?)?.toInt() != 0,
    isCritical: (m['is_critical'] as num?)?.toInt() == 1,
    requireEvidenceIfFail:
        (m['require_evidence_if_fail'] as num?)?.toInt() != 0,
    requireEvidenceIfValue:
        (m['require_evidence_if_value'] as num?)?.toInt() == 1,
    defaultValue: '${m['default_value'] ?? ''}',
    optionsJson: '${m['options_json'] ?? ''}',
    unit: '${m['unit'] ?? ''}',
    minValue: (m['min_value'] as num?)?.toDouble(),
    maxValue: (m['max_value'] as num?)?.toDouble(),
    tolerance: (m['tolerance'] as num?)?.toDouble(),
    toleranceType: '${m['tolerance_type'] ?? 'abs'}',
    validationRuleJson: '${m['validation_rule_json'] ?? ''}',
    conditionalShowJson: '${m['conditional_show_json'] ?? ''}',
    failTriggerJson: '${m['fail_trigger_json'] ?? ''}',
    helpText: '${m['help_text'] ?? ''}',
    defectCode: '${m['defect_code'] ?? ''}',
    deletedAt: '${m['deleted_at'] ?? ''}',
  );

  Map<String, dynamic> toMap({bool withId = true}) => {
    if (withId && itemId != null) 'item_id': itemId,
    'section_id': sectionId,
    'template_id': templateId,
    'label': label,
    'item_type': itemType,
    'order_index': orderIndex,
    'required': required ? 1 : 0,
    'allow_na': allowNa ? 1 : 0,
    'is_critical': isCritical ? 1 : 0,
    'require_evidence_if_fail': requireEvidenceIfFail ? 1 : 0,
    'require_evidence_if_value': requireEvidenceIfValue ? 1 : 0,
    'default_value': defaultValue,
    'options_json': optionsJson,
    'unit': unit,
    if (minValue != null) 'min_value': minValue,
    if (maxValue != null) 'max_value': maxValue,
    if (tolerance != null) 'tolerance': tolerance,
    'tolerance_type': toleranceType,
    'validation_rule_json': validationRuleJson,
    'conditional_show_json': conditionalShowJson,
    'fail_trigger_json': failTriggerJson,
    'help_text': helpText,
    'defect_code': defectCode,
    if (deletedAt.isNotEmpty) 'deleted_at': deletedAt,
  };

  QcItem copyWith({
    int? itemId,
    int? sectionId,
    int? templateId,
    String? label,
    String? itemType,
    int? orderIndex,
    bool? required,
    bool? allowNa,
    bool? isCritical,
    bool? requireEvidenceIfFail,
    bool? requireEvidenceIfValue,
    String? defaultValue,
    String? optionsJson,
    String? unit,
    double? minValue,
    double? maxValue,
    double? tolerance,
    String? toleranceType,
    String? validationRuleJson,
    String? conditionalShowJson,
    String? failTriggerJson,
    String? helpText,
    String? defectCode,
    String? deletedAt,
  }) => QcItem(
    itemId: itemId ?? this.itemId,
    sectionId: sectionId ?? this.sectionId,
    templateId: templateId ?? this.templateId,
    label: label ?? this.label,
    itemType: itemType ?? this.itemType,
    orderIndex: orderIndex ?? this.orderIndex,
    required: required ?? this.required,
    allowNa: allowNa ?? this.allowNa,
    isCritical: isCritical ?? this.isCritical,
    requireEvidenceIfFail: requireEvidenceIfFail ?? this.requireEvidenceIfFail,
    requireEvidenceIfValue:
        requireEvidenceIfValue ?? this.requireEvidenceIfValue,
    defaultValue: defaultValue ?? this.defaultValue,
    optionsJson: optionsJson ?? this.optionsJson,
    unit: unit ?? this.unit,
    minValue: minValue ?? this.minValue,
    maxValue: maxValue ?? this.maxValue,
    tolerance: tolerance ?? this.tolerance,
    toleranceType: toleranceType ?? this.toleranceType,
    validationRuleJson: validationRuleJson ?? this.validationRuleJson,
    conditionalShowJson: conditionalShowJson ?? this.conditionalShowJson,
    failTriggerJson: failTriggerJson ?? this.failTriggerJson,
    helpText: helpText ?? this.helpText,
    defectCode: defectCode ?? this.defectCode,
    deletedAt: deletedAt ?? this.deletedAt,
  );
}

/// Split a comma-separated or JSON-array `options_json` column.
List<String> _splitOptions(String raw) {
  if (raw.trim().isEmpty) return const [];
  final decoded = jsonLoadsList(raw);
  if (decoded.isNotEmpty) {
    return decoded.map((e) => '$e').toList(growable: false);
  }
  return raw
      .split(',')
      .map((t) => t.trim())
      .where((t) => t.isNotEmpty)
      .toList(growable: false);
}

List<String> _splitTags(String raw) {
  if (raw.trim().isEmpty) return const [];
  return raw
      .split(',')
      .map((t) => t.trim())
      .where((t) => t.isNotEmpty)
      .toList(growable: false);
}
