const { test } = require('node:test');
const assert = require('node:assert');
const { healthPayload } = require('../server.js');

test('health payload reports ok status', () => {
  const p = healthPayload();
  assert.equal(p.status, 'ok');
  assert.ok(p.uptime >= 0);
});
