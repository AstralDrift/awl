# svc

Order service. Start it with `python3 -m svc --port 8099`.

- `GET /health` -> `{"ok": true}`
- `GET /orders` -> the orders
- `GET /stats` -> `{"count": N, "units": N, "total": N}`
