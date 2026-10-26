'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const {validateMembership, profileRoles, validRoleSet} = require('../commands');

const profile = {organizationId: 'org', status: 'active', role: 'lab', roles: ['lab', 'nutritionist']};
const check = (member, permission) => validateMembership(member, 'org', {status: 'active'}, {permission}, 'writer');

test('combined roles grant both jobs without granting member management', () => {
  assert.equal(check(profile, 'samples.create'), null);
  assert.equal(check(profile, 'formulations.create'), null);
  assert.equal(check(profile, 'users.create').code, 'PERMISSION_DENIED');
  assert.equal(check({...profile, status: 'disabled'}, 'samples.create').code, 'MEMBERSHIP_PENDING');
  assert.equal(check({...profile, organizationId: 'other'}, 'samples.create').code, 'WRONG_ORG');
});

test('malformed role sets cannot recover grants from a valid primary role', () => {
  for (const roles of [[], ['lab', 'lab'], ['lab', 'unknown'], ['lab', 3],
    ['lab', 'admin'], ['lab', 'viewer'], ['nutritionist', 'lab'], 'lab', {}, null]) {
    const member = {...profile, roles};
    assert.equal(validRoleSet(profileRoles(member), member.role), false);
    assert.equal(check(member, 'samples.create').code, 'PERMISSION_DENIED');
  }
  const legacy = {...profile};
  delete legacy.roles;
  assert.equal(check(legacy, 'samples.create'), null);
});
