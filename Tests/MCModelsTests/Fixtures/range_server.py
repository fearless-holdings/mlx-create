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

Civitai mimic (CivitaiDownloader tests). GET /civitai/download/<id> answers 401 unless the key in civitai.key is
sent as Authorization: Bearer; otherwise it 302s to /civitai-cdn/<id>?e=<epoch>&sig=... on localhost ("cross_host"),
127.0.0.1 over plain http ("same_host_http"), or serves the bytes itself ("direct"). The CDN answers 403 when e is
stale, serves Range (no ETag), and ignores Range when civitai.ignore_range is set.
  civitai: {"file": abs, "key": str|null, "redirect": ..., "epoch": int, "stream_403": N (the next N requests
            without Range get 403), "stream_mode": "ok"|"overrun"|"short", "ignore_range": bool}
  expire_civitai: true             bumps the epoch, so every signed URL goes stale
  GET /__stats also returns civitai_requests: [{path, host, authorization, range, status, bytes}].
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
SHORT_BY = 1000
lock = threading.Lock()
state = {
    "epoch": 1,
    "redirect": True,
    "mode": "range",
    "stall": {"after_bytes": 0, "times": 0},
    "throttle_ms": 0,
    "files": {},
    "civitai": {"file": None, "key": None, "redirect": "cross_host", "epoch": 1, "stream_403": 0,
                "stream_mode": "ok", "ignore_range": False},
}
stats = {"bytes_served": {}, "requests": [], "civitai_requests": []}


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
                stats["civitai_requests"] = []
            if "civitai" in body:
                state["civitai"].update(body["civitai"])
            if body.get("expire_civitai"):
                state["civitai"]["epoch"] += 1
        self.send_json(200, {"ok": True})

    def do_GET(self):
        if self.path == "/__stats":
            with lock:
                return self.send_json(200, stats)

        if self.path.startswith("/civitai/download/"):
            return self.serve_civitai_download()

        if self.path.startswith("/civitai-cdn/"):
            return self.serve_civitai_cdn()

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


    def civitai_snapshot(self):
        with lock:
            snap = dict(state["civitai"])
            snap["throttle_ms"] = state["throttle_ms"]
        return snap

    def civitai_log(self, status, rng, sent):
        with lock:
            stats["civitai_requests"].append({
                "path": urllib.parse.urlsplit(self.path).path,
                "host": self.headers.get("Host"),
                "authorization": self.headers.get("Authorization"),
                "range": rng,
                "status": status,
                "bytes": sent,
            })

    def serve_civitai_download(self):
        civ = self.civitai_snapshot()
        rng = self.headers.get("Range")
        if civ["key"] is not None and self.headers.get("Authorization") != f"Bearer {civ['key']}":
            self.civitai_log(401, rng, 0)
            return self.send_json(401, {"error": "api key required"})
        file_id = urllib.parse.urlsplit(self.path).path.rsplit("/", 1)[-1]
        if civ["redirect"] == "direct":
            return self.serve_civitai_file(civ, rng)
        host = "localhost" if civ["redirect"] == "cross_host" else "127.0.0.1"
        port = self.server.server_address[1]
        location = f"http://{host}:{port}/civitai-cdn/{file_id}?e={civ['epoch']}&sig=t{time.time_ns()}"
        self.send_response(302)
        self.send_header("Location", location)
        self.send_header("Content-Length", "0")
        self.end_headers()
        self.civitai_log(302, rng, 0)

    def serve_civitai_cdn(self):
        civ = self.civitai_snapshot()
        parts = urllib.parse.urlsplit(self.path)
        rng = self.headers.get("Range")
        if urllib.parse.parse_qs(parts.query).get("e", [""])[0] != str(civ["epoch"]):
            self.civitai_log(403, rng, 0)
            return self.send_json(403, {"error": "expired signature"})
        return self.serve_civitai_file(civ, rng)

    def serve_civitai_file(self, civ, rng):
        path = civ["file"]
        size = os.path.getsize(path)
        start, end, status = 0, size - 1, 200
        if rng and not civ["ignore_range"] and rng.startswith("bytes="):
            a, _, b = rng[len("bytes="):].partition("-")
            start = int(a)
            end = min(int(b) if b else size - 1, size - 1)
            status = 206
        stream = rng is None
        if stream:
            with lock:
                refuse = state["civitai"]["stream_403"] > 0
                if refuse:
                    state["civitai"]["stream_403"] -= 1
            if refuse:
                self.civitai_log(403, rng, 0)
                return self.send_json(403, {"error": "expired signature"})
        mode = civ["stream_mode"] if stream else "ok"
        length = end - start + 1
        extra = b""
        if mode == "overrun":
            begin, count, extra, status = 0, size, OVERRUN_FILL * OVERRUN_BYTES, 200
        elif mode == "short":
            begin, count, status = 0, max(size - SHORT_BY, 0), 200
        else:
            begin, count = start, length
        self.send_response(status)
        if mode in ("overrun", "short"):
            self.send_header("Connection", "close")
            self.close_connection = True
        else:
            self.send_header("Content-Length", str(length))
            if status == 206:
                self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.send_header("Accept-Ranges", "bytes")
        self.end_headers()
        sent = 0
        try:
            with open(path, "rb") as f:
                f.seek(begin)
                remaining = count
                while remaining > 0:
                    data = f.read(min(CHUNK, remaining))
                    if not data:
                        break
                    self.wfile.write(data)
                    self.wfile.flush()
                    sent += len(data)
                    remaining -= len(data)
                    if civ["throttle_ms"]:
                        time.sleep(civ["throttle_ms"] / 1000.0)
            if extra:
                self.wfile.write(extra)
                self.wfile.flush()
                sent += len(extra)
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            self.civitai_log(status, rng, sent)


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
