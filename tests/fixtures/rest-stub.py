#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
#
# Test fixture: a minimal stand-in for the Palworld REST API. Requires HTTP Basic
# auth (admin:$PALWORLD_STUB_PW, default "secret123") and answers /v1/api/metrics
# and /v1/api/info, so the tooling can be exercised without a real server.
import base64, json, os
from http.server import BaseHTTPRequestHandler, HTTPServer

PW = os.environ.get("PALWORLD_STUB_PW", "secret123")

class H(BaseHTTPRequestHandler):
    def _auth_ok(self):
        h = self.headers.get("Authorization", "")
        if not h.startswith("Basic "):
            return False
        try:
            u, p = base64.b64decode(h[6:]).decode().split(":", 1)
        except Exception:
            return False
        return u == "admin" and p == PW

    def do_GET(self):
        if not self._auth_ok():
            self.send_response(401); self.end_headers(); return
        if self.path.startswith("/v1/api/metrics"):
            body = json.dumps({
                "serverfps": 60, "serverfpsaverage": 59, "serverframetime": 16.6,
                "currentplayernum": 3, "maxplayernum": 32, "uptime": 4242,
                "basecampnum": 2, "days": 5,
            }).encode()
        elif self.path.startswith("/v1/api/info"):
            body = json.dumps({"version": "v0.7.3", "servername": "Stub Server"}).encode()
        else:
            self.send_response(404); self.end_headers(); return
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)

    def log_message(self, *a):
        pass

print("stub Palworld REST API on :8212", flush=True)
HTTPServer(("0.0.0.0", 8212), H).serve_forever()
