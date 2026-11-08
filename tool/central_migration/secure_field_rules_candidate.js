'use strict';

const helpers = `
    // BEGIN SECURE FIELD CONTRACT
    function secureManager(orgId) {
      return activeInOrg(orgId) && myRoles().hasAny(['admin','trial_owner','quality_manager']);
    }
    function secureReveal(orgId) {
      let view = get(/databases/$(database)/documents/organizations/$(orgId)/secureVisibility/$(request.auth.uid));
      return secureManager(orgId) && view != null && view.data.enabled == true
        && view.data.authTime == request.auth.token.auth_time
        && activeOwnedDevice(orgId, view.data.deviceId);
    }
    function secureMaintenance(orgId, d) {
      let gate = get(/databases/$(database)/documents/organizations/$(orgId)).data.commandProtocol;
      return gate.get('secureMaintenanceJob', null) == null ? false : secureManager(orgId) && d.protocol.get('secureMigration', '') == gate.secureMaintenanceJob
        && d.deviceId == gate.secureMaintenanceDevice
        && (d.protocol.entityType in ['sample','productBatchSample','labResult','secureFieldSubmission','nirValidationSettings','nutritionFormulation']
          || (d.protocol.entityType in ['referenceMaterial','labProduct'] && d.remoteId == gate.secureMaintenanceTarget)
          || (d.protocol.entityType in ['materialBound','parameter','labMaterialAnalysis','labProductAnalysis','labUnit'] ? secureDefinitionCompanion(orgId, d, gate) : false));
    }
    function secureDefinitionCompanion(orgId, d, gate) {
      let collection = gate.secureMaintenanceTargetType == 'referenceMaterial' ? 'referenceMaterials' : 'labConfig';
      let root = getAfter(/databases/$(database)/documents/organizations/$(orgId)/$(collection)/$(gate.secureMaintenanceTarget));
      return gate.secureMaintenanceComplete == true && root != null
        && root.data.protocol.operationId == d.protocol.operationId
        && root.data.securePolicyJob == gate.secureMaintenanceJob;
    }
    function secureWriteFence(orgId, d) {
      let gate = get(/databases/$(database)/documents/organizations/$(orgId)).data.commandProtocol;
      return gate.get('secureMaintenanceJob', null) == null ? true : secureMaintenance(orgId, d);
    }
    function secureDefinition(orgId, d) {
      let was = resource == null ? 0 : resource.data.get('secureConfigured', 0);
      let now = d.get('secureConfigured', 0);
      return now in [0,1] && (was == 0 && now == 0 || (secureManager(orgId)
        && (resource != null && now == was
          && d.get('physicalReferenceJson', '') == resource.data.get('physicalReferenceJson', '')
          && d.get('chemicalReferenceJson', '') == resource.data.get('chemicalReferenceJson', '')
          || (secureMaintenance(orgId, d)
            && get(/databases/$(database)/documents/organizations/$(orgId)).data.commandProtocol.secureMaintenanceComplete == true))));
    }
    function secureSource(orgId, d) {
      let enabled = get(/databases/$(database)/documents/organizations/$(orgId)).data.commandProtocol.get('secureFieldsEnabled', false);
      return enabled ? secureProtectedSource(orgId, d)
        : (d.get('secureEntryId', null) == null && (resource == null || resource.data.get('secureEntryId', null) == null));
    }
    function secureProtectedSource(orgId, d) {
      let gate = get(/databases/$(database)/documents/organizations/$(orgId)).data.commandProtocol;
      let expected = d.protocol.get('secureMigration', '') != '' ? gate.get('secureMaintenanceEpoch', 0) : gate.get('publicPrivacyEpoch', 0);
      return d.get('publicPrivacyEpoch', 0) == expected
        && (resource == null ? secureNewSource(orgId, d) : secureExistingSource(orgId, d));
    }
    function secureNewSource(orgId, d) {
      let next = d.get('secureEntryId', null);
      return next == null ? secureSourceTemplate(orgId, d)
        : d.protocol.get('secureFieldsAware', false) == true && securePointer(orgId, d, next);
    }
    function secureExistingSource(orgId, d) {
      let prior = resource.data.get('secureEntryId', null);
      let next = d.get('secureEntryId', null);
      return secureSourceTemplate(orgId, d)
        && (prior == null && next == null || d.protocol.get('secureFieldsAware', false) == true)
        && (d.get('secureResult', 0) == resource.data.get('secureResult', 0) || secureMaintenance(orgId, d))
        && (prior == next || (next == null ? secureMaintenance(orgId, d) : securePointer(orgId, d, next)));
    }
    function secureSourceTemplate(orgId, d) {
      return d.protocol.entityType == 'sample' ? secureSampleTemplate(orgId, d)
        : d.protocol.entityType == 'productBatchSample' ? secureBatchTemplate(orgId, d)
        : d.protocol.entityType != 'labResult' || get(/databases/$(database)/documents/organizations/$(orgId)).data.commandProtocol.get('secureFieldsEnabled', false) != true || d.protocol.get('secureFieldsAware', false) == true;
    }
    function secureSampleTemplate(orgId, d) {
      let product = d.get('inspectionKind', 'raw') == 'product';
      let ref = d.parentRefs.get(product ? 'productId' : 'materialId', {});
      let collection = product ? 'labConfig' : 'referenceMaterials';
      let parent = ref.get('entityId', '') == '' ? null : getAfter(/databases/$(database)/documents/organizations/$(orgId)/$(collection)/$(ref.entityId));
      return parent == null || parent.data.get('secureConfigured', 0) == 0 || secureMaintenance(orgId, d)
        || (d.protocol.get('secureFieldsAware', false) == true && d.get('secureEntryId', null) is string);
    }
    function secureBatchTemplate(orgId, d) {
      let parent = getAfter(/databases/$(database)/documents/organizations/$(orgId)/samples/$(d.parentRefs.batchId.entityId));
      return parent.data.get('secureTemplateJson', null) == null ||
        (d.protocol.get('secureFieldsAware', false) == true && d.get('secureEntryId', null) is string);
    }
    function securePointer(orgId, d, id) {
      let child = getAfter(/databases/$(database)/documents/organizations/$(orgId)/labConfig/$(id));
      let data = child.data;
      let field = d.protocol.entityType == 'sample' ? 'inspectionId' : d.protocol.entityType == 'productBatchSample' ? 'batchSampleId' : d.protocol.entityType == 'labResult' ? 'sampleTestId' : d.protocol.entityType == 'nirValidationSettings' ? 'nirResetId' : 'formulationId';
      return child != null && data.configType == 'secure_field_submissions'
        && data.sourceKind == d.protocol.entityType && data.sourceVersion == d.version
        && data.parentRefs[field].entityId == d.remoteId
        && data.protocol.operationId == d.protocol.operationId
        && (resource == null || secureMaintenance(orgId, d));
    }
    function secureSubmission(orgId, d) {
      let field = d.sourceKind == 'sample' ? 'inspectionId' : d.sourceKind == 'productBatchSample' ? 'batchSampleId' : d.sourceKind == 'labResult' ? 'sampleTestId' : d.sourceKind == 'nirValidationSettings' ? 'nirResetId' : 'formulationId';
      let collection = d.sourceKind == 'sample' ? 'samples' : d.sourceKind == 'productBatchSample' ? 'productBatchSamples' : d.sourceKind == 'labResult' ? 'labResults' : 'labConfig';
      let ref = d.parentRefs.get(field, {});
      let source = getAfter(/databases/$(database)/documents/organizations/$(orgId)/$(collection)/$(ref.entityId));
      return resource == null && d.deletedAt == null && d.fieldsJson.size() <= 750000
        && d.sourceKind in ['sample','productBatchSample','labResult','nirValidationSettings','nutritionFormulation']
        && d.parentRefs.size() == 1 && ref == {'entityType':d.sourceKind,'entityId':source.data.remoteId,'version':source.data.version}
        && source.data.organizationId == orgId && source.data.secureEntryId == d.remoteId
        && source.data.version == d.sourceVersion && source.data.protocol.operationId == d.protocol.operationId
        && (source.data.version == 1 || secureMaintenance(orgId, d))
        && (d.sourceKind != 'nirValidationSettings' || d.sourceVersion == 1 || secureNirOriginal(orgId, d, ref.entityId));
    }
    function secureNirOriginal(orgId, d, sourceId) {
      let prior = get(/databases/$(database)/documents/organizations/$(orgId)/labConfig/$(sourceId));
      let id = prior.data.get('secureEntryId', null);
      let archived = id == null ? null : get(/databases/$(database)/documents/organizations/$(orgId)/labConfig/$(id));
      return d.originalSnapshotJson == (archived == null ? prior.data.get('calibrationSnapshotJson', null) : archived.data.originalSnapshotJson)
        && d.originalParameter == (archived == null ? prior.data.parameter : archived.data.originalParameter)
        && d.originalNote == (archived == null ? prior.data.get('resetNote', null) : archived.data.get('originalNote', null));
    }
    function secureNirMigration(orgId, d) {
      let id = resource.data.get('secureEntryId', null);
      let archived = id == null ? null : get(/databases/$(database)/documents/organizations/$(orgId)/labConfig/$(id));
      return secureMaintenance(orgId, d) && d.deletedAt == resource.data.deletedAt
        && d.diff(resource.data).affectedKeys().hasOnly(['calibrationSnapshotJson','parameter','resetNote','secureEntryId','secureResult','securePolicyJob','publicPrivacyEpoch','version','updatedAt','updatedBy','deviceId','protocol','centralSequence','parentRefs'])
        && (d.get('secureEntryId', null) != null || (
          d.get('calibrationSnapshotJson', null) == (archived == null ? resource.data.get('calibrationSnapshotJson', null) : archived.data.originalSnapshotJson)
          && d.parameter == (archived == null ? resource.data.parameter : archived.data.originalParameter)
          && d.get('resetNote', null) == (archived == null ? resource.data.get('resetNote', null) : archived.data.get('originalNote', null))));
    }
    function secureFormulationMigration(orgId, d) {
      return secureMaintenance(orgId, d) && d.deletedAt == resource.data.deletedAt
        && d.configType == 'nutrition_formulations'
        && d.diff(resource.data).affectedKeys().hasOnly(['parametersJson','calculationJson','sourceSnapshotJson','graphParametersJson','secureEntryId','secureTemplateJson','securePolicyJob','publicPrivacyEpoch','version','updatedAt','updatedBy','deviceId','protocol','centralSequence','parentRefs']);
    }
    function secureControlEdit(orgId) {
      let d = request.resource.data;
      return secureManager(orgId) && writerDevice(orgId)
        && d.keys().hasOnly(['pending','complete','jobId','targetId','targetType','parameterNames','deviceId','updatedAt','privacyEpoch'])
        && d.privacyEpoch is int && d.privacyEpoch > 0
        && d.pending is bool && d.complete is bool && d.jobId is string && d.targetId is string
        && d.targetType in ['referenceMaterial','labProduct'] && d.parameterNames is list
        && d.updatedAt == request.time
        && getAfter(/databases/$(database)/documents/organizations/$(orgId)).data.commandProtocol.get('secureMaintenanceJob', null) == (d.pending ? d.jobId : null)
        && (resource == null || resource.data.pending == false || (d.jobId == resource.data.jobId && d.targetId == resource.data.targetId && d.deviceId == resource.data.deviceId));
    }
    function secureOrganizationEdit(orgId) {
      let d = request.resource.data;
      let g = d.commandProtocol;
      let state = getAfter(/databases/$(database)/documents/organizations/$(orgId)/secureControl/state);
      return secureManager(orgId) && d.diff(resource.data).affectedKeys().hasOnly(['commandProtocol'])
        && g.diff(resource.data.commandProtocol).affectedKeys().hasOnly(['secureFieldsEnabled','secureMaintenanceJob','secureMaintenanceDevice','secureMaintenanceTarget','secureMaintenanceTargetType','secureMaintenanceComplete','secureMaintenanceEpoch','publicPrivacyEpoch'])
        && g.get('secureFieldsEnabled', false) is bool
        && (resource.data.commandProtocol.get('secureFieldsEnabled', false) != true || g.secureFieldsEnabled == true)
        && (state.data.parameterNames.size() == 0 || g.secureFieldsEnabled == true)
        && state != null && state.data.privacyEpoch == g.secureMaintenanceEpoch
        && g.secureMaintenanceEpoch is int && g.secureMaintenanceEpoch > 0
        && (state.data.pending
          ? g.get('publicPrivacyEpoch', 0) == resource.data.commandProtocol.get('publicPrivacyEpoch', 0)
          : state.data.complete && g.publicPrivacyEpoch == state.data.privacyEpoch)
        && (resource.data.commandProtocol.get('secureMaintenanceJob', null) == null
          ? g.secureMaintenanceEpoch == resource.data.commandProtocol.get('publicPrivacyEpoch', 0) + 1
          : g.secureMaintenanceEpoch == resource.data.commandProtocol.secureMaintenanceEpoch)
        && state.data.deviceId == g.secureMaintenanceDevice
        && state.data.targetId == g.secureMaintenanceTarget && state.data.targetType == g.secureMaintenanceTargetType && state.data.complete == g.secureMaintenanceComplete
        && g.secureMaintenanceJob == (state.data.pending ? state.data.jobId : null);
    }
    // END SECURE FIELD CONTRACT
`;

function candidate(rules) {
  const marker = /\n    \/\/ BEGIN SECURE FIELD CONTRACT[\s\S]*?    \/\/ END SECURE FIELD CONTRACT\n/;
  rules = rules.replace(marker, '');
  rules = rules.replace('    // ── identity helpers', helpers + '\n    // ── identity helpers');
  if (!rules.includes('// BEGIN SECURE FIELD CONTRACT')) {
    rules = rules.replace('    function legacyDomainWritesAllowed', helpers + '\n    function legacyDomainWritesAllowed');
  }
  rules = rules.replace('return directBusinessLinked(orgId);', 'return directBusinessLinked(orgId) && secureWriteFence(orgId, request.resource.data);');
  // A separate narrow metadata permission. It cannot change any existing
  // organization lifecycle or command-protocol gate.
  rules = rules.replace(/      \/\/ BEGIN SECURE METADATA[\s\S]*?      \/\/ END SECURE METADATA\n/, '');
  const block = `      // BEGIN SECURE METADATA
      allow update: if secureOrganizationEdit(orgId);
      match /secureVisibility/{uid} {
        allow get: if activeInOrg(orgId) && request.auth.uid == uid;
        allow list, delete: if false;
        allow create, update: if request.auth.uid == uid && secureManager(orgId) && writerDevice(orgId)
          && request.resource.data.keys().hasOnly(['enabled','authTime','deviceId','updatedAt'])
          && request.resource.data.enabled is bool
          && request.resource.data.authTime == request.auth.token.auth_time
          && request.resource.data.updatedAt == request.time;
      }
      match /secureControl/{id} {
        allow get: if id == 'state' && activeInOrg(orgId);
        allow list, delete: if false;
        allow create, update: if id == 'state' && secureControlEdit(orgId);
      }
      // END SECURE METADATA
`;
  rules = rules.replace('      // Heartbeat written by the sync engine.', block + '\n      // Heartbeat written by the sync engine.');
  const read = /        allow read: if resource != null && resource.data.configType.matches\('nutrition_\.\*'\)[\s\S]*?: can\(orgId, 'samples.read'\);/;
  rules = rules.replace(read, `        allow read: if resource != null && (resource.data.configType == 'secure_field_submissions'
          ? secureReveal(orgId) : (resource.data.configType.matches('nutrition_.*')
            ? can(orgId, 'formulations.read') : can(orgId, 'samples.read')));`);
  rules = rules.replace(/        \/\/ SECURE FORMULA MIGRATION[\s\S]*?;\n/, '');
  rules = rules.replace('      match /labConfig/{docId} {', `      match /labConfig/{docId} {
        // SECURE FORMULA MIGRATION
        allow update: if secureFormulationMigration(orgId, request.resource.data) && bumped(orgId) && directShape();`);
  return rules.replace(/\n{3,}(?=    \/\/ BEGIN SECURE FIELD CONTRACT|      \/\/ BEGIN SECURE METADATA)/g, '\n\n');
}
module.exports = {candidate};
