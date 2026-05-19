#!/usr/bin/env python3
"""Minimal captive portal HTTP server. No external dependencies."""
import http.server
import socketserver
import urllib.parse

PORTAL_HTML = """\
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Network Login</title>
  <style>
    body { font-family: sans-serif; max-width: 400px; margin: 80px auto; padding: 20px; }
    h1   { color: #333; }
    button { background: #0078d4; color: #fff; border: none; padding: 12px 24px;
             font-size: 16px; border-radius: 4px; cursor: pointer; }
    button:hover { background: #006cbf; }
    p { color: #666; }
  </style>
</head>
<body>
  <h1>Welcome</h1>
  <p>You are connected to a simulated captive portal network.</p>
  <form method="GET" action="/connected">
    <button type="submit">Connect to Internet</button>
  </form>
</body>
</html>
"""

SUCCESS_HTML = """\
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><title>Connected</title></head>
<body style="font-family:sans-serif;max-width:400px;margin:80px auto;padding:20px">
  <h1 style="color:#0a0">Connected!</h1>
  <p>You may now use the internet. (This is a simulated captive portal.)</p>
</body>
</html>
"""

# Endpoints used by OS captive-portal probes
PROBE_PATHS = {
    "/generate_204",          # Android
    "/hotspot-detect.html",   # iOS / macOS
    "/connecttest.txt",       # Windows
    "/ncsi.txt",              # Windows NCSI
    "/success.txt",           # Firefox
    "/canonical.html",        # Ubuntu
}


class PortalHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print(f"[portal] {self.address_string()} {fmt % args}", flush=True)

    def _send(self, code, body, ctype="text/html; charset=utf-8"):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", len(data))
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        if path in PROBE_PATHS:
            self._send(200, PORTAL_HTML)
        elif path == "/connected":
            self._send(200, SUCCESS_HTML)
        else:
            self.send_response(302)
            self.send_header("Location", "http://192.168.99.1/")
            self.end_headers()

    do_POST = do_GET
    do_HEAD = do_GET


if __name__ == "__main__":
    PORT = 80
    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.TCPServer(("", PORT), PortalHandler) as httpd:
        print(f"[portal] Captive portal listening on :{PORT}", flush=True)
        httpd.serve_forever()
