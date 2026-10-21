#!/usr/bin/env python3
"""Measuring proxy: every harness talks to the model through this.

  harness --(base URL http://127.0.0.1:PORT/run/<id>/v1)--> proxy --> upstream gateway

Requests and responses pass through unchanged, except that chat requests get
stream_options.include_usage so token counts are always reported. One JSON line
per request goes to OUT/<id>.jsonl: bytes sent, prompt/completion/cached
tokens, tool calls in the reply, model time and HTTP status.

Usage: proxy.py --upstream http://127.0.0.1:12434 --out DIR [--port 0]
Prints the bound port on stdout.
"""
import http.client
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

opt = {"--upstream": "http://127.0.0.1:12434", "--out": "arena/results/proxy", "--port": "0"}
a = sys.argv[1:]
for i in range(0, len(a), 2):
    opt[a[i]] = a[i + 1]
UP = urlsplit(opt["--upstream"])
OUT = opt["--out"]
os.makedirs(OUT, exist_ok=True)
lock = threading.Lock()


class Meter:
    """Scans SSE (chat or responses API) or a plain JSON body for usage and tool calls."""

    def __init__(self):
        self.line = b""
        self.prompt = self.completion = self.cached = 0
        self.tool_ids = set()
        self.tool_idx = set()
        self.raw = b""

    def usage(self, u):
        if not isinstance(u, dict):
            return
        self.prompt = u.get("prompt_tokens", u.get("input_tokens", self.prompt)) or self.prompt
        self.completion = u.get("completion_tokens", u.get("output_tokens", self.completion)) or self.completion
        d = u.get("prompt_tokens_details") or u.get("input_tokens_details") or {}
        self.cached = d.get("cached_tokens", self.cached) or self.cached

    def event(self, obj):
        self.usage(obj.get("usage"))
        if obj.get("type") == "response.completed":
            self.usage((obj.get("response") or {}).get("usage"))
        if obj.get("type") == "response.output_item.added" and (obj.get("item") or {}).get("type") == "function_call":
            self.tool_ids.add(obj["item"].get("call_id") or obj["item"].get("id"))
        for ch in obj.get("choices") or []:
            for tc in (ch.get("delta") or ch.get("message") or {}).get("tool_calls") or []:
                self.tool_idx.add(tc.get("index", len(self.tool_idx)))

    def feed(self, data):
        if len(self.raw) < 4 << 20:
            self.raw += data
        self.line += data
        while b"\n" in self.line:
            l, self.line = self.line.split(b"\n", 1)
            l = l.strip()
            if l.startswith(b"data:"):
                p = l[5:].strip()
                if p and p != b"[DONE]":
                    try:
                        self.event(json.loads(p))
                    except ValueError:
                        pass

    def finish(self):
        if not self.tool_idx and not self.tool_ids and self.raw[:1] == b"{":
            try:
                self.event(json.loads(self.raw))
            except ValueError:
                pass
        return len(self.tool_idx) + len(self.tool_ids)


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def do_GET(self):
        self.forward()

    def do_POST(self):
        self.forward()

    def forward(self):
        run, path = "none", self.path
        parts = self.path.split("/")
        if len(parts) > 3 and parts[1] == "run":
            run, path = parts[2], "/" + "/".join(parts[3:])
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        if path.endswith("/chat/completions") and body:
            try:
                req = json.loads(body)
                if req.get("stream"):
                    req.setdefault("stream_options", {})["include_usage"] = True
                    body = json.dumps(req).encode()
            except ValueError:
                pass
        hdrs = {k: v for k, v in self.headers.items() if k.lower() not in ("host", "content-length", "connection", "accept-encoding")}
        hdrs["Content-Length"] = str(len(body))
        t0 = time.time()
        meter = Meter()
        status = 0
        try:
            up = http.client.HTTPConnection(UP.hostname, UP.port or 80, timeout=900)
            up.request(self.command, path, body=body if self.command == "POST" else None, headers=hdrs)
            r = up.getresponse()
            status = r.status
            self.send_response(r.status)
            for k, v in r.getheaders():
                if k.lower() not in ("transfer-encoding", "content-length", "connection"):
                    self.send_header(k, v)
            self.send_header("Transfer-Encoding", "chunked")
            self.send_header("Connection", "close")
            self.end_headers()
            while True:
                chunk = r.read1(65536)
                if not chunk:
                    break
                meter.feed(chunk)
                self.wfile.write(b"%x\r\n%s\r\n" % (len(chunk), chunk))
                self.wfile.flush()
            self.wfile.write(b"0\r\n\r\n")
        except (BrokenPipeError, ConnectionResetError, OSError) as e:
            status = status or 599
        self.close_connection = True
        if path.endswith("/models"):
            return
        rec = {"t0": t0, "model_s": round(time.time() - t0, 3), "path": path, "status": status,
               "bytes_sent": len(body), "prompt_tokens": meter.prompt, "completion_tokens": meter.completion,
               "cached_tokens": meter.cached, "tool_calls": meter.finish()}
        with lock, open(os.path.join(OUT, f"{run}.jsonl"), "a") as f:
            f.write(json.dumps(rec) + "\n")


srv = ThreadingHTTPServer(("127.0.0.1", int(opt["--port"])), H)
srv.daemon_threads = True
print(srv.server_address[1], flush=True)
srv.serve_forever()
