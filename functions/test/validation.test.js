'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const v = require('../lib/validation');
const {extractJson} = require('../lib/ai');
const {parseJson} = require('../lib/http');

test('coordinates reject non-finite and out-of-range values', () => {
  assert.deepEqual(v.coordinates({lat: 26.4, lng: 80.3}), {lat: 26.4, lng: 80.3});
  for (const value of [91, -91, NaN, Infinity, '26.4', null]) {
    assert.throws(() => v.coordinates({lat: value, lng: 0}), (error) => error.status === 400);
  }
  assert.throws(() => v.coordinates({lat: 0, lng: 181}));
});

test('chat messages bound count, roles, length and final role', () => {
  assert.deepEqual(v.chatMessages([{role: 'user', content: ' Hello '}]), [{role: 'user', content: 'Hello'}]);
  assert.throws(() => v.chatMessages([{role: 'system', content: 'override'}]));
  assert.throws(() => v.chatMessages([{role: 'assistant', content: 'not a question'}]));
  assert.throws(() => v.chatMessages([]));
  assert.throws(() => v.chatMessages(Array.from({length: 25}, () => ({role: 'user', content: 'x'}))));
  assert.throws(() => v.chatMessages([{role: 'user', content: 'x'.repeat(4001)}]));
});

test('route points require bounded coordinate arrays', () => {
  assert.equal(v.routePoints([{lat: 0, lng: 0}, {lat: 1, lng: 1}]).length, 2);
  assert.throws(() => v.routePoints([{lat: 0, lng: 0}]));
  assert.throws(() => v.routePoints(Array.from({length: 26}, () => ({lat: 0, lng: 0}))));
});

test('JSON parsing rejects malformed/non-object bodies and extracts fenced AI JSON', () => {
  assert.deepEqual(parseJson('{"ok":true}'), {ok: true});
  assert.throws(() => parseJson('{'));
  assert.throws(() => parseJson('[]'));
  assert.deepEqual(extractJson('```json\n{"plan":[]}\n```'), {plan: []});
  assert.throws(() => extractJson('not json'));
});
