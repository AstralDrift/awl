'use strict';
const { send, error, readJson } = require('./http');

function parseId(s) {
  const id = Number(s);
  return Number.isInteger(id) && id > 0 ? id : undefined;
}

function validate(body, partial) {
  if (!partial || 'name' in body) {
    if (typeof body.name !== 'string' || body.name.trim() === '') return 'name must be a non-empty string';
  }
  if ('qty' in body && (!Number.isInteger(body.qty) || body.qty < 0)) return 'qty must be a non-negative integer';
  return null;
}

// [method, pattern, handler(req, res, store, params)]
const routes = [
  ['GET', /^\/items$/, (req, res, store) => send(res, 200, store.list())],
  ['GET', /^\/items\/([^/]+)$/, (req, res, store, [id]) => {
    const item = store.get(parseId(id));
    return item ? send(res, 200, item) : error(res, 404, 'item not found');
  }],
  ['POST', /^\/items$/, async (req, res, store) => {
    const body = await readJson(req);
    const bad = validate(body, false);
    if (bad) return error(res, 400, bad);
    return send(res, 201, store.create({ name: body.name, qty: body.qty }));
  }],
  ['PATCH', /^\/items\/([^/]+)$/, async (req, res, store, [id]) => {
    const body = await readJson(req);
    const bad = validate(body, true);
    if (bad) return error(res, 400, bad);
    const fields = {};
    if ('name' in body) fields.name = body.name;
    if ('qty' in body) fields.qty = body.qty;
    const item = store.update(parseId(id), fields);
    return item ? send(res, 200, item) : error(res, 404, 'item not found');
  }],
];

module.exports = { routes };
