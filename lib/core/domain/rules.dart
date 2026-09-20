/// Pure business rules and constants (port of core/domain/rules.py).
library;

const List<String> rolesAllowed = ['Admin', 'Lab User', 'Viewer'];
const String developerRole = 'Developer';
const List<String> editRoles = ['Admin', 'Lab User'];

const Set<String> requiredAppDbTables = {
  'users',
  'reference_materials',
  'inspections',
  'settings',
};

const Set<String> rebuildableAppDbTables = {
  'inspection_status_history',
  'parameters',
};

const Map<String, String> decisionStatuses = {
  'APPROVED': 'Approved',
  'CONDITIONAL_APPROVAL': 'Approved',
  'PARTIAL_REJECTION': 'Partial',
  'FULL_REJECTION': 'Rejected',
};

const List<String> decisionCodes = [
  'APPROVED',
  'CONDITIONAL_APPROVAL',
  'PARTIAL_REJECTION',
  'FULL_REJECTION',
];

/// Labels bilingual by status code.
const Map<String, Map<String, String>> decisionLabels = {
  'APPROVED': {'ar': 'قبول نهائي', 'en': 'Final Approval'},
  'CONDITIONAL_APPROVAL': {'ar': 'قبول مبدئي مع المتابعة', 'en': 'Conditional Approval'},
  'PARTIAL_REJECTION': {'ar': 'رفض جزئي', 'en': 'Partial Rejection'},
  'FULL_REJECTION': {'ar': 'رفض كلي', 'en': 'Full Rejection'},
};

const int truckNumberMaxLength = 10;
const int resultValueMaxLength = 50;
const int quantityMaxLength = 10;
const int rejectedQuantityMaxLength = 10;
const int materialNameMaxLength = 100;
const int decisionReasonMaxLength = 250;
const int followUpNoteMaxLength = 250;
const int maxDecisionVersions = 3;

const String passwordHashAlgoLegacy = 'pbkdf2_sha256';
const String passwordHashAlgoV2 = 'pbkdf2_sha256_v2';
const int passwordHashRounds = 390000;
const String developerPasswordHashAlgo = 'pbkdf2_sha256_v2_dev';
const int developerPasswordHashRounds = 780000;
const String sealedTextPrefix = 'enc1:';

const String defaultAdminUsername = 'hassan10101s';

/// Usage expiry offset used when no expiry is set (developer signed installations).
const Duration usageExpiryGrace = Duration(days: 3650);

/// Roles that can manage settings.
bool canManageSettings(String role) =>
    role == 'Developer' || role == 'Admin';

/// Roles that can edit inspections / run labs.
bool canEditInspections(String role) =>
    role == 'Developer' || role == 'Admin' || role == 'Lab User';

/// Whether a role can edit other users.
bool canEditUsers(String role) => role == 'Developer';

bool isDecisionStatus(String status) => decisionCodes.contains(status);