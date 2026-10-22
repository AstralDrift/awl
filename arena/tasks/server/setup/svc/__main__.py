import argparse
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from svc import stats, store


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send_json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        try:
            if self.path == "/health":
                return self.send_json(200, {"ok": True})
            if self.path == "/orders":
                return self.send_json(200, store.all_orders())
            if self.path == "/stats":
                return self.send_json(200, stats.stats())
            return self.send_json(404, {"error": "not found"})
        except Exception as e:  # noqa: BLE001
            return self.send_json(500, {"error": type(e).__name__})


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--port", type=int, default=8099)
    a = p.parse_args()
    ThreadingHTTPServer(("127.0.0.1", a.port), Handler).serve_forever()


main()
