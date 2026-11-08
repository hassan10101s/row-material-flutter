'use strict';
// Checked-in generated rules are the deployed artifact. --check rejects drift.
const fs = require('node:fs');
const path = require('node:path');
const manifest = require('./domain_manifest.json');
const {maxBusinessEffects, maxLabDefinitionEffects, maxProductReferenceEffects, maxSimpleBusinessEffects, simpleEntityTypes: simpleTypes, maxChemicalDefinitions, maxChemicalDefinitionProofBlocks} = require('./release_limits.json');
const tableTypes = ['qcCustomTable','qcCustomTableField'];
const labTypes = ['labAnalysis','labAnalysisItem','labFieldLink','labUnit'];
const consumptionTypes = ['labResult','consumption','inventoryTransaction','inventoryLot','inventoryItem','secureFieldSubmission'];
const productTypes = ['labProduct','labProductAnalysis'];
const target = path.resolve(__dirname, '../../firestore.rules');
const outputIndex = process.argv.indexOf('--output');
const output = outputIndex < 0 ? target : path.resolve(process.argv[outputIndex + 1] || '');
if (outputIndex >= 0 && !output.startsWith(path.resolve(__dirname,'../../build') + path.sep)) {
  throw Error('Candidate output must remain inside workspace/build');
}
const q = s => `'${s}'`;
const entries = Object.entries(manifest.entities).filter(([t]) => t !== 'member');
const collections = Object.fromEntries(entries.map(([t,d]) => [t,d.collection]));
// Only these expression-heavy privacy records distribute primitive checks
// across their source rule and the same atomic small event. Every other type
// validates its complete schema in its own source rule.
const partitionedTypes = new Set(['sample','productBatchSample','qcInspection','qcResponse']);
if ([...partitionedTypes].some(t=>!manifest.entities[t])) throw Error('Unknown partitioned schema');
// A split of an identifier-only constant has exactly the same list values,
// while avoiding one evaluated literal expression per allowed column.
const literal = v => Array.isArray(v) && v.length > 8 && v.every(x => typeof x === 'string' && /^[A-Za-z0-9_]+$/.test(x))
  ? q(v.join(',')) + ".split(',')" : JSON.stringify(v).replaceAll('"', "'");
const managed = new Set(['createdAt','createdBy','updatedAt','updatedBy','version','deletedAt','deviceId','remoteId']);
function value(d, field, prefix='d') {
  return d.parents.some(p=>p.relation===field)
    ? `${prefix}.parentRefs.${field}.entityType + '/' + ${prefix}.parentRefs.${field}.entityId`
    : `${prefix}.get(${q(field)}, null)`;
}
function keys(type, d) {
  const methods = [];
  d.unique.forEach((u,i)=>{
    if (u.collations.some(c=>c!=='BINARY')) throw Error(`Unimplemented collation: ${type}`);
    if (u.where && !/^deleted_at\s+IS\s+NULL$/i.test(u.where)) throw Error(`Unsupported predicate: ${type}`);
    const fields = u.fields.map(f=>value(d,f));
    const guard = u.fields.map(f=> d.parents.some(p=>p.relation===f)
      ? `d.parentRefs.get(${q(f)}, null) != null` : `d.get(${q(f)}, null) != null`).join(' && ');
    const encoded = fields.map(v=>`keyPart(${v})`).join(' + ');
    methods.push(`    function unique_${type}_${i}(d) {
      return ${u.where ? 'd.deletedAt == null && ' : ''}${guard}
        ? [hashing.sha256(${q(`u2|${type}|${i}|`)} + ${encoded}).toHexString().lower()] : [];
    }`);
  });
  methods.push(`    function keys_${type}(d) { return ${d.unique.length ? d.unique.map((_,i)=>`unique_${type}_${i}(d)`).join('.concat(')+')'.repeat(d.unique.length-1) : '[]'}; }`);
  return methods.join('\n');
}
function shape(type,d) {
  const allowed = [...d.fields.filter(f=>f!=='payload'), 'protocol','parentRefs','centralSequence'];
  const terms = [`d.keys().hasOnly(${literal(allowed)})`,
    `d.protocol.entityType == ${q(type)}`,
    `d.parentRefs is map`, `d.parentRefs.keys().hasOnly(${literal(d.parents.map(p=>p.relation))})`,
    d.unique.length ? `d.protocol.uniqueKeys == keys_${type}(d)` : `d.protocol.uniqueKeys == uniqueKeys`];
  if (d.collection==='labConfig') terms.push(`d.configType == ${q(d.table)}`);
  const typeTerms = [];
  for (const [f,c] of Object.entries(d.sqlFields)) {
    if (managed.has(f)) continue;
    // consumptionLinked's comparisons, equality and bounded arithmetic already
    // require all four quantities to be finite numbers. Do not repeat the
    // same primitive tests before that stronger domain validation.
    if (type === 'consumption' && ['qtyUsed','requestedQty','appliedQty','shortfallQty'].includes(f)) continue;
    if (type === 'consumption' && ['sampleTestId','inventoryId','lotId','reversalOfLogId','lotRemoteId'].includes(f)) continue;
    if (type === 'inventoryItem' && f === 'currentQty') continue; // inventoryBalance enforces type/range.
    if (type === 'inventoryLot' && ['qtyReceived','qtyRemaining'].includes(f)) continue; // lotLinked bounds both numbers.
    const actor = d.actors.includes(f);
    const primitive = actor ? 'string' : /INT/i.test(c.type) ? 'int' : /REAL|FLOAT|NUMERIC|DOUBLE/i.test(c.type) ? 'number' : 'string';
    const check = `d.${f} is ${primitive}`;
    // Foreign numeric ids are origin metadata; the global parentRefs gate below
    // is authoritative. Defaults may be absent in legacy records being edited.
    const nullable = !c.required || c.hasDefault || d.parents.some(p=>p.relation===f);
    // Inspection/NCR/audit payloads normally carry non-null values. Check their
    // type first so authorized non-admin saves fit the expression budget;
    // the null alternative preserves the exact same optional-field contract.
    // The large stock-return family is verified at the expression ceiling;
    // retain its inlined fast path while sharing predicates elsewhere.
    const stockBudget = consumptionTypes.includes(type) && type !== 'secureFieldSubmission';
    typeTerms.push(nullable ? (stockBudget
      ? `(d.get(${q(f)}, null) is ${primitive} || d.get(${q(f)}, null) == null)`
      : `optional_${primitive}(d.get(${q(f)}, null))`) : check);
    if (type==='sample' && f==='entryCode') terms.push('(resource == null || d.entryCode == resource.data.entryCode)');
  }
  const partitioned = partitionedTypes.has(type);
  terms.push(`payloadCore_${type}(d)`);
  if (type === 'consumption') terms.push(`(d.protocol.get('ledgerMode', '') == 'consumption_v1'
          ? !d.keys().hasAny(['sampleTestId','inventoryId','lotId','reversalOfLogId','lotRemoteId'])
          : optional_int(d.get('sampleTestId', null)) && optional_int(d.get('inventoryId', null))
            && optional_int(d.get('lotId', null)) && optional_int(d.get('reversalOfLogId', null))
            && optional_string(d.get('lotRemoteId', null)))`);
  if (partitioned) terms.push(`(d.protocol.get('effect', null) == null || payloadTypes_${type}(d))`);
  for (const p of d.parents) {
    if (type === 'secureFieldSubmission') continue;
    // These two parents are validated together with their operation binding
    // by consumptionLinked, avoiding duplicate expression-heavy traversals.
    if (type === 'consumption' && ['inventoryId','sampleTestId'].includes(p.relation)) continue;
    const pd = manifest.entities[p.type];
    const optional = !p.required || (type==='sample' && p.relation==='materialId');
    let parentCheck = `parentValid(orgId, d, ${q(p.relation)}, ${q(p.type)}, ${q(pd.collection)}, ${pd.collection==='labConfig'?q(pd.table):"''"})`;
    if (type.startsWith('qc') && p.type.startsWith('qc')) parentCheck = `qcParentValid(orgId, d, ${q(p.relation)}, ${q(p.type)}, ${q(pd.collection)})`;
    if (type === 'labProductAnalysis') parentCheck = `(qcParentValid(orgId, d, ${q(p.relation)}, ${q(p.type)}, ${q(pd.collection)}) && getAfter(/databases/$(database)/documents/organizations/$(orgId)/labConfig/$(d.parentRefs.${p.relation}.entityId)).data.configType == ${q(pd.table)})`;
    if (type === 'consumption') parentCheck = `consumptionParentValid(orgId, d, ${q(p.relation)}, ${q(p.type)}, ${q(pd.collection)})`;
    if (type === 'labResult') parentCheck = `(d.get('deletedAt', null) != null && resource != null ? tombstoneParentUnchanged(d, ${q(p.relation)}) : ${parentCheck})`;
    const missing = type==='sample' && p.relation==='materialId'
      ? `d.get('inspectionKind', 'raw') == 'product'` : 'true';
    terms.push(optional ? `(d.parentRefs.get(${q(p.relation)}, null) == null ? ${missing} : ${parentCheck})` : parentCheck);
  }
  for (let i=0;i<d.unique.length;i++) {
    const unchanged = productTypes.includes(type) ? 'admitted || ' : ['inventoryItem','inventoryLot'].includes(type)
      ? `(resource != null && resource.data.get('deletedAt', null) == null && d.get('deletedAt', null) == null && d.get(${q(type === 'inventoryItem' ? 'name' : 'lotNo')}, null) == resource.data.get(${q(type === 'inventoryItem' ? 'name' : 'lotNo')}, null)) || ` : '';
    terms.push(`(uniqueKeys.size() <= ${i} || ${unchanged}heldUnique(orgId, d, uniqueKeys[${i}]))`);
  }
  if (type==='inventoryItem') terms.push('inventoryBalance(orgId, d)');
  if (['referenceMaterial','labProduct'].includes(type)) terms.push('secureDefinition(orgId, d)');
  if (['sample','productBatchSample','labResult','nirValidationSettings','nutritionFormulation'].includes(type)) terms.push('secureSource(orgId, d)');
  if (type==='secureFieldSubmission') terms.push('secureSubmission(orgId, d)');
  if (type==='labAnalysis') terms.push('chemicalDefinitionProof(orgId, d)');
  if (type==='labResult') terms.push(`(d.get('nirExclusionsJson', null) == null || d.nirExclusionsJson.size() <= 65536)`,
    `(resource == null || resource.data.get('nirExclusionsJson', null) == null || d.get('nirExclusionsJson', null) is string)`);
  if (type==='inventoryLot') terms.push('lotLinked(orgId, d)');
  if (type==='inventoryTransaction') terms.push("!d.remoteId.matches('^derived_consumption_v1_.*')", 'ledgerLinked(orgId, d)');
  if (type==='consumption') terms.push('consumptionLinked(orgId, d)');
  if (type==='stockAdjustment') terms.push('adjustmentLinked(orgId, d)');
  if (type==='sample') terms.push('sampleDecision(orgId, d)');
  if (type==='qualityCheck') terms.push('qualityHistory(orgId, d)');
  if (type==='productBatchSample') terms.push('productSampleDecisionValid(orgId, d)');
  if (type==='nirValidationSettings') terms.push(`(resource == null && d.get('deletedAt', null) == null || resource != null && secureNirMigration(orgId, d))`, `(d.get('referenceVersion', null) == null
    ? (d.parentRefs.size() == 0 && d.get('materialId', null) == null && d.get('productId', null) == null)
    : (d.referenceVersion == 1 && (
      (d.get('scope', '') == '' && d.parentRefs.size() == 0 && d.get('materialId', null) == null && d.get('productId', null) == null)
      || (d.get('scope', '') == 'raw_material' && d.parameter.size() > 0 && d.parentRefs.get('materialId', null) != null && d.parentRefs.get('productId', null) == null && d.get('productId', null) == null)
      || (d.get('scope', '') == 'product' && d.parameter.size() > 0 && d.parentRefs.get('productId', null) != null && d.parentRefs.get('materialId', null) == null && d.get('materialId', null) == null))))`);
  if (type==='qcFindingNc') terms.push('productFindingLinkValid(orgId, d)');
  if (productTypes.includes(type)) terms.push(`(d.protocol.get('effect', null) == null || admitted)`);
  if (['inventoryItem','inventoryLot'].includes(type)) {
    terms.push(`(d.protocol.get('effect', null) == null || d.protocol.effect == {'entityType':${q(type)},'entityId':d.remoteId,'version':d.version,'collection':${q(d.collection)}})`);
  } else if ([...tableTypes, ...labTypes, ...consumptionTypes,...productTypes,...simpleTypes].includes(type)) terms.push(`compactTableEffect(orgId, d, ${q(type)}, ${q(d.collection)})`);
  const core = typeTerms.filter((_, i) => !partitioned || i % 2 === 0);
  const event = !partitioned ? [] : typeTerms.filter((_, i) => i % 2 === 1);
  const sameProductKey = type === 'labProduct' ? 'd.name == resource.data.name' : ['productId','analysisId'].map(f=>`d.parentRefs.${f}.entityType == resource.data.parentRefs.${f}.entityType && d.parentRefs.${f}.entityId == resource.data.parentRefs.${f}.entityId`).join(' && ');
  return `    function payloadCore_${type}(d) { return ${core.length ? core.join(' && ') : 'true'}; }\n    function payloadTypes_${type}(d) { return ${event.length ? event.join(' && ') : 'true'}; }\n    function shape_${type}(orgId, d) {\n      let uniqueKeys = ${d.unique.length ? 'd.protocol.uniqueKeys' : `keys_${type}(d)`};\n${productTypes.includes(type) ? `      let admitted = resource != null && resource.data.get('deletedAt', null) == null && d.get('deletedAt', null) == null && ${sameProductKey};\n` : ''}      return ${terms.join('\n        && ')};\n    }`;

}
let generated = `    // BEGIN GENERATED DIRECT DOMAIN RULES (generate_rules.js)
    function chemicalAt(orgId, a, index) {
      let defs = a.get('chemicalDefinitions', []);
      return defs.size() <= index || chemicalEntry(orgId, defs[index]);
    }
    function chemicalEntry(orgId, c) {
      let stock = getAfter(/databases/$(database)/documents/organizations/$(orgId)/inventoryItems/$(c.inventoryId));
      return c is map && c.keys().hasOnly(['kind','inventoryId','unit','field','quantity'])
        && c.inventoryId is string && c.inventoryId.size() > 0
        && c.unit is string && stock != null && stock.data.organizationId == orgId
        && stock.data.get('deletedAt', null) == null
        && (stock.data.category == 'liquid' ? c.unit in ['L','mL']
          : stock.data.category == 'powder' ? c.unit in ['kg','g'] : c.unit == 'pc')
        && (c.kind == 'fixed' ? c.quantity is number && c.quantity > 0 && c.quantity < 1000000000000000
          && !c.keys().hasAny(['field'])
          : c.kind == 'link' && c.field is string && c.field.size() > 0 && !c.keys().hasAny(['quantity']));
    }
    function chemicalDefinitionProof(orgId, d) {
      let defs = d.get('chemicalDefinitions', []);
      return defs is list && defs.size() <= ${maxChemicalDefinitions}
        && (defs.size() == 0 || d.deletedAt != null || chemicalSummary(orgId, d));
    }
    function chemicalSummary(orgId, d) {
      let id = d.protocol.operationId + '_' + d.remoteId + '_summary';
      let proof = getAfter(/databases/$(database)/documents/organizations/$(orgId)/analysisDefinitionProofs/$(id));
      return proof != null && proof.data.analysisId == d.remoteId
        && proof.data.operationId == d.protocol.operationId && proof.data.summary == true
        && proof.data.committedAt == request.time;
    }
    function chemicalBlockProof(orgId, d, block) {
      let id = d.protocol.operationId + '_' + d.remoteId + '_' + string(block);
      let proof = getAfter(/databases/$(database)/documents/organizations/$(orgId)/analysisDefinitionProofs/$(id));
      return proof != null && proof.data.analysisId == d.remoteId
        && proof.data.operationId == d.protocol.operationId && proof.data.summary == false
        && proof.data.block == block && proof.data.committedAt == request.time;
    }
    function chemicalAllBlocks(orgId, a, n) {
      return n == int(math.ceil(a.chemicalDefinitions.size() / 4.0)) && n > 0 && n <= ${maxChemicalDefinitionProofBlocks}
${Array.from({length:maxChemicalDefinitionProofBlocks},(_,i)=>`        && (n <= ${i} || chemicalBlockProof(orgId, a, ${i}))`).join('\n')};
    }
    function optional_string(v) { return v is string || v == null; }
    function optional_int(v) { return v is int || v == null; }
    function optional_number(v) { return v is number || v == null; }
    function keyPart(v) {
      let text = string(v);
      return string(text.toUtf8().size()) + ':' + text;
    }
    function heldUnique(orgId, d, key) {
      let held = getAfter(/databases/$(database)/documents/organizations/$(orgId)/uniqueReservations/$(key));
      return held != null && held.data.released == false
        && held.data.entityType == d.protocol.entityType && held.data.entityId == d.remoteId
        && held.data.recordPath == request.path;
    }
    function parentValid(orgId, d, field, type, collection, configType) {
      let ref = d.parentRefs.get(field, {});
      let id = ref.get('entityId', '');
      let parent = getAfter(/databases/$(database)/documents/organizations/$(orgId)/$(collection)/$(id));
      let data = parent.data;
      return ref.keys().hasOnly(['entityType','entityId','version'])
        && ref.get('entityType', '') == type && id is string && id.size() > 0
        && ref.version is int && ref.version > 0 && parent != null
        && data.organizationId == orgId && data.version == ref.version
        && (!(type == 'labAnalysis' && d.protocol.entityType == 'labResult' && data.keys().hasAny(['chemicalDefinitions'])) || d.protocol.get('chemicalDefinitionAware', false) == true)
        && (!(type == 'labAnalysis' && d.protocol.entityType in ['labAnalysisItem','labFieldLink']) || !data.keys().hasAny(['chemicalDefinitions']))
        && (configType == '' || data.configType == configType)
        && (data.get('deletedAt', null) == null || d.deletedAt != null
          || (resource != null && resource.data.get('parentRefs', {}).get(field, {}).get('entityId', '') == id))
        && (d.protocol.entityType != 'productBatchSample' || data.inspectionKind == 'product');
    }
    // QC parents have no labConfig discriminator, chemical-definition gate
    // or product-sample kind gate. Keep the same reference/version/deletion
    // contract without evaluating those unrelated domain branches per parent.
    function qcParentValid(orgId, d, field, type, collection) {
      let ref = d.parentRefs.get(field, {});
      let id = ref.get('entityId', '');
      let parent = getAfter(/databases/$(database)/documents/organizations/$(orgId)/$(collection)/$(id));
      let data = parent.data;
      return ref.keys().hasOnly(['entityType','entityId','version'])
        && ref.get('entityType', '') == type && id is string && id.size() > 0
        && ref.version is int && ref.version > 0 && parent != null
        && data.organizationId == orgId && data.version == ref.version
        && (data.get('deletedAt', null) == null || d.deletedAt != null
          || (resource != null && resource.data.get('parentRefs', {}).get(field, {}).get('entityId', '') == id));
    }
    function payloadTypes(type, d) {
      return ${[...partitionedTypes].map(t=>`type == ${q(t)} ? payloadTypes_${t}(d)`).join(' : ')} : true;
    }
    function effectAt(orgId, e, i) {
      let path = e.recordPaths[i];
      let record = e.records[i];
      let doc = getAfter(path);
      let collection = record.collection;
      return record.keys().hasOnly(['entityType','entityId','version','collection'])
        && record.entityId is string && record.version is int
        && path == /databases/$(database)/documents/organizations/$(orgId)/$(collection)/$(record.entityId)
        && doc != null && doc.data.version == record.version
        && doc.data.remoteId == record.entityId && doc.data.protocol.entityType == record.entityType
        && doc.data.protocol.operationId == e.operationId && doc.data.updatedAt == request.time
        && payloadTypes(record.entityType, doc.data);
    }
    function exactEffects(orgId, e) {
      return e.records.size() <= 4 ? smallEffects(orgId, e) : tableEffects(orgId, e);
    }
    function smallEffects(orgId, e) {
      return e.records.size() > 0 && e.recordPaths.toSet().size() == e.records.size()
${Array.from({length:4},(_,i)=>`        && (e.records.size() <= ${i} || effectAt(orgId, e, ${i}))`).join('\n')};
    }
    function compactTableEffect(orgId, d, type, collection) {
      let proof = d.protocol.get('effect', null);
      // directShape binds remoteId to the collection's captured docId. Avoid
      // reconstructing the entire request path in every stock/lot write.
      return proof == null || proof == {'entityType':type,'entityId':d.remoteId,'version':d.version,'collection':collection};
    }
    function tableEffectAt(e, i, types) {
      let doc = getAfter(e.recordPaths[i]).data;
      return doc.protocol.entityType in types
        && doc.protocol.effect == e.records[i]
        && doc.protocol.operationId == e.operationId && doc.updatedAt == request.time;
    }
    function tableEffects(orgId, e) {
      // Bind event metadata through its first business effect. That effect's
      // own write rule already requires the same authenticated atomic receipt.
      // Reading the receipt here as well would consume an eleventh lookup for
      // a ten-effect event, beyond Firestore's per-write access-call budget.
      let first = getAfter(e.recordPaths[0]).data;
      let table = first.protocol.entityType in ${literal(tableTypes)};
      let consumption = first.protocol.entityType == 'labResult';
      let product = first.protocol.entityType == 'labProduct';
      let simple = first.protocol.entityType in ${literal(simpleTypes)};
      let types = table ? ${literal(tableTypes)} : consumption ? ${literal(consumptionTypes.filter(t=>t!=='labResult'))} : simple ? ${literal(simpleTypes)} : ${literal(labTypes)};
      return e.records.size() > 0 && e.records.size() <= (simple ? ${maxSimpleBusinessEffects} : ${maxBusinessEffects})
        && (product ? e.records.size() <= ${maxProductReferenceEffects} : (table || consumption || simple || e.records.size() <= ${maxLabDefinitionEffects}))
        && e.organizationId == orgId && first.organizationId == orgId
        && first.deviceId == e.deviceId && first.centralSequence == e.sequence
        && e.recordPaths.toSet().size() == e.records.size()
        && (simple && e.records.size() > ${maxBusinessEffects} ? simpleLargeEffects(orgId, e) : (
${Array.from({length:maxBusinessEffects},(_,i)=>`          ${i === 0 ? '' : '&& '}(e.records.size() <= ${i} || (product ? productEffectAt(e, ${i}, first.remoteId) : tableEffectAt(e, ${i}, ${i === 0 ? "consumption ? ['labResult'] : types" : 'types'})))`).join('\n')}));
    }
    function simpleLargeEffects(orgId, e) {
      let proof = getAfter(/databases/$(database)/documents/organizations/$(orgId)/simpleOperationProofs/$(e.operationId)).data;
      return proof.organizationId == orgId && proof.operationId == e.operationId
        && proof.sequence == e.sequence && proof.committedAt == request.time
        && proof.records == e.records && proof.recordPaths == e.recordPaths
        && tableEffectAt(e, 0, ${literal(simpleTypes)})
        && tableEffectAt(e, 1, ${literal(simpleTypes)});
    }
    function simpleProofAt(orgId, d, i) {
      let record = d.records[i];
      let path = d.recordPaths[i];
      let doc = getAfter(path).data;
      return path == /databases/$(database)/documents/organizations/$(orgId)/$(record.collection)/$(record.entityId)
        && doc.organizationId == orgId && doc.protocol.entityType in ${literal(simpleTypes)}
        && doc.protocol.effect == record && doc.protocol.operationId == d.operationId
        && doc.centralSequence == d.sequence && doc.updatedAt == request.time;
    }
    function simpleProofAllowed(orgId, d) {
      let first = getAfter(d.recordPaths[2]).data;
      return d.keys().hasOnly(['organizationId','operationId','sequence','records','recordPaths','committedAt'])
        && d.organizationId == orgId && d.records.size() > ${maxBusinessEffects}
        && d.records.size() <= ${maxSimpleBusinessEffects} && d.records.size() == d.recordPaths.size()
        && first.updatedBy == request.auth.uid && d.committedAt == request.time
${Array.from({length:10},(_,j)=>j+2).map(i=>`        && (d.records.size() <= ${i} || simpleProofAt(orgId, d, ${i}))`).join('\n')};
    }
    function productEffectAt(e, i, productId) {
      let doc = getAfter(e.recordPaths[i]).data;
      return (i == 0 ? doc.protocol.entityType == 'labProduct'
        : doc.protocol.entityType == 'labProductAnalysis' && doc.parentRefs.productId.entityId == productId)
        && doc.protocol.effect == e.records[i]
        && doc.protocol.operationId == e.operationId && doc.updatedAt == request.time;
    }
    function ledgerDelta(orgId, d, i) {
      let paths = d.protocol.ledgerPaths;
      return paths.size() <= i ? 0 : getAfter(paths[i]).data.quantityDelta;
    }
    function ledgerEffect(orgId, d, i) {
      let paths = d.protocol.ledgerPaths;
      let ledger = paths.size() <= i ? null : getAfter(paths[i]);
      return paths.size() <= i || (ledger != null
        && ledger.data.protocol.entityType == 'inventoryTransaction'
        && ledger.data.protocol.operationId == d.protocol.operationId
        && ledger.data.parentRefs.inventoryId.entityId == d.remoteId
        && ledger.data.organizationId == orgId && ledger.data.updatedAt == request.time);
    }
    function inventoryBalance(orgId, d) {
      let before = resource == null ? 0 : resource.data.currentQty;
      let delta = ${Array.from({length:8},(_,i)=>`ledgerDelta(orgId, d, ${i})`).join(' + ')};
      let lots = ${Array.from({length:8},(_,i)=>`lotDelta(orgId, d, ${i})`).join(' + ')};
      return d.currentQty is number && d.currentQty >= 0 && d.currentQty < 1000000000000000
        && d.protocol.ledgerPaths is list && d.protocol.ledgerPaths.size() <= 8
        && d.protocol.ledgerPaths.toSet().size() == d.protocol.ledgerPaths.size()
        && d.protocol.lotPaths is list && d.protocol.lotPaths.size() <= 8
        && d.protocol.lotPaths.toSet().size() == d.protocol.lotPaths.size()
        && d.protocol.get('consumptionPaths', []) is list
        && d.protocol.get('consumptionPaths', []).size() <= 4
        && (d.protocol.get('consumptionPaths', []).size() == 0
          || math.abs((${Array.from({length:4},(_,i)=>`consumptionDelta(d, ${i})`).join(' + ')}) - delta) <= 0.00000001 * (math.abs(delta) > 1 ? math.abs(delta) : 1))
        && math.abs(lots - delta) <= 0.00000001 * (math.abs(delta) > 1 ? math.abs(delta) : 1)
        && math.abs(d.currentQty - before - delta) <= 0.00000001 * (math.abs(before) > math.abs(d.currentQty) ? (math.abs(before) > 1 ? math.abs(before) : 1) : (math.abs(d.currentQty) > 1 ? math.abs(d.currentQty) : 1))
${Array.from({length:8},(_,i)=>`        && ledgerEffect(orgId, d, ${i})`).join('\n')};
    }
    function lotDelta(orgId, d, i) {
      let paths = d.protocol.lotPaths;
      let path = paths.size() <= i ? null : paths[i];
      let after = path == null ? null : getAfter(path);
      let before = path == null ? null : get(path);
      return path == null ? 0 : (after != null && after.data.organizationId == orgId
        && after.data.protocol.entityType == 'inventoryLot'
        && after.data.parentRefs.inventoryId.entityId == d.remoteId
        && after.data.protocol.operationId == d.protocol.operationId && after.data.updatedAt == request.time
        ? after.data.qtyRemaining - (before == null ? 0 : before.data.qtyRemaining) : 1000000000000000000);
    }
    function consumptionDelta(d, index) {
      let paths = d.protocol.get('consumptionPaths', []);
      let log = paths.size() <= index ? null : getAfter(paths[index]);
      return log == null ? 0 : (log.data.parentRefs.inventoryId.entityId == d.remoteId
        && log.data.protocol.entityType == 'consumption' && log.data.protocol.operationId == d.protocol.operationId
        && log.data.organizationId == d.organizationId && log.data.updatedAt == request.time
        ? (log.data.eventType == 'REVERSAL' ? log.data.appliedQty : -log.data.appliedQty) : 1000000000000000000);
    }
    function consumptionLinked(orgId, d) {
      let item = getAfter(/databases/$(database)/documents/organizations/$(orgId)/inventoryItems/$(d.parentRefs.inventoryId.entityId));
      let result = getAfter(/databases/$(database)/documents/organizations/$(orgId)/labResults/$(d.parentRefs.sampleTestId.entityId));
      return d.eventType in ['CONSUMPTION','REVERSAL']
        && item != null && item.data.organizationId == orgId
        && d.parentRefs.inventoryId == {'entityType':'inventoryItem','entityId':item.data.remoteId,'version':item.data.version}
        && item.data.get('deletedAt', null) == null
        && result != null && result.data.organizationId == orgId
        && d.parentRefs.sampleTestId == {'entityType':'labResult','entityId':result.data.remoteId,'version':result.data.version}
        && (result.data.get('deletedAt', null) == null || (d.eventType == 'REVERSAL' && d.parentRefs.get('reversalOfLogId', null) != null))
        && result.data.updatedAt == request.time
        && d.appliedQty >= 0 && d.requestedQty >= 0 && d.requestedQty < 1000000000000000
        && d.shortfallQty >= 0 && d.qtyUsed == (d.eventType == 'REVERSAL' ? -d.appliedQty : d.appliedQty)
        && math.abs(d.requestedQty - d.appliedQty - d.shortfallQty) <= 0.00000001 * (d.requestedQty > 1 ? d.requestedQty : 1)
        && result.data.protocol.operationId == d.protocol.operationId
        && (d.appliedQty == 0 || (item.data.protocol.operationId == d.protocol.operationId
          && (item.data.protocol.get('ledgerMode', '') == 'consumption_v1'
            ? d.protocol.get('ledgerMode', '') == 'consumption_v1' && d.parentRefs.get('lotId', null) != null
            : item.data.protocol.ledgerPaths.size() > 0)
          && item.data.protocol.get('consumptionPaths', []).hasAny([request.path])));
    }
    // Consumption is append-only: its optional parents can use a smaller
    // validator without the generic configuration/update exceptions.
    function consumptionParentValid(orgId, d, field, type, collection) {
      let ref = d.parentRefs[field];
      let parent = getAfter(/databases/$(database)/documents/organizations/$(orgId)/$(collection)/$(ref.entityId));
      return ref.version is int && ref.version > 0 && parent != null
        && parent.data.organizationId == orgId
        && ref == {'entityType':type,'entityId':parent.data.remoteId,'version':parent.data.version}
        && parent.data.get('deletedAt', null) == null
        && (type != 'inventoryLot' || d.appliedQty == 0 || d.protocol.get('ledgerMode', '') != 'consumption_v1'
          || (parent.data.protocol.get('ledgerMode', '') == 'consumption_v1'
            && parent.data.parentRefs.inventoryId.entityId == d.parentRefs.inventoryId.entityId
            && parent.data.protocol.operationId == d.protocol.operationId && parent.data.updatedAt == request.time))
        && (type != 'consumption' || deletionReversalValid(d, parent.data));
    }
    function tombstoneParentUnchanged(d, field) {
      let ref = d.parentRefs.get(field, {});
      let prior = resource.data.parentRefs.get(field, {});
      return resource.data.get('deletedAt', null) == null
        && ref.keys().hasOnly(['entityType','entityId','version'])
        && ref.entityType == prior.entityType && ref.entityId == prior.entityId
        && ref.version is int && ref.version > 0;
    }
    function deletionReversalValid(d, original) {
      // The optional-parent gate above already checks existence, tenant,
      // version and lifecycle; bind its business meaning here exactly once.
      return d.eventType == 'REVERSAL' && original.eventType == 'CONSUMPTION'
        && original.parentRefs.sampleTestId.entityId == d.parentRefs.sampleTestId.entityId
        && original.parentRefs.inventoryId.entityId == d.parentRefs.inventoryId.entityId
        && original.parentRefs.get('lotId', {}).get('entityId', null) == d.parentRefs.get('lotId', {}).get('entityId', null)
        && d.appliedQty > 0 && d.appliedQty <= original.appliedQty;
    }
    function lotLinked(orgId, d) {
      let item = getAfter(/databases/$(database)/documents/organizations/$(orgId)/inventoryItems/$(d.parentRefs.inventoryId.entityId));
      return d.qtyReceived >= 0 && d.qtyReceived < 1000000000000000
        && d.qtyRemaining >= 0 && d.qtyRemaining <= d.qtyReceived
        && (d.deletedAt == null || d.qtyRemaining == 0)
        && (resource == null || (d.qtyReceived == resource.data.qtyReceived
          && d.parentRefs.inventoryId.entityId == resource.data.parentRefs.inventoryId.entityId))
        && item.data.protocol.operationId == d.protocol.operationId
        && item.data.protocol.lotPaths.hasAny([request.path])
        && (item.data.protocol.get('ledgerMode', '') == 'consumption_v1') == (d.protocol.get('ledgerMode', '') == 'consumption_v1')
        && (d.protocol.get('ledgerMode', '') != 'consumption_v1' || (resource != null
          && item.data.protocol.get('ledgerMode', '') == 'consumption_v1'
          && math.abs(d.qtyRemaining - resource.data.qtyRemaining - lotConsumptionDelta(item.data, d.remoteId))
            <= 0.00000001 * (resource.data.qtyRemaining > 1 ? resource.data.qtyRemaining : 1)));
    }
    function lotConsumptionAt(item, lot, index) {
      let paths = item.protocol.get('consumptionPaths', []);
      let log = paths.size() <= index ? null : getAfter(paths[index]);
      return log == null || log.data.parentRefs.get('lotId', {}).get('entityId', '') != lot ? 0
        // The same freshly-written item's inventoryBalance validates every
        // path's type/tenant/operation/time. Here only select this lot's share;
        // repeating all those checks exceeds the expression budget.
        : (log.data.eventType == 'REVERSAL' ? log.data.appliedQty : -log.data.appliedQty);
    }
    function lotConsumptionDelta(item, lot) {
      return lotConsumptionAt(item, lot, 0) + lotConsumptionAt(item, lot, 1)
        + lotConsumptionAt(item, lot, 2) + lotConsumptionAt(item, lot, 3);
    }
    function adjustmentLinked(orgId, d) {
      let path = /databases/$(database)/documents/organizations/$(orgId)/inventoryItems/$(d.parentRefs.inventoryId.entityId);
      let before = get(path);
      let after = getAfter(path);
      return d.oldQty >= 0 && d.newQty >= 0
        && d.oldQty == before.data.currentQty && d.newQty == after.data.currentQty
        && after.data.protocol.operationId == d.protocol.operationId;
    }
    function ledgerLinked(orgId, d) {
      let id = d.parentRefs.inventoryId.entityId;
      let item = getAfter(/databases/$(database)/documents/organizations/$(orgId)/inventoryItems/$(id));
      return d.quantityDelta is number && math.abs(d.quantityDelta) < 1000000000000000
        && d.transactionType in ['OPENING_BALANCE','RECEIPT','ADJUSTMENT','CONSUMPTION','REVERSAL']
        && item.data.protocol.operationId == d.protocol.operationId
        && item.data.protocol.ledgerPaths.hasAny([request.path])
        && (item.data.protocol.get('consumptionPaths', []).size() == 0
          || consumptionMatchesLedger(orgId, item.data));
    }
    function consumptionMatchesLedger(orgId, item) {
      let consumed = ${Array.from({length:4},(_,i)=>`consumptionDelta(item, ${i})`).join(' + ')};
      let delta = ${Array.from({length:4},(_,i)=>`(item.protocol.ledgerPaths.size() > ${i} ? ledgerDeltaAt(orgId, item, item.protocol.ledgerPaths[${i}]) : 0)`).join(' + ')};
      return math.abs(consumed - delta) <= 0.00000001 * (math.abs(delta) > 1 ? math.abs(delta) : 1);
    }
    function sampleDecision(orgId, d) {
      let quantity = quantityNumber(d.get('quantity', null));
      let rejected = quantityNumber(d.get('rejectedQuantity', null));
      return d.decisionStatus in ['', 'PENDING','APPROVED','CONDITIONAL_APPROVAL','PARTIAL_REJECTION','FULL_REJECTION']
        && quantity >= 0 && quantity < 1000000000000000 && rejected >= 0 && rejected <= quantity
        && (resource == null
          ? (d.decisionStatus in ['', 'PENDING'] ? true : initialDecisionAllowed(d.decisionStatus))
          : (d.decisionStatus == resource.data.get('decisionStatus', '') ? true : sampleDecisionHistory(d)));
    }
    function initialDecisionAllowed(status) {
      let profile = userDoc(request.auth.uid);
      return profile.data.role in ['admin','quality_manager','lab'] ? true
        : roleCan(status in ['PARTIAL_REJECTION','FULL_REJECTION'] ? 'qc.reject' : 'qc.approve');
    }
    function sampleDecisionHistory(d) {
      let path = d.protocol.qualityHistoryPath;
      let history = path == null ? null : getAfter(path);
      return history != null
        && history.data.protocol.entityType == 'qualityCheck'
        && history.data.protocol.operationId == d.protocol.operationId
        && history.data.parentRefs.inspectionId.entityId == d.remoteId
        && history.data.oldStatus == resource.data.get('decisionStatus', '')
        && history.data.newStatus == d.decisionStatus;
    }
    function quantityValid(raw) {
      return raw == null || raw == '' || (raw is string && raw.matches('^[0-9]+([.,][0-9]+)?$')
        && float(raw.replace(',', '.')) < 1000000000000000);
    }
    function quantityNumber(raw) { return raw == null || raw == '' ? 0 : float(raw.replace(',', '.')); }
    function qualityHistory(orgId, d) {
      let id = d.parentRefs.inspectionId.entityId;
      let before = get(/databases/$(database)/documents/organizations/$(orgId)/samples/$(id));
      let sample = getAfter(/databases/$(database)/documents/organizations/$(orgId)/samples/$(id));
      return sample.data.protocol.operationId == d.protocol.operationId
        && sample.data.protocol.qualityHistoryPath == request.path
        && d.oldStatus == (before == null ? '' : before.data.decisionStatus)
        // The qualityChecks create rule already gates this exact newStatus
        // on qc.approve/qc.reject. Do not repeat that role evaluation here.
        && d.newStatus == sample.data.decisionStatus;
    }
    function productSampleDecisionValid(orgId, d) {
      let id = d.get('nonConformanceRemoteId', '');
      let finding = id is string && id.size() > 0
        ? getAfter(/databases/$(database)/documents/organizations/$(orgId)/qcFindingsNc/$(id)) : null;
      return d.get('decisionStatus', '') in [null,'','PENDING','APPROVED','CONDITIONAL_APPROVAL','PARTIAL_REJECTION','FULL_REJECTION','NON_CONFORMANCE']
        && (d.get('decisionStatus', '') != 'NON_CONFORMANCE'
          || (finding != null && finding.data.get('deletedAt', null) == null
            && finding.data.parentRefs.productSampleId.entityId == d.remoteId));
    }
    function productFindingLinkValid(orgId, d) {
      let id = d.parentRefs.get('productSampleId', {}).get('entityId', '');
      let before = resource == null ? '' : resource.data.get('parentRefs', {}).get('productSampleId', {}).get('entityId', '');
      let sample = id.size() > 0 ? getAfter(/databases/$(database)/documents/organizations/$(orgId)/productBatchSamples/$(id)) : null;
      return (resource == null || id == before)
        && (d.get('deletedAt', null) == null || sample == null
          || sample.data.get('deletedAt', null) != null
          || sample.data.get('decisionStatus', '') != 'NON_CONFORMANCE'
          || sample.data.get('nonConformanceRemoteId', '') != d.remoteId);
    }
    function rolePermissionGranted(role, perm) {
      return perm in ['samples.create','samples.update','lab_results.create','lab_results.update','qc.write','reports.create']
        ? role in ['admin','quality_manager','lab','trial_owner']
        : perm in ['qc.approve','qc.reject','users.read','audit.read']
        ? role in ['admin','quality_manager','lab']
        : perm in ['org.update','users.create','users.update','users.disable','devices.read','devices.update']
        ? role in ['admin']
        : perm in rolePermissions(role);
    }
${entries.map(([t,d])=>keys(t,d)+'\n'+shape(t,d)).join('\n')}
    // END GENERATED DIRECT DOMAIN RULES`;
// The structural replacements use LF; normalize Windows checkouts first.
let rules = fs.readFileSync(target,'utf8').replace(/\r\n/g, '\n');
const marker = /    \/\/ BEGIN GENERATED DIRECT DOMAIN RULES[\s\S]*?    \/\/ END GENERATED DIRECT DOMAIN RULES/;
if (marker.test(rules)) rules=rules.replace(marker,()=>generated);
else rules=rules.replace('    // ── identity helpers', ()=>generated+'\n\n    // ── identity helpers');
// One generated shape gate per existing collection permission branch. The
// administrative members contract remains independent of domain writes.
for (const collection of new Set(entries.map(([,d])=>d.collection))) {
  const compactCollection = [...tableTypes,...labTypes,...consumptionTypes,...productTypes,...simpleTypes]
    .some(t=>manifest.entities[t].collection === collection);
  const defs = entries.filter(([,d])=>d.collection===collection).sort(([a],[b]) => a === 'secureFieldSubmission' ? -1 : b === 'secureFieldSubmission' ? 1 : 0);
  const condition = defs.map(([t,d])=>d.collection==='labConfig'
    ? `(request.resource.data.configType == ${q(d.table)} && shape_${t}(orgId, request.resource.data))`
    : `shape_${t}(orgId, request.resource.data)`).join('\n            || ');
  const re = new RegExp(`(      match /${collection}/\\{docId\\} \\{)([\\s\\S]*?)(?=\\n      \\})`);
  rules=rules.replace(re,(_,head,body)=>{
    body=body.replace(/\n        function directShape\(\) \{[\s\S]*?\n        \}/,'');
    body=body.replace(/ && directShape\(\)/g,'').replace(/^\s*\n/, '\n');
    // Apply to writes without altering existing, narrower role checks.
    body=body.replace(/(allow (?:create|update): if [\s\S]*?)(;)/g, (_, condition, end) => condition.replaceAll('can(orgId, ', 'roleCan(') + ' && directShape()' + end);
    return head+`\n        function directShape() {\n          return ${compactCollection ? 'request.resource.data.remoteId == docId && ' : ''}(${condition});\n        }`+body;
  });
}
// Apply the same QC audit and bounded atomic contract exercised by the direct
// normal-user emulator suite. Never deploy from this generation command.
rules = require('./qc_audit_rules_candidate').candidate(rules);
rules = require('./secure_field_rules_candidate').candidate(rules);
rules = rules.replace(/d\.block < \d+/g, `d.block < ${maxChemicalDefinitionProofBlocks}`);
rules = rules.replace(/\n      match \/simpleOperationProofs\/\{proofId\} \{[\s\S]*?\n      \}/, '');
rules = rules.replace('      match /analysisDefinitionProofs/{proofId} {', `      match /simpleOperationProofs/{proofId} {
        allow create: if signedIn() && proofId == request.resource.data.operationId
          && simpleProofAllowed(orgId, request.resource.data);
        allow read, update, delete: if false;
      }
      match /analysisDefinitionProofs/{proofId} {`);
rules = rules.replace(/request\.resource\.data\.recordPaths\.size\(\) <= \d+/g,
  `request.resource.data.recordPaths.size() <= ${maxSimpleBusinessEffects}`);
// Expanded consumption children share the event's fresh labResult. Its own
// write keeps the authenticated receipt check; tableEffects binds every image
// to that same atomic operation. Avoid repeating that receipt traversal on
// each stock/lot child. A root without an expanded proof still has the four-
// record small-event ceiling, so no root can bypass the receipt anchor.
rules = rules.replace(/\n    function expandedDomainLinked\(orgId, d\) \{[\s\S]*?\n    \}/, '');
rules = rules.replace(/function directBusinessLinked\(orgId\) \{[\s\S]*?\n    \}/, `function directBusinessLinked(orgId) {
      return request.resource.data.protocol.get('effect', null) == null ? smallBusinessLinked(orgId)
        : expandedDomainLinked(orgId, request.resource.data);
    }
    function expandedDomainLinked(orgId, d) {
      return d.protocol.entityType == 'labProductAnalysis'
        || (d.protocol.get('ledgerMode', '') == 'consumption_v1' && d.protocol.entityType != 'labResult')
        ? compactChildLinked(orgId) : expandedBusinessLinked(orgId);
    }`);
// Generate both paths from one source, leaving the verified small-operation
// expression budget unchanged. Regeneration must not duplicate the child gate.
rules = rules.replace(/\n    function compactChildLinked\(orgId\) \{[\s\S]*?\n    \}/, '');
rules = rules.replace(/function smallBusinessLinked\(orgId\) \{[\s\S]*?\n    \}/, block => {
  const small = block.replace(/event\.data\.records\.size\(\) <= [^\n]+/, 'event.data.records.size() <= 4');
  return small + '\n    ' + small.replace('function smallBusinessLinked(', 'function compactChildLinked(')
    .replace('event.data.records.size() <= 4', `event.data.records.size() <= ${maxBusinessEffects}`);
});
if ((rules.match(/payloadTypes\(record.entityType, doc.data\)/g) || []).length !== 1) throw Error('Small-event payload type validation is missing');
// Avoid rebuilding the expanded role permission list for every common write
// check. The fast groups are checked exhaustively against the Dart matrix.
rules = rules.replace(/(function roleCan\(perm\) \{[\s\S]*?)(?=    function can\(orgId, perm\))/, (_, block) =>
  block.replace(/perm in rolePermissions\(([^)]+)\)/g, 'rolePermissionGranted($1, perm)'));
rules = rules.replace(/[\t ]+$/gm, '');
if (Buffer.byteLength(rules)>250000) throw Error('Rules source exceeds safe source budget');
if(process.argv.includes('--check')) {
  if(fs.readFileSync(target,'utf8').replace(/\r\n/g,'\n')!==rules.replace(/\r\n/g,'\n')) throw Error('Generated rules drift; run generate_rules.js');
} else fs.writeFileSync(output,rules);
module.exports={};
