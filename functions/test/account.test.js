'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {deleteStoragePrefix, publicVerificationTokens} = require('../lib/account');

test('account storage cleanup removes every file in bounded batches', async () => {
  const deleted = [];
  const files = Array.from({length: 205}, (_, index) => ({
    delete: async (options) => {
      assert.equal(options.ignoreNotFound, true);
      deleted.push(index);
    },
  }));
  const bucket = {getFiles: async (options) => {
    assert.equal(options.prefix, 'users/user-1/');
    assert.equal(options.autoPaginate, true);
    return [files];
  }};
  const count = await deleteStoragePrefix(bucket, 'users/user-1/');
  assert.equal(count, 205);
  assert.equal(new Set(deleted).size, 205);
});

test('account cleanup includes legacy public Digital ID token formats', () => {
  const current = 'a'.repeat(64);
  const legacy = 'legacy-random-token-32-characters';
  const snapshot = {
    docs: [
      {data: () => ({token: current})},
      {data: () => ({token: legacy})},
      {data: () => ({token: current})}, // duplicate
      {data: () => ({token: ''})},
      {data: () => ({token: 'not/a/single/document/id'})},
      {data: () => ({token: null})},
      {data: () => ({})},
    ],
  };
  assert.deepEqual(publicVerificationTokens(snapshot), [current, legacy]);
});
