/// Rejected (including partial), pending and unrecognised decisions are never
/// ingredients. This policy also applies to historical fallback receipts.
const formulationAcceptedDecisions = ['APPROVED', 'CONDITIONAL_APPROVAL'];

/// Internal query token; repositories expand it to parameterized SQL.
const formulationAcceptedStatusFilter = '@formulation-accepted';
