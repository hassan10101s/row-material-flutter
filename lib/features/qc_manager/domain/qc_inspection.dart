import 'package:equatable/equatable.dart';

import '../../../core/utils/app_format.dart';
import 'qc_enums.dart';

/// One execution of a checklist against a lot/batch/PO (qc_manager/domain).
///
/// [templateVersion] is captured at start so that publishing a new template
/// version cannot retroactively change what a historical sheet meant.
class QcInspection extends Equatable {
  final int? inspectionId;
  final int templateId;
  final int templateVersion;
  final String refType;
  final String refId;
  final String lotNo;
  final String batchNo;
  final String poNo;
  final String grnNo;
  final double? qtyInspected;
  final String qtyUnit;
  final String dept;
  final String site;
  final String location;
  final String line;
  final String workCenter;
  final String status;
  final String resultOverall;
  final double? scorePct;
  final bool hasNc;
  final int ncCount;
  final int criticalNcCount;
  final int majorNcCount;
  final int minorNcCount;
  final String inspectorId;
  final String inspectorName;
  final String reviewerId;
  final String reviewerName;
  final String approvedBy;
  final String approvedByName;
  final String submittedAt;
  final String reviewedAt;
  final String approvedAt;
  final String rejectedAt;
  final String closedAt;
  final String inspectionDate;
  final String startAt;
  final String endAt;
  final String shift;
  final String remarks;
  final String reviewComments;
  final String rejectionReason;
  final String deletedAt;
  final String createdAt;
  final String updatedAt;
  final String createdBy;
  final String updatedBy;

  const QcInspection({
    this.inspectionId,
    required this.templateId,
    this.templateVersion = 1,
    this.refType = QcRefType.other,
    this.refId = '',
    this.lotNo = '',
    this.batchNo = '',
    this.poNo = '',
    this.grnNo = '',
    this.qtyInspected,
    this.qtyUnit = '',
    this.dept = '',
    this.site = '',
    this.location = '',
    this.line = '',
    this.workCenter = '',
    this.status = QcInspectionStatus.inProgress,
    this.resultOverall = QcOverallResult.pending,
    this.scorePct,
    this.hasNc = false,
    this.ncCount = 0,
    this.criticalNcCount = 0,
    this.majorNcCount = 0,
    this.minorNcCount = 0,
    this.inspectorId = '',
    this.inspectorName = '',
    this.reviewerId = '',
    this.reviewerName = '',
    this.approvedBy = '',
    this.approvedByName = '',
    this.submittedAt = '',
    this.reviewedAt = '',
    this.approvedAt = '',
    this.rejectedAt = '',
    this.closedAt = '',
    required this.inspectionDate,
    this.startAt = '',
    this.endAt = '',
    this.shift = '',
    this.remarks = '',
    this.reviewComments = '',
    this.rejectionReason = '',
    this.deletedAt = '',
    required this.createdAt,
    required this.updatedAt,
    this.createdBy = '',
    this.updatedBy = '',
  });

  bool get isDeleted => deletedAt.isNotEmpty;
  bool get isInProgress => status == QcInspectionStatus.inProgress;
  bool get isSubmitted => status == QcInspectionStatus.submitted;

  /// Editable by the inspector only before submit; after that the sheet is
  /// owned by the reviewer.
  bool get isEditable => isInProgress && !isDeleted;

  bool get isRejected => status == QcInspectionStatus.rejected;
  bool get isClosed => status == QcInspectionStatus.closed;

  bool get hasOpenNc =>
      criticalNcCount > 0 || majorNcCount > 0 || minorNcCount > 0;

  /// A Critical NC blocks submission when the template says so, and always
  /// blocks a straight approval.
  bool get hasCriticalNc => criticalNcCount > 0;

  /// The label used in lists and exports when no lot/batch was recorded.
  String get refLabel {
    if (refId.isNotEmpty) return refId;
    if (lotNo.isNotEmpty) return lotNo;
    if (batchNo.isNotEmpty) return batchNo;
    if (poNo.isNotEmpty) return poNo;
    return '-';
  }

  @override
  List<Object?> get props => [
    inspectionId,
    templateId,
    templateVersion,
    refType,
    refId,
    lotNo,
    batchNo,
    poNo,
    grnNo,
    qtyInspected,
    qtyUnit,
    dept,
    site,
    location,
    line,
    workCenter,
    status,
    resultOverall,
    scorePct,
    hasNc,
    ncCount,
    criticalNcCount,
    majorNcCount,
    minorNcCount,
    inspectorId,
    inspectorName,
    reviewerId,
    reviewerName,
    approvedBy,
    approvedByName,
    submittedAt,
    reviewedAt,
    approvedAt,
    rejectedAt,
    closedAt,
    inspectionDate,
    startAt,
    endAt,
    shift,
    remarks,
    reviewComments,
    rejectionReason,
    deletedAt,
    createdAt,
    updatedAt,
    createdBy,
    updatedBy,
  ];

  factory QcInspection.fromMap(Map<String, dynamic> m) => QcInspection(
    inspectionId: (m['inspection_id'] as num?)?.toInt(),
    templateId: (m['template_id'] as num?)?.toInt() ?? 0,
    templateVersion: (m['template_version'] as num?)?.toInt() ?? 1,
    refType: QcRefType.normalize('${m['ref_type'] ?? ''}'),
    refId: '${m['ref_id'] ?? ''}',
    lotNo: '${m['lot_no'] ?? ''}',
    batchNo: '${m['batch_no'] ?? ''}',
    poNo: '${m['po_no'] ?? ''}',
    grnNo: '${m['grn_no'] ?? ''}',
    qtyInspected: (m['qty_inspected'] as num?)?.toDouble(),
    qtyUnit: '${m['qty_unit'] ?? ''}',
    dept: '${m['dept'] ?? ''}',
    site: '${m['site'] ?? ''}',
    location: '${m['location'] ?? ''}',
    line: '${m['line'] ?? ''}',
    workCenter: '${m['work_center'] ?? ''}',
    status: QcInspectionStatus.normalize('${m['status'] ?? ''}'),
    resultOverall: QcOverallResult.normalize('${m['result_overall'] ?? ''}'),
    scorePct: (m['score_pct'] as num?)?.toDouble(),
    hasNc: (m['has_nc'] as num?)?.toInt() == 1,
    ncCount: (m['nc_count'] as num?)?.toInt() ?? 0,
    criticalNcCount: (m['critical_nc_count'] as num?)?.toInt() ?? 0,
    majorNcCount: (m['major_nc_count'] as num?)?.toInt() ?? 0,
    minorNcCount: (m['minor_nc_count'] as num?)?.toInt() ?? 0,
    inspectorId: '${m['inspector_id'] ?? ''}',
    inspectorName: '${m['inspector_name'] ?? ''}',
    reviewerId: '${m['reviewer_id'] ?? ''}',
    reviewerName: '${m['reviewer_name'] ?? ''}',
    approvedBy: '${m['approved_by'] ?? ''}',
    approvedByName: '${m['approved_by_name'] ?? ''}',
    submittedAt: '${m['submitted_at'] ?? ''}',
    reviewedAt: '${m['reviewed_at'] ?? ''}',
    approvedAt: '${m['approved_at'] ?? ''}',
    rejectedAt: '${m['rejected_at'] ?? ''}',
    closedAt: '${m['closed_at'] ?? ''}',
    inspectionDate: '${m['inspection_date'] ?? ''}',
    startAt: '${m['start_at'] ?? ''}',
    endAt: '${m['end_at'] ?? ''}',
    shift: '${m['shift'] ?? ''}',
    remarks: '${m['remarks'] ?? ''}',
    reviewComments: '${m['review_comments'] ?? ''}',
    rejectionReason: '${m['rejection_reason'] ?? ''}',
    deletedAt: '${m['deleted_at'] ?? ''}',
    createdAt: '${m['created_at'] ?? ''}',
    updatedAt: '${m['updated_at'] ?? ''}',
    createdBy: '${m['created_by'] ?? ''}',
    updatedBy: '${m['updated_by'] ?? ''}',
  );

  Map<String, dynamic> toMap({bool withId = true}) => {
    if (withId && inspectionId != null) 'inspection_id': inspectionId,
    'template_id': templateId,
    'template_version': templateVersion,
    'ref_type': refType,
    'ref_id': refId,
    'lot_no': lotNo,
    'batch_no': batchNo,
    'po_no': poNo,
    'grn_no': grnNo,
    if (qtyInspected != null) 'qty_inspected': qtyInspected,
    'qty_unit': qtyUnit,
    'dept': dept,
    'site': site,
    'location': location,
    'line': line,
    'work_center': workCenter,
    'status': status,
    'result_overall': resultOverall,
    if (scorePct != null) 'score_pct': scorePct,
    'has_nc': hasNc ? 1 : 0,
    'nc_count': ncCount,
    'critical_nc_count': criticalNcCount,
    'major_nc_count': majorNcCount,
    'minor_nc_count': minorNcCount,
    'inspector_id': inspectorId,
    'inspector_name': inspectorName,
    'reviewer_id': reviewerId,
    'reviewer_name': reviewerName,
    'approved_by': approvedBy,
    'approved_by_name': approvedByName,
    'submitted_at': submittedAt,
    'reviewed_at': reviewedAt,
    'approved_at': approvedAt,
    'rejected_at': rejectedAt,
    'closed_at': closedAt,
    'inspection_date': inspectionDate,
    'start_at': startAt,
    'end_at': endAt,
    'shift': shift,
    'remarks': remarks,
    'review_comments': reviewComments,
    'rejection_reason': rejectionReason,
    if (deletedAt.isNotEmpty) 'deleted_at': deletedAt,
    'created_at': createdAt,
    'updated_at': updatedAt,
    'created_by': createdBy,
    'updated_by': updatedBy,
  };

  /// Every field is nullable-and-defaulted, so a caller changing the status
  /// cannot accidentally blank the lot, the inspector or the timestamps it does
  /// not know about.
  ///
  /// Fields that can legitimately be *cleared* - the workflow stamps, the
  /// measured quantities, `deletedAt` - take an `Object?` sentinel rather than a
  /// plain `T?`. Clearing a stamp is a real operation (a rejection re-opens the
  /// sheet, a soft delete is undone by a restore), so for those "not passed" has
  /// to mean "erase" and only an explicit `null` does that. Passing a value, or
  /// omitting the argument, still leaves the field alone. The stored columns are
  /// `NOT NULL DEFAULT ''`, so an explicit null lands as the empty string rather
  /// than a second representation of "nothing".
  QcInspection copyWith({
    int? inspectionId,
    int? templateId,
    int? templateVersion,
    String? refType,
    String? refId,
    String? lotNo,
    String? batchNo,
    String? poNo,
    String? grnNo,
    Object? qtyInspected = _unsetField,
    String? qtyUnit,
    String? dept,
    String? site,
    String? location,
    String? line,
    String? workCenter,
    String? status,
    String? resultOverall,
    Object? scorePct = _unsetField,
    bool? hasNc,
    int? ncCount,
    int? criticalNcCount,
    int? majorNcCount,
    int? minorNcCount,
    String? inspectorId,
    String? inspectorName,
    String? reviewerId,
    String? reviewerName,
    String? approvedBy,
    String? approvedByName,
    Object? submittedAt = _unsetField,
    Object? reviewedAt = _unsetField,
    Object? approvedAt = _unsetField,
    Object? rejectedAt = _unsetField,
    Object? closedAt = _unsetField,
    String? inspectionDate,
    Object? startAt = _unsetField,
    Object? endAt = _unsetField,
    String? shift,
    String? remarks,
    String? reviewComments,
    String? rejectionReason,
    Object? deletedAt = _unsetField,
    String? createdAt,
    String? updatedAt,
    String? createdBy,
    String? updatedBy,
  }) => QcInspection(
    inspectionId: inspectionId ?? this.inspectionId,
    templateId: templateId ?? this.templateId,
    templateVersion: templateVersion ?? this.templateVersion,
    refType: refType ?? this.refType,
    refId: refId ?? this.refId,
    lotNo: lotNo ?? this.lotNo,
    batchNo: batchNo ?? this.batchNo,
    poNo: poNo ?? this.poNo,
    grnNo: grnNo ?? this.grnNo,
    qtyInspected: _keepOrNull(qtyInspected, this.qtyInspected),
    qtyUnit: qtyUnit ?? this.qtyUnit,
    dept: dept ?? this.dept,
    site: site ?? this.site,
    location: location ?? this.location,
    line: line ?? this.line,
    workCenter: workCenter ?? this.workCenter,
    status: status ?? this.status,
    resultOverall: resultOverall ?? this.resultOverall,
    scorePct: _keepOrNull(scorePct, this.scorePct),
    hasNc: hasNc ?? this.hasNc,
    ncCount: ncCount ?? this.ncCount,
    criticalNcCount: criticalNcCount ?? this.criticalNcCount,
    majorNcCount: majorNcCount ?? this.majorNcCount,
    minorNcCount: minorNcCount ?? this.minorNcCount,
    inspectorId: inspectorId ?? this.inspectorId,
    inspectorName: inspectorName ?? this.inspectorName,
    reviewerId: reviewerId ?? this.reviewerId,
    reviewerName: reviewerName ?? this.reviewerName,
    approvedBy: approvedBy ?? this.approvedBy,
    approvedByName: approvedByName ?? this.approvedByName,
    submittedAt: _keepOr(submittedAt, this.submittedAt),
    reviewedAt: _keepOr(reviewedAt, this.reviewedAt),
    approvedAt: _keepOr(approvedAt, this.approvedAt),
    rejectedAt: _keepOr(rejectedAt, this.rejectedAt),
    closedAt: _keepOr(closedAt, this.closedAt),
    inspectionDate: inspectionDate ?? this.inspectionDate,
    startAt: _keepOr(startAt, this.startAt),
    endAt: _keepOr(endAt, this.endAt),
    shift: shift ?? this.shift,
    remarks: remarks ?? this.remarks,
    reviewComments: reviewComments ?? this.reviewComments,
    rejectionReason: rejectionReason ?? this.rejectionReason,
    deletedAt: _keepOr(deletedAt, this.deletedAt),
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    createdBy: createdBy ?? this.createdBy,
    updatedBy: updatedBy ?? this.updatedBy,
  );
}

/// Sentinel telling `copyWith` an argument was not supplied, as opposed to
/// being supplied as null.
const Object _unsetField = Object();

/// Resolves a sentinel-typed `copyWith` argument to its stored value.
///
/// A non-nullable target treats an explicit null as the empty string, which is
/// how this schema spells "no value" on a `NOT NULL` text column.
T _keepOr<T extends Object>(Object? given, T current) =>
    identical(given, _unsetField) ? current : (given as T?) ?? '' as T;

/// The same, for the nullable columns where null is a value of its own.
T? _keepOrNull<T>(Object? given, T? current) =>
    identical(given, _unsetField) ? current : given as T?;

/// A single answered item on a sheet.
///
/// `UNIQUE(inspection_id, item_id)` in the schema is the real guarantee that a
/// sheet has exactly one answer per item; this model simply mirrors it.
class QcResponse extends Equatable {
  final int? respId;
  final int inspectionId;
  final int itemId;
  final int? sectionId;
  final String result;
  final String value;
  final String valueType;
  final String notes;

  /// JSON array of captured photo paths.
  final String photosJson;
  final String signatureBase64;
  final String measuredAt;
  final double? measuredValue;
  final String defectCode;

  /// Set when this failure came from a critical item - it is what drives the
  /// Critical NC and the `Fail` overall result.
  final bool isCriticalFailure;
  final String createdAt;
  final String updatedAt;

  const QcResponse({
    this.respId,
    required this.inspectionId,
    required this.itemId,
    this.sectionId,
    required this.result,
    this.value = '',
    this.valueType = '',
    this.notes = '',
    this.photosJson = '',
    this.signatureBase64 = '',
    this.measuredAt = '',
    this.measuredValue,
    this.defectCode = '',
    this.isCriticalFailure = false,
    required this.createdAt,
    required this.updatedAt,
  });

  bool get isPass => QcResponseResult.isPass(result);
  bool get isFail => QcResponseResult.isFail(result);
  bool get isNa => QcResponseResult.isNa(result);

  /// Whether an inspector actually answered this item.
  ///
  /// `QcResponseResult` has no "pending" member - anything that is not Fail or
  /// NA normalises to Pass, so `result` alone cannot tell an untouched seeded
  /// row from a deliberate N/A. [measuredAt] is what separates them: the seed
  /// written by `createInspection` leaves it empty, and answering stamps it.
  /// Without this, every sheet would report itself fully answered on open, or
  /// would refuse to submit a legitimately N/A item.
  bool get isRecorded => measuredAt.isNotEmpty;

  /// A failing answer with nothing attached cannot satisfy an evidence rule.
  bool get hasEvidence =>
      photosJson.trim().isNotEmpty ||
      signatureBase64.isNotEmpty ||
      notes.trim().isNotEmpty;

  List<String> get photos =>
      jsonLoadsList(photosJson).map((e) => '$e').toList();

  @override
  List<Object?> get props => [
    respId,
    inspectionId,
    itemId,
    sectionId,
    result,
    value,
    valueType,
    notes,
    photosJson,
    signatureBase64,
    measuredAt,
    measuredValue,
    defectCode,
    isCriticalFailure,
    createdAt,
    updatedAt,
  ];

  factory QcResponse.fromMap(Map<String, dynamic> m) => QcResponse(
    respId: (m['resp_id'] as num?)?.toInt(),
    inspectionId: (m['inspection_id'] as num?)?.toInt() ?? 0,
    itemId: (m['item_id'] as num?)?.toInt() ?? 0,
    sectionId: (m['section_id'] as num?)?.toInt(),
    result: QcResponseResult.normalize('${m['result'] ?? ''}'),
    value: '${m['value'] ?? ''}',
    valueType: '${m['value_type'] ?? ''}',
    notes: '${m['notes'] ?? ''}',
    photosJson: '${m['photos_json'] ?? ''}',
    signatureBase64: '${m['signature_base64'] ?? ''}',
    measuredAt: '${m['measured_at'] ?? ''}',
    measuredValue: (m['measured_value'] as num?)?.toDouble(),
    defectCode: '${m['defect_code'] ?? ''}',
    isCriticalFailure: (m['is_critical_failure'] as num?)?.toInt() == 1,
    createdAt: '${m['created_at'] ?? ''}',
    updatedAt: '${m['updated_at'] ?? ''}',
  );

  Map<String, dynamic> toMap({bool withId = true}) => {
    if (withId && respId != null) 'resp_id': respId,
    'inspection_id': inspectionId,
    'item_id': itemId,
    if (sectionId != null) 'section_id': sectionId,
    'result': result,
    'value': value,
    'value_type': valueType,
    'notes': notes,
    'photos_json': photosJson,
    'signature_base64': signatureBase64,
    'measured_at': measuredAt,
    if (measuredValue != null) 'measured_value': measuredValue,
    'defect_code': defectCode,
    'is_critical_failure': isCriticalFailure ? 1 : 0,
    'created_at': createdAt,
    'updated_at': updatedAt,
  };

  /// Sentinel-typed arguments, for the same reason as [QcInspection.copyWith]:
  /// a measurement has to be clearable without also losing the value next to
  /// it, and `measuredAt` is cleared when a sheet is reset for a re-inspection.
  QcResponse copyWith({
    int? respId,
    int? inspectionId,
    int? itemId,
    Object? sectionId = _unsetField,
    String? result,
    String? value,
    String? valueType,
    Object? notes = _unsetField,
    Object? photosJson = _unsetField,
    Object? signatureBase64 = _unsetField,
    Object? measuredAt = _unsetField,
    Object? measuredValue = _unsetField,
    Object? defectCode = _unsetField,
    bool? isCriticalFailure,
    String? createdAt,
    String? updatedAt,
  }) => QcResponse(
    respId: respId ?? this.respId,
    inspectionId: inspectionId ?? this.inspectionId,
    itemId: itemId ?? this.itemId,
    sectionId: _keepOrNull(sectionId, this.sectionId),
    result: result ?? this.result,
    value: value ?? this.value,
    valueType: valueType ?? this.valueType,
    notes: _keepOr(notes, this.notes),
    photosJson: _keepOr(photosJson, this.photosJson),
    signatureBase64: _keepOr(signatureBase64, this.signatureBase64),
    measuredAt: _keepOr(measuredAt, this.measuredAt),
    measuredValue: _keepOrNull(measuredValue, this.measuredValue),
    defectCode: _keepOr(defectCode, this.defectCode),
    isCriticalFailure: isCriticalFailure ?? this.isCriticalFailure,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
}
