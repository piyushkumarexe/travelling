'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {requireUid} = require('../lib/http');

function request(authorization) {
  return {get: (name) => name === 'Authorization' ? authorization : undefined};
}

test('missing and malformed bearer tokens are rejected', async () => {
  const requireUser = requireUid({auth: () => { throw new Error('must not verify'); }});
  await assert.rejects(requireUser(request('')), (error) => error.status === 401);
  await assert.rejects(requireUser(request('Basic secret')), (error) => error.status === 401);
  await assert.rejects(requireUser(request('Bearer ')), (error) => error.status === 401);
});

test('ID tokens are verified with revocation checking', async () => {
  let received;
  let checkRevoked;
  const admin = {auth: () => ({verifyIdToken: async (token, revoked) => {
    received = token;
    checkRevoked = revoked;
    return {uid: 'user-123'};
  }})};
  const uid = await requireUid(admin)(request('Bearer valid-token'));
  assert.equal(uid, 'user-123');
  assert.equal(received, 'valid-token');
  assert.equal(checkRevoked, true);
});

test('invalid tokens never become anonymous requests', async () => {
  const admin = {auth: () => ({verifyIdToken: async () => { throw new Error('invalid'); }})};
  await assert.rejects(requireUid(admin)(request('Bearer invalid')), (error) => {
    assert.equal(error.status, 401);
    assert.equal(error.code, 'unauthenticated');
    assert.doesNotMatch(error.message, /invalid/);
    return true;
  });
});
