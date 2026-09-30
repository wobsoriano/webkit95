"""Serves scripts/testpage like `python3 -m http.server`, plus two download routes:
/download/attachment  16 KiB of bytes(range(256)) * 64 with Content-Disposition attachment
/download/slow        4 MiB streamed at 256 KiB a second, to see a download in progress
Usage: python3 scripts/testserver.py <port>"""

import functools
import http.server
import os
import sys
import time

ATTACHMENT = bytes(range(256)) * 64
SLOW_TOTAL = 4 * 1024 * 1024
SLOW_CHUNK = 64 * 1024


class Handler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/download/attachment"):
            self.send_file("webkit95-attachment.bin", [ATTACHMENT])
        elif self.path.startswith("/download/slow"):
            self.send_file("webkit95-slow.bin", (bytes(SLOW_CHUNK) for _ in range(SLOW_TOTAL // SLOW_CHUNK)), pause=0.25)
        else:
            super().do_GET()

    def send_file(self, name, chunks, pause=0.0):
        body = list(chunks) if pause == 0 else None
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Disposition", 'attachment; filename="%s"' % name)
        self.send_header("Content-Length", str(len(body[0]) if body else SLOW_TOTAL))
        self.end_headers()
        try:
            for chunk in body or chunks:
                self.wfile.write(chunk)
                self.wfile.flush()
                if pause:
                    time.sleep(pause)
        except (BrokenPipeError, ConnectionResetError):
            pass


root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "testpage")
server = http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), functools.partial(Handler, directory=root))
server.serve_forever()
