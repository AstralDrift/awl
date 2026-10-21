'use strict';
const { test, before, after } = require('node:test');
const assert = require('node:assert');
const { createServer } = require('../src/server');

let server, base;
before(async () => {
  server = createServer();
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  base = `http://127.0.0.1:${server.address().port}`;
});
after(() => server.close());

const req = (method, path, body) =>
  fetch(base + path, { method, headers: { 'content-type': 'application/json' }, body: body && JSON.stringify(body) });

test('create, get, list', async () => {
  const r = await req('POST', '/items', { name: 'apple', qty: 3 });
  assert.strictEqual(r.status, 201);
  const item = await r.json();
  assert.deepStrictEqual(item, { id: 1, name: 'apple', qty: 3 });
  assert.deepStrictEqual(await (await req('GET', '/items/1')).json(), item);
  assert.deepStrictEqual(await (await req('GET', '/items')).json(), [item]);
});

test('validation and 404', async () => {
  assert.strictEqual((await req('POST', '/items', { qty: 1 })).status, 400);
  const r = await req('GET', '/items/999');
  assert.strictEqual(r.status, 404);
  assert.deepStrictEqual(await r.json(), { error: 'item not found' });
});

test('patch', async () => {
  const r = await req('PATCH', '/items/1', { qty: 7 });
  assert.deepStrictEqual(await r.json(), { id: 1, name: 'apple', qty: 7 });
});
