#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import os
import socket
import ssl
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


FIXTURE_DIR = Path(__file__).resolve().parent
CERTIFICATE = FIXTURE_DIR / "webview_navigation_cert.pem"
PRIVATE_KEY = FIXTURE_DIR / "webview_navigation_key.pem"


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
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, _format, *_args):
        pass


def certificate_fingerprint() -> str:
    pem = CERTIFICATE.read_text(encoding="ascii")
    der = ssl.PEM_cert_to_DER_cert(pem)
    return hashlib.sha256(der).hexdigest()


def publish_metadata(path: Path, http_port: int, https_port: int) -> None:
    if not (1 <= http_port <= 65535 and 1 <= https_port <= 65535 and http_port != https_port):
        raise RuntimeError("fixture servers did not bind distinct valid ports")
    fingerprint = certificate_fingerprint()
    if len(fingerprint) != 64 or any(byte not in "0123456789abcdef" for byte in fingerprint):
        raise RuntimeError("fixture certificate did not produce a SHA256 fingerprint")
    metadata = {
        "version": 1,
        "http_origin": f"http://127.0.0.1:{http_port}",
        "https_origin": f"https://127.0.0.1:{https_port}",
        "certificate_sha256": fingerprint,
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(metadata, stream, sort_keys=True, separators=(",", ":"))
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary_name, path)
    finally:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: webview_navigation_server.py METADATA_PATH")
    metadata_path = Path(sys.argv[1]).resolve()
    http_server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    https_server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(CERTIFICATE, PRIVATE_KEY)
    https_server.socket = context.wrap_socket(https_server.socket, server_side=True)
    publish_metadata(metadata_path, http_server.server_port, https_server.server_port)

    https_thread = threading.Thread(target=https_server.serve_forever, name="navigation-https", daemon=True)
    https_thread.start()
    try:
        http_server.serve_forever()
    finally:
        http_server.server_close()
        https_server.shutdown()
        https_server.server_close()
        https_thread.join(timeout=5)


if __name__ == "__main__":
    main()
