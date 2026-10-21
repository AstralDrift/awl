#!/bin/sh
python3 - <<'P'
p = "src/store.js"; s = open(p).read()
s = s.replace("""    return item;
  }
}
""", """    return item;
  }

  remove(id) {
    return this.items.delete(id);
  }
}
""", 1)
open(p, "w").write(s)
p = "src/routes.js"; s = open(p).read()
s = s.replace("""];

module.exports""", """  ['DELETE', /^\\/items\\/([^/]+)$/, (req, res, store, [id]) =>
    store.remove(parseId(id)) ? send(res, 204) : error(res, 404, 'item not found')],
];

module.exports""")
open(p, "w").write(s)
p = "README.md"; s = open(p).read()
s = s.replace("| PATCH | /items/:id | 200 updated item, 404 if missing |", "| PATCH | /items/:id | 200 updated item, 404 if missing |\n| DELETE | /items/:id | 204, 404 if missing |")
open(p, "w").write(s)
P
cat >> test/items.test.js <<'J'

test('delete', async () => {
  assert.strictEqual((await req('DELETE', '/items/1')).status, 204);
  assert.strictEqual((await req('DELETE', '/items/1')).status, 404);
});
J
