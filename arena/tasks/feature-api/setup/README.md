# items-api

Small in-memory JSON API on Node's http module (no dependencies).

| method | path | result |
|---|---|---|
| GET | /items | 200, array of items |
| GET | /items/:id | 200 item, 404 if missing |
| POST | /items | 201 created item; body `{"name": str, "qty"?: int}` |
| PATCH | /items/:id | 200 updated item, 404 if missing |

Errors are JSON: `{"error": "<message>"}`. Run tests with `npm test`.
