import '../../../core/utils/app_format.dart';

/// StatusHistory entry for an inspection decision.
class StatusHistoryRow {
  final int? id;
  final int inspectionId;
  final int version;
  final String? oldStatus;
  final String newStatus;
  final String changeReason;
  final String followUpNote;
  final String rejectedQuantity;
  final int changedBy;
  final String changedByName;
  final String changedAt;

  const StatusHistoryRow({
    this.id,
    required this.inspectionId,
    required this.version,
    required this.oldStatus,
    required this.newStatus,
    required this.changeReason,
    required this.followUpNote,
    required this.rejectedQuantity,
    required this.changedBy,
    required this.changedByName,
    required this.changedAt,
  });

  factory StatusHistoryRow.fromMap(Map<String, dynamic> m) => StatusHistoryRow(
        id: m['id'] as int?,
        inspectionId: (m['inspection_id'] as num).toInt(),
        version: (m['version'] as num).toInt(),
        oldStatus: m['old_status'] as String?,
        newStatus: '${m['new_status'] ?? ''}',
        changeReason: '${m['change_reason'] ?? ''}',
        followUpNote: '${m['follow_up_note'] ?? ''}',
        rejectedQuantity: '${m['rejected_quantity'] ?? ''}',
        changedBy: (m['changed_by'] as num).toInt(),
        changedByName: '${m['changed_by_name'] ?? ''}',
        changedAt: '${m['changed_at'] ?? ''}',
      );

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'inspection_id': inspectionId,
        'version': version,
        'old_status': oldStatus,
        'new_status': newStatus,
        'change_reason': changeReason,
        'follow_up_note': followUpNote,
        'rejected_quantity': rejectedQuantity,
        'changed_by': changedBy,
        'changed_by_name': changedByName,
        'changed_at': changedAt,
      };
}

/// An inspection (features/inspections/domain).
class Inspection {
  final int? id;
  final String entryCode;
  final int materialId;
  final String materialName;
  final String materialCode;
  final String inspectionDate;
  final String supplier;
  final String truckNumber;
  final String quantity;
  final String sampleTakenBy;
  final String specialistName;
  final Map<String, dynamic> physicalResults;
  final Map<String, dynamic> chemicalResults;
  final Map<String, dynamic> physicalReference;
  final Map<String, dynamic> chemicalReference;
  final String decisionStatus;
  final String decisionReason;
  final String followUpNote;
  final String rejectedQuantity;
  final String reportHtml;
  final Map<String, dynamic> snapshot;
  final List<dynamic> sampleNames;
  final int decisionVersion;
  final int? createdBy;
  final String createdByName;
  final String? lastPdfPath;
  final String createdAt;
  final String updatedAt;
  final String? expiryDate;

  const Inspection({
    this.id,
    required this.entryCode,
    required this.materialId,
    required this.materialName,
    required this.materialCode,
    required this.inspectionDate,
    this.supplier = '',
    this.truckNumber = '',
    this.quantity = '',
    this.sampleTakenBy = '',
    this.specialistName = '',
    this.physicalResults = const {},
    this.chemicalResults = const {},
    this.physicalReference = const {},
    this.chemicalReference = const {},
    this.decisionStatus = '',
    this.decisionReason = '',
    this.followUpNote = '',
    this.rejectedQuantity = '',
    this.reportHtml = '',
    this.snapshot = const {},
    this.sampleNames = const [],
    this.decisionVersion = 1,
    this.createdBy,
    this.createdByName = '',
    this.lastPdfPath,
    required this.createdAt,
    required this.updatedAt,
    this.expiryDate,
  });

  bool get hasDecision => decisionStatus.isNotEmpty;

  String get qty3 => _to3(quantity);
  String get rejectedQty3 => _to3(rejectedQuantity);

  static String _to3(String value) {
    final t = value.trim();
    if (t.isEmpty || t == '-') return t;
    final d = double.tryParse(t);
    return d == null ? t : d.toStringAsFixed(3);
  }

  factory Inspection.fromMap(Map<String, dynamic> m) => Inspection(
        id: m['id'] as int?,
        entryCode: '${m['entry_code'] ?? ''}',
        materialId: (m['material_id'] as num?)?.toInt() ?? 0,
        materialName: '${m['material_name'] ?? ''}',
        materialCode: '${m['material_code'] ?? ''}',
        inspectionDate: '${m['inspection_date'] ?? ''}',
        supplier: '${m['supplier'] ?? ''}',
        truckNumber: '${m['truck_number'] ?? ''}',
        quantity: '${m['quantity'] ?? ''}',
        sampleTakenBy: '${m['sample_taken_by'] ?? ''}',
        specialistName: '${m['specialist_name'] ?? ''}',
        physicalResults: _jsonMap(m['physical_results'] ?? m['physical_results_json']),
        chemicalResults: _jsonMap(m['chemical_results'] ?? m['chemical_results_json']),
        physicalReference: _jsonMap(m['physical_reference'] ?? m['physical_reference_json']),
        chemicalReference: _jsonMap(m['chemical_reference'] ?? m['chemical_reference_json']),
        decisionStatus: '${m['decision_status'] ?? ''}',
        decisionReason: '${m['decision_reason'] ?? ''}',
        followUpNote: '${m['follow_up_note'] ?? ''}',
        rejectedQuantity: '${m['rejected_quantity'] ?? ''}',
        reportHtml: '${m['report_html'] ?? ''}',
        snapshot: _jsonMap(m['snapshot'] ?? m['snapshot_json']),
        sampleNames: _jsonList(m['sample_names'] ?? m['sample_names_json']),
        decisionVersion: (m['decision_version'] as num?)?.toInt() ?? 1,
        createdBy: (m['created_by'] as num?)?.toInt(),
        createdByName: '${m['created_by_name'] ?? ''}',
        lastPdfPath: m['last_pdf_path'] as String?,
        createdAt: '${m['created_at'] ?? ''}',
        updatedAt: '${m['updated_at'] ?? ''}',
        expiryDate: m['expiry_date'] as String?,
      );

  Map<String, dynamic> toRowMap() => {
        if (id != null) 'id': id,
        'entry_code': entryCode,
        'material_id': materialId,
        'material_name': materialName,
        'material_code': materialCode,
        'inspection_date': inspectionDate,
        'supplier': supplier,
        'truck_number': truckNumber,
        'quantity': quantity,
        'sample_taken_by': sampleTakenBy,
        'specialist_name': specialistName,
        'physical_results_json': jsonDumps(physicalResults),
        'chemical_results_json': jsonDumps(chemicalResults),
        'physical_reference_json': jsonDumps(physicalReference),
        'chemical_reference_json': jsonDumps(chemicalReference),
        'decision_status': decisionStatus,
        'decision_reason': decisionReason,
        'follow_up_note': followUpNote,
        'rejected_quantity': rejectedQuantity,
        'report_html': reportHtml,
        'snapshot_json': jsonDumps(snapshot),
        'sample_names_json': jsonDumps(sampleNames),
        'decision_version': decisionVersion,
        if (createdBy != null) 'created_by': createdBy,
        'created_by_name': createdByName,
        if (lastPdfPath != null) 'last_pdf_path': lastPdfPath,
        'created_at': createdAt,
        'updated_at': updatedAt,
        if (expiryDate != null) 'expiry_date': expiryDate,
      };

  static Map<String, dynamic> _jsonMap(Object? value) {
    if (value == null) return {};
    if (value is Map) return Map<String, dynamic>.from(value);
    return jsonLoads(value.toString());
  }

  static List<dynamic> _jsonList(Object? value) {
    if (value == null) return const [];
    if (value is List) return value;
    return jsonLoadsList(value.toString());
  }
}