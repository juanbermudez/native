#!/usr/bin/env python3
import sys
import time
import socket
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    same_url_lock = threading.Lock()
    same_url_requests = 0

    def do_GET(self):
        if self.path == "/disconnect":
            self.connection.shutdown(socket.SHUT_RDWR)
            self.connection.close()
            return
        if self.path == "/start":
            self.send_response(302)
            self.send_header("Location", "/final")
            self.end_headers()
            return
        if self.path == "/same":
            with self.same_url_lock:
                self.__class__.same_url_requests += 1
                same_url_request = self.__class__.same_url_requests
            if same_url_request == 1:
                time.sleep(3)
        if self.path.startswith("/slow"):
            time.sleep(8)
        body = b"<!doctype html><title>lifecycle</title><p>ok</p>"
        if self.path == "/final":
            body = b'<!doctype html><title>lifecycle</title><iframe src="/frame"></iframe><p>ok</p>'
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except BrokenPipeError:
            pass

    def log_message(self, _format, *_args):
        pass


server = ThreadingHTTPServer(("127.0.0.1", 48765), Handler)
with open(sys.argv[1], "w", encoding="utf-8") as port_file:
    port_file.write(str(server.server_port))
server.serve_forever()
