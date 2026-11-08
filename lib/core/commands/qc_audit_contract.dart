/// Global target types for the existing QC audit vocabulary. Local ids are
/// resolved at authoring/projection boundaries, never sent as global identity.
const qcAuditTargets = <String, String>{
  'SOP': 'qcSop',
  'SOP_REV': 'qcSopRevision',
  'SOP_READ': 'qcSopRead',
  'TEMPLATE': 'qcTemplate',
  'SECTION': 'qcSection',
  'ITEM': 'qcItem',
  'INSPECTION': 'qcInspection',
  'RESPONSE': 'qcResponse',
  'FINDING': 'qcFindingNc',
  'CAPA': 'qcCapa',
};
