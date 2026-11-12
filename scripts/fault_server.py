#!/usr/bin/env python3
"""故障注入服务：验证「非 200」与「真超时」两条失败态走的是真实 URLSession 路径。
  POST /v1/chat/completions        → 500 + JSON body
  POST /hang/v1/.../chat/completions → 永不回包（触发客户端 timeoutInterval）
"""
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from concurrent.futures import ThreadPoolExecutor

PORT = 18731


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):  # noqa: N802
        length = int(self.headers.get("Content-Length") or 0)
        self.rfile.read(length)
        if self.path.startswith("/hang"):
            time.sleep(60)
            return
        body = json.dumps({"error": "internal boom"}).encode()
        self.send_response(500)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):  # noqa: A002
        pass


if __name__ == "__main__":
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    with ThreadPoolExecutor(max_workers=8):
        srv.serve_forever()
