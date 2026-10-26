/** Trusted validation for an entire domain write set, before any effect. */
const {roleCan} = require('./commands');
const manifest = require('./domain_manifest.json');

const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const safeId = value => typeof value === 'string' && value.length > 0 && value.length <= 256 &&
  !value.includes('/') && !/[\x00-\x1f]/.test(value) && value !== '.' && value !== '..' && !/^__.*__$/.test(value);
const fail = (code, messageAr) => ({code, messageAr});
const rejected = value => /reject|رفض/i.test(String(value || ''));
const decisionCodes = ['APPROVED','CONDITIONAL_APPROVAL','PARTIAL_REJECTION','FULL_REJECTION'];

// The existing inspection schema stores optional quantities as numeric text,
// including a decimal comma. Preserve that format while rejecting non-finite
// values; do not narrow the real UI contract to the old pilot's number-only DTO.
function numericText(value) {
  if (value === undefined || value === null || value === '') return null;
  if (typeof value === 'number') return Number.isFinite(value) && value >= 0 ? value : NaN;
  if (typeof value !== 'string') return NaN;
  const text = value.trim().replaceAll(',', '.');
  if (text === '') return null;
  if (!/^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$/.test(text)) return NaN;
  const result = Number(text);
  return Number.isFinite(result) && result >= 0 ? result : NaN;
}

function definition(type) {
  return Object.hasOwn(manifest.entities, type) ? manifest.entities[type] : null;
}

function validateWriteSet(payload, role, organizationId) {
  if (!object(payload) || Object.keys(payload).some(key => key !== 'writes') ||
      !Array.isArray(payload.writes) || payload.writes.length < 1 || payload.writes.length > 1000) {
    return fail('BAD_PAYLOAD', 'مجموعة تغييرات غير صالحة.');
  }
  const identities = new Set();
  for (const write of payload.writes) {
    if (!object(write) || Object.keys(write).some(key =>
      !['entityType','entityId','operation','expectedVersion','payload','relations'].includes(key))) {
      return fail('BAD_PAYLOAD', 'إطار تغيير غير صالح.');
    }
    const def = definition(write.entityType);
    if (!def || !safeId(write.entityId) ||
        !['create','update','tombstone'].includes(write.operation) || !object(write.payload)) {
      return fail('BAD_PAYLOAD', 'كيان أو هوية أو عملية غير صالحة.');
    }
    const identity = `${def.collection}/${write.entityId}`;
    if (identities.has(identity)) return fail('BAD_PAYLOAD', 'هوية مكررة داخل العملية.');
    identities.add(identity);
    const relations = write.relations || {};
    if (!object(relations)) return fail('BAD_PAYLOAD', 'علاقات غير صالحة.');
    for (const [name, ref] of Object.entries(relations)) {
      const declared = def.parents.find(parent => parent.relation === name);
      if (!declared || !object(ref) || Object.keys(ref).some(key => !['entityType','entityId','expectedVersion'].includes(key)) ||
          ref.entityType !== declared.type || !safeId(ref.entityId) ||
          !Number.isSafeInteger(ref.expectedVersion) || ref.expectedVersion < 0) {
        return fail('BAD_PAYLOAD', 'هوية عالمية غير صالحة لأحد الروابط.');
      }
      if (ref.expectedVersion === 0 && !payload.writes.some(target =>
        target.entityType === ref.entityType && target.entityId === ref.entityId && target.operation === 'create')) {
        return fail('PARENT_MISSING_OR_DELETED', 'الأب غير معتمد ولا ينشأ ضمن العملية.');
      }
    }
    for (const parent of def.parents) {
      if (write.entityType === 'sample' && parent.relation === 'materialId' && write.payload.inspectionKind === 'product') continue;
      if (parent.required && !relations[parent.relation]) return fail('PARENT_MISSING_OR_DELETED', 'الرابط المطلوب غير معتمد.');
    }
    if (!Number.isSafeInteger(write.expectedVersion) || write.expectedVersion < 0 ||
        write.expectedVersion >= Number.MAX_SAFE_INTEGER ||
        (write.operation === 'create' && write.expectedVersion !== 0) ||
        (write.operation !== 'create' && write.expectedVersion < 1)) {
      return fail('BAD_PAYLOAD', 'إصدار متوقع غير صالح.');
    }
    if (def.appendOnly && write.operation !== 'create') {
      return fail('IMMUTABLE_RECORD', 'السجل الإلحاقي لا يُعدّل ولا يُحذف.');
    }
    let permission = def.permission;
    if (write.entityType === 'sample' && write.operation === 'create') permission = 'samples.create';
    if (write.entityType === 'qualityCheck') {
      permission = rejected(write.payload.newStatus) ? 'qc.reject' : 'qc.approve';
    }
    if (write.entityType === 'member') {
      permission = write.operation === 'create' ? 'users.create' :
        (write.operation === 'tombstone' || write.payload.status === 'disabled' ? 'users.disable' : 'users.update');
    }
    if (!permission || !roleCan(role, permission)) return fail('PERMISSION_DENIED', 'صلاحية التغيير غير متاحة.');
    if (write.payload.organizationId !== undefined && write.payload.organizationId !== organizationId) {
      return fail('WRONG_ORG', 'مؤسسة السجل غير متطابقة.');
    }
    for (const [key, value] of Object.entries(write.payload)) {
      if (!def.fields.includes(key)) return fail('BAD_PAYLOAD', `حقل غير مسموح: ${key}`);
      if (typeof value === 'number' && (!Number.isFinite(value) ||
          (Number.isInteger(value) && !Number.isSafeInteger(value)))) {
        return fail('VALUE_OUT_OF_RANGE', 'قيمة عددية غير صالحة.');
      }
      if ((key.endsWith('Json') || key === 'payload') && value !== null && value !== '') {
        if (typeof value !== 'string') return fail('BAD_PAYLOAD', 'حقل JSON غير صالح.');
        try {
          const decoded = JSON.parse(value);
          if (!object(decoded) && !Array.isArray(decoded)) return fail('BAD_PAYLOAD', 'بنية JSON غير صالحة.');
        } catch (_) { return fail('BAD_PAYLOAD', 'حقل JSON غير صالح.'); }
      }
    }
    const managed = new Set(['createdAt','createdBy','updatedAt','updatedBy','version','deletedAt','deviceId','remoteId']);
    for (const [field, column] of Object.entries(def.sqlFields || {})) {
      if (managed.has(field)) continue;
      const value = write.payload[field];
      if (value === undefined) {
        if (write.operation === 'create' && column.required && !column.hasDefault &&
            !(write.relations || {})[field] &&
            !(write.entityType === 'sample' && write.payload.inspectionKind === 'product' && field === 'materialId')) {
          return fail('BAD_PAYLOAD', `حقل مطلوب: ${field}`);
        }
        continue;
      }
      if (value === null) {
        if (column.required && !(write.relations || {})[field]) return fail('BAD_PAYLOAD', `حقل لا يقبل قيمة فارغة: ${field}`);
        continue;
      }
      if ((def.actors || []).includes(field)) {
        if (!safeId(value)) return fail('BAD_PAYLOAD', 'هوية صاحب السجل غير صالحة.');
      } else if (/INT|REAL|FLOAT|DOUBLE|NUMERIC/i.test(column.type)) {
        if (typeof value !== 'number' || !Number.isFinite(value) ||
            (/INT/i.test(column.type) && !Number.isSafeInteger(value))) return fail('BAD_PAYLOAD', `نوع حقل عددي غير صالح: ${field}`);
      } else if (/TEXT|CHAR|CLOB/i.test(column.type) && typeof value !== 'string') {
        return fail('BAD_PAYLOAD', `نوع حقل نصي غير صالح: ${field}`);
      }
    }
    if (def.payloadFields && write.payload.payload != null) {
      const nested = JSON.parse(write.payload.payload);
      if (!object(nested) || Object.keys(nested).some(key => !def.payloadFields.includes(key))) {
        return fail('BAD_PAYLOAD', 'محتوى إعدادات المعمل غير مسموح.');
      }
      if (write.payload.configType !== def.table) return fail('BAD_PAYLOAD', 'نوع إعدادات المعمل غير متطابق.');
    }
    if (write.entityType === 'organizationSetting' &&
        !manifest.sharedSettingKeys.includes(write.payload.key)) return fail('BAD_PAYLOAD', 'الإعداد خاص بالجهاز أو غير مسموح بمشاركته.');
    if (write.entityType === 'sample' && write.payload.decisionStatus != null &&
        !['', 'PENDING', ...decisionCodes].includes(write.payload.decisionStatus)) {
      return fail('BAD_PAYLOAD', 'حالة فحص غير معروفة.');
    }
  }
  return null;
}

/** State-dependent checks use records read in the same server transaction. */
function validateAgainstCurrent(write, current, role, allWrites) {
  if (write.operation === 'create') {
    if (current) return fail('VERSION_CONFLICT', 'السجل موجود بالفعل.');
  } else {
    if (!current) return fail('NOT_FOUND', 'السجل غير موجود.');
    if (current.deletedAt) return fail('DELETED_CANNOT_MODIFY', 'السجل محذوف.');
    if (current.version !== write.expectedVersion) return fail('VERSION_CONFLICT', 'تغير إصدار السجل.');
    for (const key of ['entryCode', 'remoteId', 'organizationId']) {
      if (current[key] !== undefined && write.payload[key] !== undefined &&
          current[key] !== write.payload[key]) return fail('BAD_PAYLOAD', 'هوية السجل ثابتة.');
    }
  }
  const next = {...(current || {}), ...write.payload};
  if (write.entityType === 'sample') {
    const quantity = numericText(next.quantity);
    const rejectedQuantity = numericText(next.rejectedQuantity);
    if (Number.isNaN(quantity)) {
      return fail('VALUE_OUT_OF_RANGE', 'كمية الفحص غير صالحة.');
    }
    if (Number.isNaN(rejectedQuantity) || (quantity !== null && rejectedQuantity !== null && rejectedQuantity > quantity)) {
      return fail('VALUE_OUT_OF_RANGE', 'الكمية المرفوضة غير صالحة.');
    }
    if (current && next.decisionStatus !== current.decisionStatus) {
      if (!roleCan(role, rejected(next.decisionStatus) ? 'qc.reject' : 'qc.approve')) {
        return fail('PERMISSION_DENIED', 'قرار الجودة يحتاج صلاحية الاعتماد.');
      }
      const history = allWrites.filter(item => item.entityType === 'qualityCheck' &&
        item.relations && item.relations.inspectionId && item.relations.inspectionId.entityId === write.entityId &&
        item.payload.newStatus === next.decisionStatus && item.payload.oldStatus === current.decisionStatus);
      if (history.length !== 1) return fail('BAD_PAYLOAD', 'قرار الجودة وسجل تاريخه يجب أن يعتمدا معًا.');
    }
  }
  if (write.entityType === 'inventoryLot') {
    if (![next.qtyReceived, next.qtyRemaining].every(value => typeof value === 'number' &&
        Number.isFinite(value) && value >= 0) || next.qtyRemaining > next.qtyReceived) {
      return fail('VALUE_OUT_OF_RANGE', 'رصيد التشغيلة غير صالح.');
    }
  }
  return null;
}

module.exports = {definition, validateWriteSet, validateAgainstCurrent, safeId};
