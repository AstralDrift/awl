'use strict';
const { test, before, after } = require('node:test');
const assert = require('node:assert');
const path = require('node:path');
const { createServer } = require(path.join(process.cwd(), 'src/server'));

let server, base;
before(async () => {
  server = createServer();
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  base = `http://127.0.0.1:${server.address().port}`;
});
after(() => server.close());

const req = (method, p, body) =>
  fetch(base + p, { method, headers: { 'content-type': 'application/json' }, body: body && JSON.stringify(body) });

test('hidden: delete lifecycle', async () => {
  for (const name of ['a', 'b', 'c']) assert.strictEqual((await req('POST', '/items', { name })).status, 201);
  const d = await req('DELETE', '/items/2');
  assert.strictEqual(d.status, 204);
  assert.strictEqual(await d.text(), '');
  assert.strictEqual((await req('GET', '/items/2')).status, 404);
  assert.deepStrictEqual((await (await req('GET', '/items')).json()).map((i) => i.id), [1, 3]);
  const again = await req('DELETE', '/items/2');
  assert.strictEqual(again.status, 404);
  assert.deepStrictEqual(await again.json(), { error: 'item not found' });
  const bogus = await req('DELETE', '/items/abc');
  assert.strictEqual(bogus.status, 404);
  assert.strictEqual((await req('DELETE', '/items')).status, 405);
  // ids are never reused
  assert.strictEqual((await (await req('POST', '/items', { name: 'd' })).json()).id, 4);
  assert.strictEqual((await req('PATCH', '/items/2', { qty: 1 })).status, 404);
});
