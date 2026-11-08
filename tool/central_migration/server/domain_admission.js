const {hashPayload} = require('./commands');
const {definition} = require('./domain_commands');
const fail = (code, messageAr) => ({code, messageAr});
const keyOf = ref => `${ref.entityType}/${ref.entityId}`;

/** The key is based on global parents, never an origin device's row number. */
function uniqueClaims(entityType, entityId, record, parentRefs) {
  const def = definition(entityType);
  return def.unique.flatMap(rule => {
    if (rule.where && !/^deleted_at\s+IS\s+NULL$/i.test(rule.where)) {
      throw new Error(`Unimplemented unique predicate for ${entityType}: ${rule.where}`);
    }
    if (rule.where && record.deletedAt) return [];
    let nested = {};
    if (typeof record.payload === 'string') nested = JSON.parse(record.payload);
    const values = rule.fields.map((field, index) => {
      const relation = parentRefs && parentRefs[field];
      let value = relation ? keyOf(relation) : record[field] ?? nested[rule.columns[index]];
      if (value == null) return null; // SQLite permits repeated NULL keys.
      if (rule.collations[index] === 'NOCASE' && typeof value === 'string') {
        value = value.replace(/[A-Z]/g, letter => letter.toLowerCase());
      } else if (rule.collations[index] === 'RTRIM' && typeof value === 'string') {
        value = value.replace(/ +$/, '');
      } else if (!['NOCASE','RTRIM','BINARY'].includes(rule.collations[index])) {
        throw new Error(`Unsupported collation ${rule.collations[index]}`);
      }
      return value;
    });
    if (values.some(value => value === null)) return [];
    return [{key: hashPayload({entityType, fields: rule.fields, values}), entityType, entityId}];
  });
}

function validateRelations(prepared, parents, organizationId) {
  const pending = new Map(prepared.map(item => [keyOf(item.write), item]));
  for (const {write, current} of prepared) {
    for (const ref of Object.values(write.relations || {})) {
      const inAction = pending.get(keyOf(ref));
      const existing = inAction ? inAction.current : parents.get(keyOf(ref));
      if (ref.expectedVersion === 0) {
        if (!inAction || inAction.write.operation !== 'create' || existing) {
          return fail('PARENT_MISSING_OR_DELETED', 'الأب لا ينشأ ضمن العملية.');
        }
      } else if (!existing || existing.version !== ref.expectedVersion) {
        return fail('VERSION_CONFLICT', 'تغير إصدار أحد مراجع العملية.');
      }
      const effective = inAction ? {...(inAction.current || {}), ...inAction.write.payload,
        organizationId, deletedAt: inAction.write.operation === 'tombstone' ? true : null,
        parentRefs: inAction.write.relations || {}} : existing;
      if (!effective || effective.organizationId !== organizationId) return fail('WRONG_ORG', 'مؤسسة الأب غير متطابقة.');
      const unchanged = current && Object.values(current.parentRefs || {}).some(prior => keyOf(prior) === keyOf(ref));
      if (effective.deletedAt && write.operation !== 'tombstone' && !unchanged) {
        return fail('PARENT_MISSING_OR_DELETED', 'الأب محذوف.');
      }
      if (ref.entityType === 'sample' && write.entityType === 'productBatchSample') {
        if (ref.expectedVersion === 0) return fail('PARENT_MISSING_OR_DELETED', 'فحص التشغيلة يجب أن يكون معتمدًا أولًا.');
        if (effective.inspectionKind !== 'product') return fail('PARENT_WRONG_TYPE', 'العينة التشغيلية تحتاج فحص منتج.');
      }
      const parentDef = definition(ref.entityType);
      if (parentDef.collection === 'labConfig' && effective.configType !== parentDef.table) {
        return fail('PARENT_WRONG_TYPE', 'نوع مرجع إعدادات المعمل غير متطابق.');
      }
    }
  }
  return null;
}

/** The balance and its ledger must move together, including opening stock. */
function validateInventoryEffects(prepared) {
  const items = new Map(prepared.filter(item => item.write.entityType === 'inventoryItem')
    .map(item => [item.write.entityId, item]));
  const deltas = new Map();
  for (const {write} of prepared) {
    if (write.entityType !== 'inventoryTransaction') continue;
    const parent = write.relations && write.relations.inventoryId;
    const delta = write.payload.quantityDelta;
    if (!parent || typeof delta !== 'number' || !Number.isFinite(delta)) {
      return fail('BAD_PAYLOAD', 'حركة مخزون غير صالحة.');
    }
    if (!items.has(parent.entityId)) return fail('BAD_PAYLOAD', 'حركة المخزون تحتاج تحديث رصيدها في العملية نفسها.');
    deltas.set(parent.entityId, (deltas.get(parent.entityId) || 0) + delta);
  }
  for (const [id, {write, current}] of items) {
    const before = current ? current.currentQty : 0;
    const after = write.payload.currentQty === undefined ? before : write.payload.currentQty;
    if (typeof before !== 'number' || !Number.isFinite(before) || typeof after !== 'number' ||
        !Number.isFinite(after) || after < 0 || Math.abs(after - before - (deltas.get(id) || 0)) > 1e-8 * Math.max(1, Math.abs(after), Math.abs(before))) {
      return fail('VALUE_OUT_OF_RANGE', 'تغير رصيد المخزون لا يطابق حركاته.');
    }
  }
  return null;
}

module.exports = {uniqueClaims, validateRelations, validateInventoryEffects, keyOf};
