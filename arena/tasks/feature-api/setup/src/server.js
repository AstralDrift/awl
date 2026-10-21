'use strict';
const http = require('node:http');
const { routes } = require('./routes');
const { error } = require('./http');
const { Store } = require('./store');

function createServer(store = new Store()) {
  return http.createServer(async (req, res) => {
    const path = req.url.split('?')[0];
    let pathMatched = false;
    for (const [method, pattern, handler] of routes) {
      const m = pattern.exec(path);
      if (!m) continue;
      pathMatched = true;
      if (method !== req.method) continue;
      try {
        return await handler(req, res, store, m.slice(1));
      } catch (e) {
        return error(res, e instanceof SyntaxError ? 400 : 500, e instanceof SyntaxError ? 'invalid JSON' : 'internal error');
      }
    }
    return error(res, pathMatched ? 405 : 404, pathMatched ? 'method not allowed' : 'not found');
  });
}

if (require.main === module) {
  const port = Number(process.env.PORT || 3000);
  createServer().listen(port, () => console.log(`listening on :${port}`));
}

module.exports = { createServer };
