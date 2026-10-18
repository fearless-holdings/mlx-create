"""
Local HTTP fixture for MCModels downloader tests. Mimics a Hugging Face resolve endpoint: the resolve URL answers
with a 302 to a time-signed CDN URL (carrying X-Linked-Etag and a Set-Cookie), and the CDN serves the bytes with its
own ETag. Run with /usr/bin/python3. Writes the bound port to --ready-file, then serves until killed.

Control (POST /__control, JSON body, keys optional):
  expire_cdn: true                 invalidates every CDN URL issued so far (time-signed URLs go stale)
  redirect: bool                   answer resolve URLs with a 302 (default true) or serve them directly
  mode: "range" | "ignore-range" | "overrun-206" | "overrun-200"
                                   ignore-range: every request gets 200 and the whole file; overrun-206: each 206
                                   body carries 64 KiB past its Content-Range; overrun-200: 200 with the whole file
                                   plus 64 KiB and no Content-Length
  stall: {"after_bytes": N, "times": K}  the next K data responses send N bytes, then hang
  throttle_ms: N                   sleep N ms after each 64 KiB sent
  files: {key: {"path": abs, "etag": str, "linked_etag": str}}   key = resolve path
  reset_stats: true                clears counters

GET /__stats returns {"bytes_served": {key: n}, "requests": [{"key", "range", "status", "ua", "cookie"}]}.
"""

import http.server
import json
import os
import socketserver
import sys
import threading
import time
import urllib.parse

CHUNK = 64 * 1024
OVERRUN_BYTES = 64 * 1024
OVERRUN_FILL = b"\xee"
lock = threading.Lock()
state = {
    "epoch": 1,
    "redirect": True,
    "mode": "range",
    "stall": {"after_bytes": 0, "times": 0},
    "throttle_ms": 0,
    "files": {},
}
stats = {"bytes_served": {}, "requests": []}


def record(key, status, headers, rng):
    with lock:
        stats["requests"].append({
            "key": key,
            "range": rng,
            "status": status,
            "ua": headers.get("User-Agent"),
            "cookie": headers.get("Cookie"),
        })


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def send_json(self, status, obj):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if self.path != "/__control":
            return self.send_json(404, {"error": "no route"})
        length = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(length) or b"{}")
        with lock:
            if body.get("expire_cdn"):
                state["epoch"] += 1
            if "redirect" in body:
                state["redirect"] = bool(body["redirect"])
            if "mode" in body:
                state["mode"] = body["mode"]
            if "stall" in body:
                state["stall"] = body["stall"]
            if "throttle_ms" in body:
                state["throttle_ms"] = int(body["throttle_ms"])
            if "files" in body:
                state["files"] = body["files"]
            if body.get("reset_stats"):
                stats["bytes_served"] = {}
                stats["requests"] = []
        self.send_json(200, {"ok": True})

    def do_GET(self):
        if self.path == "/__stats":
            with lock:
                return self.send_json(200, stats)

        if self.path.startswith("/cdn/"):
            return self.serve_cdn()

        key = urllib.parse.urlsplit(self.path).path
        with lock:
            entry = state["files"].get(key)
            redirect = state["redirect"]
        if entry is None:
            return self.send_json(404, {"error": "unknown key"})

        if redirect:
            with lock:
                epoch = state["epoch"]
            self.send_response(302)
            self.send_header("Location", f"/cdn/e{epoch}{key}?sig=t{time.time_ns()}")
            self.send_header("X-Linked-Etag", entry.get("linked_etag", ""))
            self.send_header("Set-Cookie", "session=fixture; Path=/")
            self.send_header("Content-Length", "0")
            self.end_headers()
            record(key, 302, self.headers, self.headers.get("Range"))
            return
        return self.serve_file(key, entry)

    def serve_cdn(self):
        path = urllib.parse.urlsplit(self.path).path
        prefix, _, rest = path[len("/cdn/"):].partition("/")
        key = "/" + rest
        with lock:
            current = f"e{state['epoch']}"
            entry = state["files"].get(key)
        if prefix != current:
            record(key, 403, self.headers, self.headers.get("Range"))
            return self.send_json(403, {"error": "expired signature"})
        if entry is None:
            return self.send_json(404, {"error": "unknown key"})
        return self.serve_file(key, entry)

    def serve_overrun(self, key, entry, size, start, end, status, rng):
        length = end - start + 1
        self.send_response(status)
        self.send_header("ETag", entry["etag"])
        self.send_header("Accept-Ranges", "bytes")
        if status == 206:
            self.send_header("Content-Length", str(length + OVERRUN_BYTES))
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        else:
            self.send_header("Connection", "close")
            self.close_connection = True
        self.end_headers()
        record(key, status, self.headers, rng)
        with open(entry["path"], "rb") as f:
            f.seek(start)
            body = f.read(length)
        try:
            self.wfile.write(body + OVERRUN_FILL * OVERRUN_BYTES)
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            return

    def serve_file(self, key, entry):
        size = os.path.getsize(entry["path"])
        rng = self.headers.get("Range")
        with lock:
            mode = state["mode"]
            ignore = mode in ("ignore-range", "overrun-200")
            stall = dict(state["stall"])
            throttle = state["throttle_ms"] / 1000.0
            stall_now = stall["times"] > 0
            if stall_now:
                state["stall"] = {"after_bytes": stall["after_bytes"], "times": stall["times"] - 1}

        start, end, status = 0, size - 1, 200
        if rng and not ignore and rng.startswith("bytes="):
            a, _, b = rng[len("bytes="):].partition("-")
            start = int(a)
            end = min(int(b) if b else size - 1, size - 1)
            status = 206
        if mode == "overrun-200" or (mode == "overrun-206" and status == 206):
            return self.serve_overrun(key, entry, size, start, end, status, rng)

        length = end - start + 1
        self.send_response(status)
        self.send_header("ETag", entry["etag"])
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(length))
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        record(key, status, self.headers, rng)

        limit = stall["after_bytes"] if stall_now else None
        sent = 0
        with open(entry["path"], "rb") as f:
            f.seek(start)
            remaining = length
            while remaining > 0:
                if limit is not None and sent >= limit:
                    time.sleep(600)
                    return
                want = min(CHUNK, remaining)
                if limit is not None:
                    want = min(want, limit - sent)
                data = f.read(want)
                if not data:
                    break
                try:
                    self.wfile.write(data)
                    self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    return
                sent += len(data)
                remaining -= len(data)
                with lock:
                    served = stats["bytes_served"]
                    served[key] = served.get(key, 0) + len(data)
                if throttle:
                    time.sleep(throttle)


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    ready = sys.argv[sys.argv.index("--ready-file") + 1]
    server = Server(("127.0.0.1", 0), Handler)
    with open(ready + ".tmp", "w") as f:
        f.write(str(server.server_address[1]))
    os.replace(ready + ".tmp", ready)
    server.serve_forever()


if __name__ == "__main__":
    main()
