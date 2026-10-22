#!/usr/bin/env python3
"""Measuring proxy: every harness talks to the model through this.

  harness --(base URL http://127.0.0.1:PORT/run/<id>/v1)--> proxy --> upstream gateway

Requests and responses pass through unchanged, except that chat requests get
stream_options.include_usage so token counts are always reported. One JSON line
per request goes to OUT/<id>.jsonl: bytes sent, prompt/completion/cached
tokens, tool calls in the reply, model time and HTTP status.

Usage: proxy.py --upstream http://127.0.0.1:12434 --out DIR [--port 0]
       proxy.py --upstream https://openrouter.ai/api --key-file F --model M --ctx N [--provider P]
Prints the bound port on stdout.

Hosted upstreams (--key-file or OPENROUTER_API_KEY): the proxy speaks HTTPS, swaps in
the real key, answers /v1/models itself (just --model, max_model_len = --ctx), drops
reasoning_effort/reasoning/include_reasoning so every harness gets the model's default
(--keep-reasoning-params to keep them), pins --provider, and retries 429/502/503
before any byte reaches the harness, so rate limits never count against one harness.
"""
import http.client
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

opt = {"--upstream": "http://127.0.0.1:12434", "--out": "arena/results/proxy", "--port": "0",
       "--key-file": "", "--model": "", "--ctx": "0", "--provider": ""}
FLAGS = {"--keep-reasoning-params"}
a = sys.argv[1:]
i = 0
while i < len(a):
    if a[i] in FLAGS:
        opt[a[i]] = "1"
        i += 1
    else:
        opt[a[i]] = a[i + 1]
        i += 2
UP = urlsplit(opt["--upstream"])
PREFIX = UP.path.rstrip("/")  # e.g. /api for https://openrouter.ai/api
KEY = os.environ.get("OPENROUTER_API_KEY", "")
if opt["--key-file"]:
    KEY = open(os.path.expanduser(opt["--key-file"])).read().strip()
HOSTED = bool(KEY)
RETRY = {429, 502, 503}
OUT = opt["--out"]
os.makedirs(OUT, exist_ok=True)
lock = threading.Lock()


class Meter:
    """Scans SSE (chat or responses API) or a plain JSON body for usage and tool calls."""

    def __init__(self):
        self.line = b""
        self.prompt = self.completion = self.cached = 0
        self.cost = 0.0
        self.provider = ""
        self.tool_ids = set()
        self.tool_idx = set()
        self.raw = b""
        self.think = []  # reasoning text
        self.content_chars = 0

    def usage(self, u):
        if not isinstance(u, dict):
            return
        self.prompt = u.get("prompt_tokens", u.get("input_tokens", self.prompt)) or self.prompt
        self.completion = u.get("completion_tokens", u.get("output_tokens", self.completion)) or self.completion
        d = u.get("prompt_tokens_details") or u.get("input_tokens_details") or {}
        self.cached = d.get("cached_tokens", self.cached) or self.cached
        if isinstance(u.get("cost"), (int, float)):
            self.cost = u["cost"]

    def event(self, obj):
        self.usage(obj.get("usage"))
        if isinstance(obj.get("provider"), str):
            self.provider = obj["provider"]
        if obj.get("type") == "response.completed":
            self.usage((obj.get("response") or {}).get("usage"))
        if obj.get("type") == "response.output_item.added" and (obj.get("item") or {}).get("type") == "function_call":
            self.tool_ids.add(obj["item"].get("call_id") or obj["item"].get("id"))
        for ch in obj.get("choices") or []:
            d = ch.get("delta") or ch.get("message") or {}
            r = d.get("reasoning_content") or d.get("reasoning")
            if isinstance(r, str):
                self.think.append(r)
            if isinstance(d.get("content"), str):
                self.content_chars += len(d["content"])
            for tc in d.get("tool_calls") or []:
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

    def models(self, model=None, ctx=None):
        body = json.dumps({"object": "list", "data": [{"id": model or opt["--model"], "object": "model",
                                                       "max_model_len": int(ctx or opt["--ctx"])}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def rewrite(self, req):
        if req.get("stream"):
            req.setdefault("stream_options", {})["include_usage"] = True
        if HOSTED:
            if opt["--model"]:
                req["model"] = opt["--model"]
            if not opt.get("--keep-reasoning-params"):
                for k in ("reasoning_effort", "reasoning", "include_reasoning"):
                    req.pop(k, None)
            if opt["--provider"]:
                # comma list = ordered set of allowed providers, nothing else
                req["provider"] = {"order": opt["--provider"].split(","), "allow_fallbacks": False}
        return req

    def forward(self):
        run, path = "none", self.path
        parts = self.path.split("/")
        if len(parts) > 3 and parts[1] == "run":
            run, path = parts[2], "/" + "/".join(parts[3:])
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        if path.rstrip("/").endswith("/models"):
            cf = os.path.join(OUT, f"{run}.ctx")  # task-specific window written by run.py
            if os.path.exists(cf):
                model, ctx = open(cf).read().split()[:2]
                return self.models(model, ctx)
            if HOSTED:
                return self.models()
        if path.endswith("/chat/completions") and body:
            try:
                body = json.dumps(self.rewrite(json.loads(body))).encode()
            except ValueError:
                pass
        hdrs = {k: v for k, v in self.headers.items() if k.lower() not in ("host", "content-length", "connection", "accept-encoding")}
        hdrs["Content-Length"] = str(len(body))
        if HOSTED:
            hdrs = {k: v for k, v in hdrs.items() if k.lower() not in ("authorization", "x-api-key", "api-key")}
            hdrs["Authorization"] = "Bearer " + KEY
            hdrs["HTTP-Referer"] = "https://github.com/AstralDrift/awl"
            hdrs["X-Title"] = "awl arena"
        t0 = time.time()
        meter = Meter()
        status = 0
        retries = 0
        try:
            while True:
                if UP.scheme == "https":
                    up = http.client.HTTPSConnection(UP.hostname, UP.port or 443, timeout=900)
                else:
                    up = http.client.HTTPConnection(UP.hostname, UP.port or 80, timeout=900)
                up.request(self.command, PREFIX + path, body=body if self.command == "POST" else None, headers=hdrs)
                r = up.getresponse()
                status = r.status
                if status in RETRY and HOSTED and retries < 6:
                    wait = min(60.0, float(r.getheader("Retry-After") or 0) or 2.0 * 2 ** retries)
                    r.read()
                    up.close()
                    retries += 1
                    time.sleep(wait)
                    continue
                break
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
               "cached_tokens": meter.cached, "tool_calls": meter.finish(), "cost": meter.cost, "retries": retries, "provider": meter.provider,
               "reasoning_chars": sum(map(len, meter.think)), "content_chars": meter.content_chars}
        with lock:
            with open(os.path.join(OUT, f"{run}.jsonl"), "a") as f:
                f.write(json.dumps(rec) + "\n")
            # debugging aids: the newest request (whole history) and every turn's reasoning
            with open(os.path.join(OUT, f"{run}.last.json"), "wb") as f:
                f.write(body)
            with open(os.path.join(OUT, f"{run}.think.txt"), "a") as f:
                f.write(f"=== turn ({meter.completion} tok)\n" + "".join(meter.think) + "\n")


srv = ThreadingHTTPServer(("127.0.0.1", int(opt["--port"])), H)
srv.daemon_threads = True
print(srv.server_address[1], flush=True)
srv.serve_forever()
