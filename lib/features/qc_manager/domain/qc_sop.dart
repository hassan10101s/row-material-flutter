import 'package:equatable/equatable.dart';

import '../../../core/utils/app_format.dart';
import 'qc_enums.dart';

/// A standard operating procedure (features/qc_manager/domain).
///
/// The row is the SOP's *identity*; its body lives either inline in
/// [contentText] or in [fileUrl], and every change to that body is a new
/// [QcSopRevision] rather than an edit here. That is what lets a published
/// SOP stay immutable while still being revisable.
class QcSop extends Equatable {
  final int? sopId;
  final String code;
  final String title;
  final String category;
  final String dept;
  final String site;
  final String status;
  final String contentType;
  final String contentText;
  final String fileUrl;
  final String fileName;
  final String mimeType;

  /// Highest revision number issued for this SOP. `0` means nothing has been
  /// saved as a revision yet.
  final int revNo;
  final String effectiveDate;
  final String expiryDate;
  final String publishedAt;

  /// Exactly one SOP is active per `code`; the publish transaction maintains it.
  final bool isActive;
  final String deletedAt;
  final String ownerId;
  final String approverId;
  final String approvedAt;
  final String reviewedAt;
  final String rejectionReason;
  final String tags;
  final String criticality;

  /// Comma-separated role lists gating view/edit/approve/publish. Empty means
  /// "fall back to the caller's QC permissions".
  final String viewRoles;
  final String editRoles;
  final String approveRoles;
  final String publishRoles;

  final bool requiresReadAck;
  final bool readAckMandatory;
  final String createdAt;
  final String updatedAt;
  final String createdBy;
  final String updatedBy;

  /// Hash of the currently published revision's content, for tamper detection.
  final String versionHash;

  const QcSop({
    this.sopId,
    required this.code,
    required this.title,
    this.category = '',
    this.dept = '',
    this.site = '',
    this.status = SopStatus.draft,
    this.contentType = SopContentType.text,
    this.contentText = '',
    this.fileUrl = '',
    this.fileName = '',
    this.mimeType = '',
    this.revNo = 0,
    this.effectiveDate = '',
    this.expiryDate = '',
    this.publishedAt = '',
    this.isActive = false,
    this.deletedAt = '',
    this.ownerId = '',
    this.approverId = '',
    this.approvedAt = '',
    this.reviewedAt = '',
    this.rejectionReason = '',
    this.tags = '',
    this.criticality = QcPriority.medium,
    this.viewRoles = '',
    this.editRoles = '',
    this.approveRoles = '',
    this.publishRoles = '',
    this.requiresReadAck = true,
    this.readAckMandatory = true,
    required this.createdAt,
    required this.updatedAt,
    this.createdBy = '',
    this.updatedBy = '',
    this.versionHash = '',
  });

  bool get isPublished => status == SopStatus.published;
  bool get isDeleted => deletedAt.isNotEmpty;
  bool get isExpired => qcIsPastDue(expiryDate);

  /// A SOP that has been approved but whose effective date has not arrived
  /// cannot be started from; it is ready, just not yet in force.
  bool get isEffectiveNow => qcIsEffectiveFrom(effectiveDate);

  /// Whether the SOP still needs a read acknowledgement for its current
  /// revision from everyone but the author.
  bool get needsAck => requiresReadAck || readAckMandatory;

  /// Whether this row's body may still be edited in place.
  ///
  /// Once a SOP is published its text lives in revisions, so the row itself is
  /// frozen - further changes go through `publishSopRevision`. Offering an edit
  /// button here would produce the worst outcome available: a screen that
  /// accepts new text and a guard that refuses to save it.
  bool get isEditable =>
      status != SopStatus.published &&
      status != SopStatus.obsolete &&
      status != SopStatus.archived &&
      !isDeleted;

  List<String> get tagList => _splitTags(tags);

  @override
  List<Object?> get props => [
    sopId,
    code,
    title,
    category,
    dept,
    site,
    status,
    contentType,
    contentText,
    fileUrl,
    fileName,
    mimeType,
    revNo,
    effectiveDate,
    expiryDate,
    publishedAt,
    isActive,
    deletedAt,
    ownerId,
    approverId,
    approvedAt,
    reviewedAt,
    rejectionReason,
    tags,
    criticality,
    viewRoles,
    editRoles,
    approveRoles,
    publishRoles,
    requiresReadAck,
    readAckMandatory,
    createdAt,
    updatedAt,
    createdBy,
    updatedBy,
    versionHash,
  ];

  factory QcSop.fromMap(Map<String, dynamic> m) => QcSop(
    sopId: (m['sop_id'] as num?)?.toInt(),
    code: '${m['code'] ?? ''}',
    title: '${m['title'] ?? ''}',
    category: '${m['category'] ?? ''}',
    dept: '${m['dept'] ?? ''}',
    site: '${m['site'] ?? ''}',
    status: SopStatus.normalize('${m['status'] ?? ''}'),
    contentType: SopContentType.normalize('${m['content_type'] ?? ''}'),
    contentText: '${m['content_text'] ?? ''}',
    fileUrl: '${m['file_url'] ?? ''}',
    fileName: '${m['file_name'] ?? ''}',
    mimeType: '${m['mime_type'] ?? ''}',
    revNo: (m['rev_no'] as num?)?.toInt() ?? 0,
    effectiveDate: '${m['effective_date'] ?? ''}',
    expiryDate: '${m['expiry_date'] ?? ''}',
    publishedAt: '${m['published_at'] ?? ''}',
    isActive: (m['is_active'] as num?)?.toInt() == 1,
    deletedAt: '${m['deleted_at'] ?? ''}',
    ownerId: '${m['owner_id'] ?? ''}',
    approverId: '${m['approver_id'] ?? ''}',
    approvedAt: '${m['approved_at'] ?? ''}',
    reviewedAt: '${m['reviewed_at'] ?? ''}',
    rejectionReason: '${m['rejection_reason'] ?? ''}',
    tags: '${m['tags'] ?? ''}',
    criticality: QcPriority.normalize('${m['criticality'] ?? ''}'),
    viewRoles: '${m['view_roles'] ?? ''}',
    editRoles: '${m['edit_roles'] ?? ''}',
    approveRoles: '${m['approve_roles'] ?? ''}',
    publishRoles: '${m['publish_roles'] ?? ''}',
    requiresReadAck: (m['requires_read_ack'] as num?)?.toInt() != 0,
    readAckMandatory: (m['read_ack_mandatory'] as num?)?.toInt() != 0,
    createdAt: '${m['created_at'] ?? ''}',
    updatedAt: '${m['updated_at'] ?? ''}',
    createdBy: '${m['created_by'] ?? ''}',
    updatedBy: '${m['updated_by'] ?? ''}',
    versionHash: '${m['version_hash'] ?? ''}',
  );

  Map<String, dynamic> toMap({bool withId = true}) => {
    if (withId && sopId != null) 'sop_id': sopId,
    'code': code,
    'title': title,
    'category': category,
    'dept': dept,
    'site': site,
    'status': status,
    'content_type': contentType,
    'content_text': contentText,
    'file_url': fileUrl,
    'file_name': fileName,
    'mime_type': mimeType,
    'rev_no': revNo,
    'effective_date': effectiveDate,
    'expiry_date': expiryDate,
    if (publishedAt.isNotEmpty) 'published_at': publishedAt,
    'is_active': isActive ? 1 : 0,
    if (deletedAt.isNotEmpty) 'deleted_at': deletedAt,
    'owner_id': ownerId,
    'approver_id': approverId,
    'approved_at': approvedAt,
    'reviewed_at': reviewedAt,
    'rejection_reason': rejectionReason,
    'tags': tags,
    'criticality': criticality,
    'view_roles': viewRoles,
    'edit_roles': editRoles,
    'approve_roles': approveRoles,
    'publish_roles': publishRoles,
    'requires_read_ack': requiresReadAck ? 1 : 0,
    'read_ack_mandatory': readAckMandatory ? 1 : 0,
    'created_at': createdAt,
    'updated_at': updatedAt,
    'created_by': createdBy,
    'updated_by': updatedBy,
    'version_hash': versionHash,
  };

  QcSop copyWith({
    String? status,
    String? contentType,
    String? contentText,
    String? fileUrl,
    String? fileName,
    String? mimeType,
    int? revNo,
    String? effectiveDate,
    String? expiryDate,
    String? publishedAt,
    bool? isActive,
    String? deletedAt,
    String? approverId,
    String? approvedAt,
    String? reviewedAt,
    String? rejectionReason,
    String? updatedAt,
    String? updatedBy,
    String? versionHash,
  }) => QcSop(
    sopId: sopId,
    code: code,
    title: title,
    category: category,
    dept: dept,
    site: site,
    status: status ?? this.status,
    contentType: contentType ?? this.contentType,
    contentText: contentText ?? this.contentText,
    fileUrl: fileUrl ?? this.fileUrl,
    fileName: fileName ?? this.fileName,
    mimeType: mimeType ?? this.mimeType,
    revNo: revNo ?? this.revNo,
    effectiveDate: effectiveDate ?? this.effectiveDate,
    expiryDate: expiryDate ?? this.expiryDate,
    publishedAt: publishedAt ?? this.publishedAt,
    isActive: isActive ?? this.isActive,
    deletedAt: deletedAt ?? this.deletedAt,
    ownerId: ownerId,
    approverId: approverId ?? this.approverId,
    approvedAt: approvedAt ?? this.approvedAt,
    reviewedAt: reviewedAt ?? this.reviewedAt,
    rejectionReason: rejectionReason ?? this.rejectionReason,
    tags: tags,
    criticality: criticality,
    viewRoles: viewRoles,
    editRoles: editRoles,
    approveRoles: approveRoles,
    publishRoles: publishRoles,
    requiresReadAck: requiresReadAck,
    readAckMandatory: readAckMandatory,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    createdBy: createdBy,
    updatedBy: updatedBy ?? this.updatedBy,
    versionHash: versionHash ?? this.versionHash,
  );
}

/// One issued revision of a SOP's body. Rows are never edited after creation:
/// `content_hash` plus `is_published_rev` is the compliance record.
class QcSopRevision extends Equatable {
  final int? revId;
  final int sopId;
  final int revNo;
  final String contentText;
  final String fileUrl;
  final String fileName;
  final String mimeType;

  /// Why this revision was cut - mandatory, because an unexplained revision is
  /// an unauditable one.
  final String changeReason;
  final String editedBy;
  final String editedByName;
  final String editedAt;
  final String diffSummary;
  final String prevRevIdRef;
  final String contentHash;
  final bool isPublishedRev;
  final String supersededAt;

  const QcSopRevision({
    this.revId,
    required this.sopId,
    required this.revNo,
    this.contentText = '',
    this.fileUrl = '',
    this.fileName = '',
    this.mimeType = '',
    required this.changeReason,
    this.editedBy = '',
    this.editedByName = '',
    required this.editedAt,
    this.diffSummary = '',
    this.prevRevIdRef = '',
    this.contentHash = '',
    this.isPublishedRev = false,
    this.supersededAt = '',
  });

  @override
  List<Object?> get props => [
    revId,
    sopId,
    revNo,
    contentText,
    fileUrl,
    fileName,
    mimeType,
    changeReason,
    editedBy,
    editedByName,
    editedAt,
    diffSummary,
    prevRevIdRef,
    contentHash,
    isPublishedRev,
    supersededAt,
  ];

  factory QcSopRevision.fromMap(Map<String, dynamic> m) => QcSopRevision(
    revId: (m['rev_id'] as num?)?.toInt(),
    sopId: (m['sop_id'] as num?)?.toInt() ?? 0,
    revNo: (m['rev_no'] as num?)?.toInt() ?? 0,
    contentText: '${m['content_text'] ?? ''}',
    fileUrl: '${m['file_url'] ?? ''}',
    fileName: '${m['file_name'] ?? ''}',
    mimeType: '${m['mime_type'] ?? ''}',
    changeReason: '${m['change_reason'] ?? ''}',
    editedBy: '${m['edited_by'] ?? ''}',
    editedByName: '${m['edited_by_name'] ?? m['edited_by'] ?? ''}',
    editedAt: '${m['edited_at'] ?? ''}',
    diffSummary: '${m['diff_summary'] ?? ''}',
    prevRevIdRef: '${m['prev_rev_id_ref'] ?? ''}',
    contentHash: '${m['content_hash'] ?? ''}',
    isPublishedRev: (m['is_published_rev'] as num?)?.toInt() == 1,
    supersededAt: '${m['superseded_at'] ?? ''}',
  );

  Map<String, dynamic> toMap({bool withId = true}) => {
    if (withId && revId != null) 'rev_id': revId,
    'sop_id': sopId,
    'rev_no': revNo,
    'content_text': contentText,
    'file_url': fileUrl,
    'file_name': fileName,
    'mime_type': mimeType,
    'change_reason': changeReason,
    'edited_by': editedBy,
    'edited_by_name': editedByName,
    'edited_at': editedAt,
    'diff_summary': diffSummary,
    'prev_rev_id_ref': prevRevIdRef,
    'content_hash': contentHash,
    'is_published_rev': isPublishedRev ? 1 : 0,
    // Written only by `publishSopRevision`, when it supersedes this revision.
    // Omitted while empty so the insert leaves it NULL, which reads back as
    // "still the live revision".
    if (supersededAt.isNotEmpty) 'superseded_at': supersededAt,
  };
}

/// A reader's acknowledgement of one SOP revision.
///
/// `UNIQUE(sop_id, rev_no, user_id)` is what makes re-reading idempotent: the
/// second ack for the same revision updates nothing and inserts nothing, so a
/// flaky connection cannot inflate the compliance percentage.
class QcSopRead extends Equatable {
  final int? id;
  final int sopId;
  final int revNo;
  final String userId;
  final String userName;
  final String readAt;
  final String signatureBase64;
  final String deviceId;
  final String ipAddress;
  final String geo;
  final String ackMethod;

  const QcSopRead({
    this.id,
    required this.sopId,
    required this.revNo,
    required this.userId,
    this.userName = '',
    required this.readAt,
    this.signatureBase64 = '',
    this.deviceId = '',
    this.ipAddress = '',
    this.geo = '',
    this.ackMethod = SopAckMethod.manual,
  });

  @override
  List<Object?> get props => [
    id,
    sopId,
    revNo,
    userId,
    userName,
    readAt,
    signatureBase64,
    deviceId,
    ipAddress,
    geo,
    ackMethod,
  ];

  factory QcSopRead.fromMap(Map<String, dynamic> m) => QcSopRead(
    id: (m['id'] as num?)?.toInt(),
    sopId: (m['sop_id'] as num?)?.toInt() ?? 0,
    revNo: (m['rev_no'] as num?)?.toInt() ?? 0,
    userId: '${m['user_id'] ?? ''}',
    userName: '${m['user_name'] ?? ''}',
    readAt: '${m['read_at'] ?? ''}',
    signatureBase64: '${m['signature_base64'] ?? ''}',
    deviceId: '${m['device_id'] ?? ''}',
    ipAddress: '${m['ip_address'] ?? ''}',
    geo: '${m['geo'] ?? ''}',
    ackMethod: SopAckMethod.normalize('${m['ack_method'] ?? ''}'),
  );

  Map<String, dynamic> toMap({bool withId = true}) => {
    if (withId && id != null) 'id': id,
    'sop_id': sopId,
    'rev_no': revNo,
    'user_id': userId,
    'user_name': userName,
    'read_at': readAt,
    'signature_base64': signatureBase64,
    'device_id': deviceId,
    'ip_address': ipAddress,
    'geo': geo,
    'ack_method': ackMethod,
  };
}

/// An append-only, hash-chained SOP audit entry.
///
/// There is no `toMap` that omits the hash fields and no update path by design:
/// the repository exposes insert and verify only (plan V6_ENHANCED §21).
class QcSopAudit extends Equatable {
  final int? id;
  final int? sopId;
  final int? revNo;
  final String action;
  final String entity;
  final String byUserId;
  final String byUserName;
  final String at;
  final Map<String, dynamic> meta;
  final String prevHash;
  final String hash;

  /// Always 1. Present so that a row copied out of the table cannot be edited
  /// in place without the edit being obvious.
  final bool immutable;

  const QcSopAudit({
    this.id,
    this.sopId,
    this.revNo,
    required this.action,
    this.entity = SopAuditEntity.sop,
    this.byUserId = '',
    this.byUserName = '',
    required this.at,
    this.meta = const {},
    this.prevHash = '',
    this.hash = '',
    this.immutable = true,
  });

  @override
  List<Object?> get props => [
    id,
    sopId,
    revNo,
    action,
    entity,
    byUserId,
    byUserName,
    at,
    meta,
    prevHash,
    hash,
    immutable,
  ];

  factory QcSopAudit.fromMap(Map<String, dynamic> m) => QcSopAudit(
    id: (m['id'] as num?)?.toInt(),
    sopId: (m['sop_id'] as num?)?.toInt(),
    revNo: (m['rev_no'] as num?)?.toInt(),
    action: '${m['action'] ?? ''}',
    entity: '${m['entity'] ?? SopAuditEntity.sop}',
    byUserId: '${m['by_user_id'] ?? ''}',
    byUserName: '${m['by_user_name'] ?? ''}',
    at: '${m['at'] ?? ''}',
    meta: _jsonMap(m['meta_json']),
    prevHash: '${m['prev_hash'] ?? ''}',
    hash: '${m['hash'] ?? ''}',
    immutable: (m['immutable'] as num?)?.toInt() != 0,
  );

  Map<String, dynamic> toMap({bool withId = true}) => {
    if (withId && id != null) 'id': id,
    if (sopId != null) 'sop_id': sopId,
    if (revNo != null) 'rev_no': revNo,
    'action': action,
    'entity': entity,
    'by_user_id': byUserId,
    'by_user_name': byUserName,
    'at': at,
    'meta_json': jsonDumps(meta),
    'prev_hash': prevHash,
    'hash': hash,
    'immutable': immutable ? 1 : 0,
  };
}

/// Split a comma-separated `tags` column, tolerating nulls and stray spaces.
List<String> _splitTags(String raw) {
  if (raw.trim().isEmpty) return const [];
  return raw
      .split(',')
      .map((t) => t.trim())
      .where((t) => t.isNotEmpty)
      .toList(growable: false);
}

Map<String, dynamic> _jsonMap(Object? value) {
  if (value == null) return const {};
  if (value is Map) return Map<String, dynamic>.from(value);
  return jsonLoads(value.toString());
}
