"""A fake TypeSafe System One endpoint for the declutter smoke checks, on 127.0.0.1 only.

POST /v1/systemone answers in the real shape (docs.typesafe.ai/api.md, Unclutter lib/jev.ts):
{"model", "answers": {<id>: {"type": "choice", "choice", "probabilities", "confidence"}},
"usage": {"input_tokens", "output_tokens"}}. It labels each element from keywords in its signals
and text, validates the request shape (422 when wrong), and appends one JSON line per request to
the record file: the request body, whether the Authorization header equals "Bearer <expected>"
(never the header itself), and whether a Cookie header came along.

POST /__mode sets how later requests are answered: ok, unknown (adds an id nobody asked about and
a duplicate), slow (answers normally after 25 s), 401, 429, timeout (answers after 30 s), malformed,
oversized, redirect.
GET /__count answers the number of requests so far.
Usage: python3 scripts/fakejev.py <port> <record file> <expected key>"""

import http.server
import json
import sys
import threading
import time

LABELS = ["keep", "ad", "promotion", "newsletter", "social", "cookie", "uncertain"]
RULES = [
    ("cookie", ("cookie", "consent")),
    ("newsletter", ("newsletter", "subscribe")),
    ("social", ("share", "social")),
    ("ad", ("advert", "sponsor", "ad-slot", " ad ", "ad-")),
    ("promotion", ("promo", "sale", "deal", "offer")),
]
lock = threading.Lock()
state = {"mode": "ok", "count": 0}


def label(element):
    words = " %s %s " % (element.get("signals", ""), element.get("text", ""))
    words = words.lower()
    for name, keys in RULES:
        if any(k in words for k in keys):
            return name
    return "keep"


def answer(choice):
    probs = {name: 0.005 for name in LABELS}
    probs[choice] = 0.97
    return {"type": "choice", "choice": choice, "probabilities": probs, "confidence": 0.965}


def valid(body):
    if body.get("model") != "jev-latest" or not isinstance(body.get("questions"), dict):
        return False
    elements = body.get("state", {}).get("elements")
    if not isinstance(elements, list):
        return False
    ids = [e.get("id") for e in elements]
    if sorted(ids) != sorted(body["questions"].keys()):
        return False
    for q in body["questions"].values():
        if q.get("type") != "choice" or sorted(q.get("criteria", {}).keys()) != sorted(LABELS):
            return False
    return True


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, status, data, headers=()):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        for k, v in headers:
            self.send_header(k, v)
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        if self.path == "/__count":
            with lock:
                self.reply(200, json.dumps({"count": state["count"]}).encode())
        else:
            self.reply(404, b"{}")

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        if self.path == "/__mode":
            with lock:
                state["mode"] = raw.decode().strip()
            return self.reply(200, b"{}")
        if self.path != "/v1/systemone":
            return self.reply(404, b"{}")
        try:
            body = json.loads(raw)
        except ValueError:
            body = None
        with lock:
            state["count"] += 1
            mode = state["mode"]
            with open(RECORD, "a") as f:
                f.write(json.dumps({
                    "auth_ok": self.headers.get("Authorization") == "Bearer " + EXPECTED,
                    "cookie_header": self.headers.get("Cookie") is not None,
                    "content_type": self.headers.get("Content-Type"),
                    "mode": mode,
                    "body": body,
                }) + "\n")
        if mode == "401":
            return self.reply(401, b'{"error": "invalid api key"}')
        if mode == "429":
            return self.reply(429, b'{"error": "rate limited"}')
        if mode == "timeout":
            time.sleep(30)
        if mode == "slow":
            time.sleep(25)
        if mode == "malformed":
            return self.reply(200, b'{"model": "jev-1.13.0", "answers": {"c1": {"type": "choi')
        if mode == "oversized":
            return self.reply(200, b'{"model": "jev-1.13.0", "pad": "' + b"x" * 2_000_000 + b'", "answers": {}}')
        if mode == "redirect":
            return self.reply(307, b"{}", [("Location", "https://example.invalid/v1/systemone")])
        if not body or not valid(body):
            return self.reply(422, b'{"error": "invalid request"}')
        answers = {e["id"]: answer(label(e)) for e in body["state"]["elements"]}
        text = json.dumps({"model": "jev-1.13.0", "answers": answers, "usage": {"input_tokens": len(raw) // 4, "output_tokens": 20 * len(answers)}})
        if mode == "unknown" and answers:
            first = next(iter(answers))
            extra = '"zz-not-asked": %s, "%s": %s, ' % (json.dumps(answer("ad")), first, json.dumps(answer("keep")))
            text = text.replace('"answers": {', '"answers": {' + extra, 1)
        self.reply(200, text.encode())


PORT, RECORD, EXPECTED = int(sys.argv[1]), sys.argv[2], sys.argv[3]
http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
