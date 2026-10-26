'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const {
  hashPayload,
  validatePayload,
  validateSessionFrame,
  validateMembership,
  roleCan,
} = require('../commands.js');

// operationId matching what the Dart side mints (uuid v4, <= 64 chars).
const OP = '6f9e3b0a1c2d4e5f8081a2b3c4d5e6f7';
const SAMPLE_FIELDS = ['sampleName', 'quantity'];

function frame(patch) {
  const out = Object.assign(
    {
      schemaVersion: 2,
      organizationId: 'org-1',
      commandType: 'sample.create',
      operationId: OP,
      entityId: 'P-1',
      expectedVersion: 0,
      deviceId: 'dev-1',
      payload: {sampleName: 'Cement A', quantity: 3},
      dependencies: {parent_sample: 'P-1'},
    },
    patch,
  );
  if (out.payloadHash === undefined) out.payloadHash = hashPayload(out.payload);
  return out;
}

// ── hashPayload ─────────────────────────────────────────────────────────────
test('hashPayload is canonical (key order independent)', () => {
  assert.strictEqual(
    hashPayload({sampleName: 'X', quantity: 5}),
    hashPayload({quantity: 5, sampleName: 'X'}),
  );
});

test('hashPayload changes when content changes', () => {
  assert.notStrictEqual(
    hashPayload({sampleName: 'X'}),
    hashPayload({sampleName: 'Y'}),
  );
});

// ── validateSessionFrame ──────────────────────────────────────────────────
test('validateSessionFrame accepts a well-formed frame', () => {
  assert.strictEqual(validateSessionFrame(frame()), null);
});

test('validateSessionFrame rejects drifted/foreign frames', () => {
  assert.strictEqual(
    validateSessionFrame(frame({schemaVersion: 3})).code,
    'SCHEMA_VERSION_MISMATCH',
  );
  assert.strictEqual(
    validateSessionFrame(frame({payloadHash: 'f'.repeat(64)})).code,
    'BAD_PAYLOAD',
  );
  assert.strictEqual(
    validateSessionFrame(frame({operationId: 'short'})).code,
    'BAD_PAYLOAD',
  );
  assert.strictEqual(
    validateSessionFrame(frame({operationId: 'x'.repeat(65)})).code,
    'BAD_PAYLOAD',
  );
  assert.strictEqual(
    validateSessionFrame(frame({commandType: 'nope'})).code,
    'BAD_COMMAND_TYPE',
  );
  assert.strictEqual(
    validateSessionFrame(frame({entityId: ''})).code,
    'BAD_PAYLOAD',
  );
  assert.strictEqual(
    validateSessionFrame(frame({expectedVersion: -1})).code,
    'BAD_PAYLOAD',
  );
  // `deviceId` shape/trust is NOT the frame validator's job (validated
  // against the Firestore device docs in the transaction), only presence.
  assert.strictEqual(validateSessionFrame(frame({deviceId: undefined})).code,
    'BAD_PAYLOAD');
});

// ── validatePayload ────────────────────────────────────────────────────────
test('validatePayload enforces the sample field allow-list', () => {
  assert.strictEqual(validatePayload('sample', 'create', {
    sampleName: 'X',
    quantity: 3,
  }), null);

  assert.strictEqual(
    validatePayload('sample', 'create', {eval: 'x'}).code,
    'BAD_PAYLOAD',
  );
  assert.strictEqual(
    validatePayload('sample', 'delete', {sampleName: 'X'}).code,
    'BAD_PAYLOAD',
  );
  assert.strictEqual(
    validatePayload('sample', 'create', {inspectionDate: 'not-a-date'})
        .code,
    'BAD_PAYLOAD',
  );
  assert.strictEqual(
    validatePayload('sample', 'create', {inspectionDate: '2026-10-25'}),
    null,
  );
});

// ── validateMembership ─────────────────────────────────────────────────────
const commandDef = {permission: 'samples.create', entity: 'sample'};
const orgData = {status: 'trial'};

test('an active member with the role passes', () => {
  assert.strictEqual(
    validateMembership(
      {organizationId: 'org-1', role: 'lab', status: 'active'},
      'org-1',
      orgData,
      commandDef,
      'dev-1',
    ),
    null,
  );
});

test('memberships and devices are gated', () => {
  assert.strictEqual(
    validateMembership(
      {organizationId: 'other-org', role: 'lab', status: 'active'},
      'org-1',
      orgData,
      commandDef,
      'dev-1',
    ).code,
    'WRONG_ORG',
  );
  assert.strictEqual(
    validateMembership(
      {organizationId: 'org-1', role: 'lab', status: 'pending'},
      'org-1',
      orgData,
      commandDef,
      'dev-1',
    ).code,
    'MEMBERSHIP_PENDING',
  );
  assert.strictEqual(
    validateMembership(
      {organizationId: 'org-1', role: 'viewer', status: 'active'},
      'org-1',
      orgData,
      commandDef,
      'dev-1',
    ).code,
    'PERMISSION_DENIED',
  );
  assert.strictEqual(
    validateMembership(
      {organizationId: 'org-1', role: 'lab', status: 'active'},
      'org-1',
      orgData,
      commandDef,
      '',
    ).code,
    'DEVICE_UNTRUSTED',
  );
  assert.strictEqual(
    validateMembership(
      {organizationId: 'org-1', role: 'lab', status: 'active'},
      'org-1',
      {status: 'suspended'},
      commandDef,
      'dev-1',
    ).code,
    'ORG_SUSPENDED',
  );
});

// ── roleCan ────────────────────────────────────────────────────────────────
test('roleCan mirrors the rules file (viewer never writes samples)', () => {
  assert.ok(!roleCan('viewer', 'samples.create'));
  assert.ok(roleCan('lab', 'samples.create'));
  assert.ok(roleCan('admin', 'samples.update'));
  assert.ok(!roleCan('trial_owner', 'samples.delete_perm'));
});


test('typed canonical payload contract covers numeric and Unicode edge cases', () => {
  const vectors = require('./fixtures/command_hash_vectors.json');
  for (const vector of vectors) assert.equal(hashPayload(vector.payload), vector.hash, vector.label);
  assert.equal(hashPayload({n: 1}), hashPayload({n: 1.0}));
  assert.equal(hashPayload({n: -0}), hashPayload({n: 0}));
  assert.throws(() => hashPayload({n: Infinity}));
});
test('frame paths, versions and dependency types fail closed', () => {
  for (const patch of [{expectedVersion: '1'}, {expectedVersion: 1.5}, {expectedVersion: NaN},
    {operationId: 'bad/path-id'}, {entityId: 'a/b'}, {organizationId: '../other'},
    {deviceId: 'a/b'}, {dependencies: []}, {dependencies: {parent_sample: 42}}]) {
    assert.equal(validateSessionFrame(frame(patch)).code, 'BAD_PAYLOAD');
  }
});
test('typed payload never silently coerces clinical values', () => {
  for (const payload of [{quantity: '3'}, {quantity: -1}, {sampleName: {}}, {inspectionDate: '2026-02-31'}]) {
    assert.equal(validatePayload('sample', 'create', payload).code, 'BAD_PAYLOAD');
  }
});

test('every backend role exactly mirrors the Firestore permission matrix', () => {
  const fs = require('node:fs');
  const path = require('node:path');
  const rules = fs.readFileSync(path.join(__dirname, '../../firestore.rules'), 'utf8');
  const {ROLE_PERMISSIONS} = require('../commands');
  const parsed = new Map([...rules.matchAll(/role == '([^']+)' \? \[([\s\S]*?)\]/g)]
    .map(match => [match[1], [...match[2].matchAll(/'([^']+)'/g)].map(item => item[1]).sort()]));
  assert.deepEqual([...parsed.keys()].sort(), Object.keys(ROLE_PERMISSIONS).sort());
  for (const [role, permissions] of parsed) assert.deepEqual([...ROLE_PERMISSIONS[role]].sort(), permissions, role);
  for (const unknown of ['__proto__', 'constructor', 'toString', 'unknown']) assert.equal(roleCan(unknown, 'samples.create'), false);
});
