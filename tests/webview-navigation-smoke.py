#!/usr/bin/env python3
"""Cross-platform executable smoke for the WebView navigation contract."""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import ssl
import subprocess
import sys
import tempfile
import time
import uuid
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import BinaryIO, Callable, Iterator

ROOT = Path(__file__).resolve().parents[1]
APP_DIR = ROOT / "examples" / "webview"
CACHE = APP_DIR / ".zig-cache"
AUTOMATION = CACHE / "native-sdk-automation"
LOG_PATH = CACHE / "native-sdk-webview-navigation-smoke.log"
FIXTURE_LOG_PATH = CACHE / "native-sdk-webview-navigation-fixture.log"
METADATA_PATH = CACHE / "native-sdk-webview-navigation-metadata.json"
FIXTURE = ROOT / "tests" / "fixtures" / "webview_navigation_server.py"
CERTIFICATE = ROOT / "tests" / "fixtures" / "webview_navigation_cert.pem"
DIST = APP_DIR / "dist"
ASSET_URL = "zero://app/docs/My%20File%23%25.html"
PRIVATE_ORIGIN = "native-sdk-app.localhost"
TERMINALS = {"finished", "failed", "cancelled"}
FRAME = {"x": 24, "y": 24, "width": 320, "height": 220}


class Failure(RuntimeError):
    pass


def check(condition: bool, message: str) -> None:
    if not condition:
        raise Failure(message)


@dataclass(frozen=True)
class Event:
    window_id: int
    label: str
    navigation_id: int
    phase: str
    url: str
    failure_class: str


@dataclass(frozen=True)
class Record:
    offset: int
    line: str
    event: Event | None


@dataclass(frozen=True)
class FixtureMetadata:
    http_origin: str
    https_origin: str
    certificate_sha256: str


def fixture_certificate_fingerprint() -> str:
    try:
        der = ssl.PEM_cert_to_DER_cert(CERTIFICATE.read_text(encoding="ascii"))
    except (OSError, ValueError) as error:
        raise Failure(f"invalid fixture certificate: {error}") from error
    import hashlib
    return hashlib.sha256(der).hexdigest()


def parse_fixture_metadata(text: str, expected_fingerprint: str) -> FixtureMetadata:
    try:
        value = json.loads(text)
    except json.JSONDecodeError as error:
        raise Failure(f"fixture metadata is not valid JSON: {error}") from error
    check(isinstance(value, dict), "fixture metadata must be an object")
    expected_keys = {"version", "http_origin", "https_origin", "certificate_sha256"}
    check(set(value) == expected_keys, f"fixture metadata keys differ: {sorted(value)}")
    check(type(value["version"]) is int and value["version"] == 1, "fixture metadata version must be integer 1")
    origin_pattern = re.compile(r"^(http|https)://127\.0\.0\.1:([1-9][0-9]{0,4})$")
    origins: dict[str, str] = {}
    ports: dict[str, int] = {}
    for name, scheme in (("http_origin", "http"), ("https_origin", "https")):
        origin = value[name]
        check(isinstance(origin, str), f"fixture {name} must be a string")
        match = origin_pattern.fullmatch(origin)
        check(match is not None and match.group(1) == scheme, f"fixture {name} is not an exact loopback {scheme} origin")
        port = int(match.group(2))
        check(port <= 65535, f"fixture {name} port is out of range")
        origins[name], ports[name] = origin, port
    check(ports["http_origin"] != ports["https_origin"], "fixture HTTP and HTTPS ports must differ")
    fingerprint = value["certificate_sha256"]
    check(isinstance(fingerprint, str) and re.fullmatch(r"[0-9a-f]{64}", fingerprint) is not None,
          "fixture certificate fingerprint must be lowercase SHA256 hex")
    check(fingerprint == expected_fingerprint, "fixture certificate fingerprint does not match committed certificate")
    return FixtureMetadata(origins["http_origin"], origins["https_origin"], fingerprint)


def parse_event(line: str) -> Event | None:
    if 'name="webview.navigation"' not in line:
        return None
    fields = {
        match.group(1): match.group(2) if match.group(2) is not None else match.group(3)
        for match in re.finditer(r'(\w+)=(?:"([^"]*)"|(\S+))', line)
    }
    names = ("window_id", "label", "navigation_id", "phase", "url", "failure_class")
    check(all(name in fields for name in names), f"malformed lifecycle record: {line.rstrip()}")
    try:
        return Event(int(fields["window_id"]), fields["label"], int(fields["navigation_id"]),
                     fields["phase"], fields["url"], fields["failure_class"])
    except ValueError as error:
        raise Failure(f"non-numeric lifecycle identifier: {line.rstrip()}") from error


class Log:
    def __init__(self, path: Path):
        self.path = path

    def cursor(self) -> int:
        try:
            data = self.path.read_bytes()
        except FileNotFoundError:
            return 0
        if not data or data.endswith(b"\n"):
            return len(data)
        return data.rfind(b"\n") + 1

    def records(self, cursor: int = 0) -> list[Record]:
        try:
            stream = self.path.open("rb")
        except FileNotFoundError:
            return []
        output: list[Record] = []
        with stream:
            stream.seek(cursor)
            while raw := stream.readline():
                offset = stream.tell() - len(raw)
                if not raw.endswith(b"\n"):
                    break  # Re-read the incomplete line on the next poll.
                line = raw.decode("utf-8", errors="replace")
                output.append(Record(offset, line, parse_event(line)))
        return output

    def events(self, cursor: int = 0) -> list[Record]:
        return [record for record in self.records(cursor) if record.event is not None]

    def terminal_count(self, navigation_id: int) -> int:
        return sum(record.event.navigation_id == navigation_id and record.event.phase in TERMINALS
                   for record in self.events() if record.event is not None)

    def text(self) -> str:
        try:
            return self.path.read_text(encoding="utf-8", errors="replace")
        except FileNotFoundError:
            return ""


def remove_path(path: Path) -> None:
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.exists():
        shutil.rmtree(path)


@contextmanager
def staged_assets() -> Iterator[None]:
    CACHE.mkdir(parents=True, exist_ok=True)
    backup = CACHE / f"native-sdk-webview-navigation-dist-backup-{os.getpid()}-{uuid.uuid4().hex}"
    had_dist = os.path.lexists(DIST)
    if had_dist:
        DIST.rename(backup)
    try:
        (DIST / "docs").mkdir(parents=True)
        (DIST / "index.html").write_text("<!doctype html><title>Navigation smoke</title><p>ready</p>\n", encoding="utf-8")
        (DIST / "docs" / "My File#%.html").write_text(
            "<!doctype html><title>Encoded asset</title><p>asset</p>\n", encoding="utf-8")
        yield
    finally:
        if os.path.lexists(DIST):
            remove_path(DIST)
        if had_dist and os.path.lexists(backup):
            backup.rename(DIST)


class Smoke:
    def __init__(self, app: Path, cli: Path):
        self.app, self.cli = app, cli
        self.log = Log(LOG_PATH)
        self.app_process: subprocess.Popen[bytes] | None = None
        self.fixture_process: subprocess.Popen[bytes] | None = None
        self.log_stream: BinaryIO | None = None
        self.fixture_log_stream: BinaryIO | None = None
        self.fixture: FixtureMetadata | None = None
        self.tls_navigation_id: int | None = None

    def run(self) -> None:
        check(self.app.is_file(), f"WebView app does not exist: {self.app}")
        check(self.cli.is_file(), f"Native CLI does not exist: {self.cli}")
        check(FIXTURE.is_file(), f"navigation fixture does not exist: {FIXTURE}")
        AUTOMATION.mkdir(parents=True, exist_ok=True)
        for path in list(AUTOMATION.glob("command-*.txt")) + [
            AUTOMATION / "bridge-response.txt", AUTOMATION / "snapshot.txt",
            AUTOMATION / "windows.txt", AUTOMATION / "accessibility.txt",
            METADATA_PATH, LOG_PATH, FIXTURE_LOG_PATH,
        ]:
            path.unlink(missing_ok=True)
        with staged_assets():
            try:
                self.start_processes()
                self.matrix()
            finally:
                self.stop(self.app_process)
                self.stop(self.fixture_process)
                if self.log_stream:
                    self.log_stream.close()
                if self.fixture_log_stream:
                    self.fixture_log_stream.close()

    @staticmethod
    def popen_options() -> dict[str, object]:
        return ({"creationflags": subprocess.CREATE_NEW_PROCESS_GROUP} if os.name == "nt"
                else {"start_new_session": True})

    def start_processes(self) -> None:
        self.fixture_log_stream = FIXTURE_LOG_PATH.open("wb")
        self.fixture_process = subprocess.Popen(
            [sys.executable, str(FIXTURE), str(METADATA_PATH)], cwd=ROOT,
            stdout=subprocess.DEVNULL, stderr=self.fixture_log_stream, **self.popen_options())
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and (not METADATA_PATH.is_file() or METADATA_PATH.stat().st_size == 0):
            if self.fixture_process.poll() is not None:
                raise Failure(self.fixture_diagnostic("navigation fixture exited before publishing its port"))
            time.sleep(0.1)
        if not METADATA_PATH.is_file() or METADATA_PATH.stat().st_size == 0:
            raise Failure(self.fixture_diagnostic("navigation fixture did not start"))
        self.fixture = parse_fixture_metadata(
            METADATA_PATH.read_text(encoding="utf-8"), fixture_certificate_fingerprint())

        env = os.environ.copy()
        env.pop("NATIVE_SDK_FRONTEND_URL", None)
        env["NATIVE_SDK_FRONTEND_ASSETS"] = "1"
        env["NATIVE_SDK_NAVIGATION_HTTP_ORIGIN"] = self.fixture.http_origin
        env["NATIVE_SDK_NAVIGATION_HTTPS_ORIGIN"] = self.fixture.https_origin
        self.log_stream = LOG_PATH.open("wb")
        self.app_process = subprocess.Popen(
            [str(self.app)], cwd=APP_DIR, env=env, stdout=self.log_stream,
            stderr=subprocess.STDOUT, **self.popen_options())
        time.sleep(0.1)
        self.app_alive()

    @staticmethod
    def fixture_diagnostic(message: str) -> str:
        if not FIXTURE_LOG_PATH.is_file():
            return message
        tail = FIXTURE_LOG_PATH.read_text(encoding="utf-8", errors="replace").splitlines()[-80:]
        tail_text = "\n".join(tail)
        return f"{message}\n---- navigation fixture stderr ----\n{tail_text}"

    @staticmethod
    def stop(process: subprocess.Popen[bytes] | None) -> None:
        if process is None or process.poll() is not None:
            return
        if os.name == "nt":
            subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"], check=False,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        else:
            process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)

    def app_alive(self) -> None:
        check(self.app_process is not None and self.app_process.poll() is None,
              f"WebView app exited with code {None if self.app_process is None else self.app_process.returncode}")

    def cli_run(self, *args: str) -> str:
        self.app_alive()
        try:
            result = subprocess.run([str(self.cli), "automate", *args], cwd=APP_DIR, capture_output=True,
                                    text=True, encoding="utf-8", errors="replace", timeout=40, check=False)
        except subprocess.TimeoutExpired as error:
            raise Failure(f"native automate {args[0]} timed out") from error
        check(result.returncode == 0,
              f"native automate {' '.join(args)} failed ({result.returncode}):\n{result.stderr}{result.stdout}")
        return result.stdout

    def operation(self, request_id: str, command: str, payload: dict[str, object],
                  expected_ok: bool = True) -> tuple[int, dict[str, object]]:
        cursor = self.log.cursor()  # Every operation owns a fresh evidence window.
        request = json.dumps({"id": request_id, "command": command, "payload": payload}, separators=(",", ":"))
        response_path = AUTOMATION / "bridge-response.txt"
        response_path.unlink(missing_ok=True)
        self.cli_run("bridge", request)
        check(response_path.is_file(), f"bridge {request_id!r} produced no response artifact")
        output = response_path.read_text(encoding="utf-8", errors="replace")
        try:
            response = json.loads(output.strip())
        except json.JSONDecodeError as error:
            raise Failure(f"bridge {request_id!r} returned invalid JSON: {output!r}") from error
        check(isinstance(response, dict) and response.get("id") == request_id,
              f"bridge response id mismatch for {request_id!r}: {response!r}")
        check(response.get("ok") is expected_ok,
              f"bridge {request_id!r} expected ok={expected_ok}, got {response!r}")
        return cursor, response

    def wait(self, cursor: int, predicate: Callable[[Record], bool], description: str) -> Record:
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            for record in self.log.records(cursor):
                if predicate(record):
                    return record
            self.app_alive()
            time.sleep(0.1)
        raise Failure(f"timed out waiting for {description}")

    def event(self, cursor: int, **wanted: object) -> Record:
        excluded = wanted.pop("not_navigation_id", None)
        def matches(record: Record) -> bool:
            event = record.event
            return event is not None and all(getattr(event, key) == value for key, value in wanted.items()) \
                and (excluded is None or event.navigation_id != excluded)
        return self.wait(cursor, matches, f"lifecycle event {wanted}")

    def create(self, request_id: str, label: str, url: str) -> tuple[int, Record]:
        cursor, _ = self.operation(request_id, "native-sdk.webview.create",
                                   {"label": label, "url": url, "frame": FRAME})
        return cursor, self.event(cursor, label=label, phase="started", url=url)

    def navigate(self, request_id: str, url: str) -> tuple[int, Record]:
        cursor, _ = self.operation(request_id, "native-sdk.webview.navigate", {"label": "smoke", "url": url})
        return cursor, self.event(cursor, label="smoke", phase="started", url=url)

    def one_terminal(self, navigation_id: int) -> None:
        count = self.log.terminal_count(navigation_id)
        check(count == 1, f"navigation {navigation_id} emitted {count} terminals, expected one")

    def raw_parent_close(self) -> Path:
        request = json.dumps({"id": "parent-close", "command": "native-sdk.window.close", "payload": {"id": 1}},
                             separators=(",", ":"))
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            numbers = [int(match.group(1)) for path in AUTOMATION.glob("command-*.txt")
                       if (match := re.fullmatch(r"command-(\d+)\.txt", path.name))]
            path = AUTOMATION / f"command-{max(numbers, default=0) + 1}.txt"
            flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_BINARY", 0)
            try:
                descriptor = os.open(path, flags, 0o600)
            except FileExistsError:
                continue
            with os.fdopen(descriptor, "wb") as stream:
                stream.write(f"bridge {request}\n".encode())
            return path
        raise Failure("could not claim an exclusive queue entry for parent close")

    def matrix(self) -> None:
        check(self.fixture is not None, "fixture metadata was not loaded")
        base = self.fixture.http_origin
        ready = self.cli_run("wait")
        check("ready=true" in ready and "dispatch_errors=0" in ready, f"automation was not healthy: {ready!r}")
        self.wait(0, lambda record: 'name="webview.load"' in record.line, "the main WebView load")

        cursor, ping = self.operation("ping", "native.ping", {"source": "navigation-smoke"})
        check("pong from Zig" in json.dumps(ping) and not self.log.events(cursor), "native.ping failed or emitted lifecycle")

        cursor, asset_start = self.create("asset-create", "asset-encoded", ASSET_URL)
        asset_id = asset_start.event.navigation_id  # type: ignore[union-attr]
        asset_finish = self.event(cursor, navigation_id=asset_id, phase="finished", url=ASSET_URL)
        check(asset_start.offset < asset_finish.offset, "asset navigation finished before it started")
        self.one_terminal(asset_id)
        cursor, _ = self.operation("asset-frame", "native-sdk.webview.setFrame",
                                   {"label": "asset-encoded", "frame": {"x": 36, "y": 36, "width": 420, "height": 260}})
        check(not self.log.events(cursor), "setFrame emitted navigation lifecycle")
        cursor, _ = self.operation("asset-close", "native-sdk.webview.close", {"label": "asset-encoded"})
        check(not self.log.events(cursor), "closing a completed asset emitted lifecycle")

        cursor, started = self.create("redirect-create", "smoke", f"{base}/start")
        redirect_id = started.event.navigation_id  # type: ignore[union-attr]
        redirected = self.event(cursor, navigation_id=redirect_id, phase="redirected", url=f"{base}/final")
        finished = self.event(cursor, navigation_id=redirect_id, phase="finished", url=f"{base}/final")
        check(started.offset < redirected.offset < finished.offset, "redirect order was not start -> redirect -> finish")
        self.one_terminal(redirect_id)
        time.sleep(0.5)
        check(all(record.event.url != f"{base}/frame" for record in self.log.events() if record.event),
              "subframe navigation leaked into lifecycle")

        _, slow = self.navigate("slow", f"{base}/slow")
        slow_id = slow.event.navigation_id  # type: ignore[union-attr]
        cursor, replacement = self.navigate("supersede", f"{base}/final")
        replacement_id = replacement.event.navigation_id  # type: ignore[union-attr]
        cancelled = self.event(cursor, navigation_id=slow_id, phase="cancelled")
        check(slow_id != replacement_id and cancelled.offset < replacement.offset,
              "different-URL cancellation did not precede a distinct replacement")
        self.event(cursor, navigation_id=replacement_id, phase="finished", url=f"{base}/final")
        self.one_terminal(slow_id); self.one_terminal(replacement_id)

        same_url = f"{base}/same"
        _, same_a = self.navigate("same-a", same_url)
        same_a_id = same_a.event.navigation_id  # type: ignore[union-attr]
        cursor, same_b = self.navigate("same-b", same_url)
        same_b_id = same_b.event.navigation_id  # type: ignore[union-attr]
        same_cancel = self.event(cursor, navigation_id=same_a_id, phase="cancelled")
        check(same_a_id != same_b_id and same_cancel.offset < same_b.offset,
              "same-URL cancellation did not precede distinct B")
        self.event(cursor, navigation_id=same_b_id, phase="finished", url=same_url)
        time.sleep(4)
        self.one_terminal(same_a_id); self.one_terminal(same_b_id)

        tls_url = f"{self.fixture.https_origin}/tls"
        cursor, tls_started = self.navigate("tls", tls_url)
        tls_id = tls_started.event.navigation_id  # type: ignore[union-attr]
        self.tls_navigation_id = tls_id
        self.event(cursor, navigation_id=tls_id, phase="failed", url=tls_url, failure_class="tls")
        time.sleep(0.5)
        self.one_terminal(tls_id)
        check(all(record.event is None or record.event.navigation_id != tls_id or record.event.phase != "finished"
                  for record in self.log.events(cursor)), "TLS navigation emitted finished after failed")

        disconnect = f"{base}/disconnect"
        cursor, offline = self.navigate("disconnect", disconnect)
        offline_id = offline.event.navigation_id  # type: ignore[union-attr]
        self.event(cursor, navigation_id=offline_id, phase="failed", failure_class="network")
        self.one_terminal(offline_id)

        used_ports = {int(base.rsplit(":", 1)[1]), int(self.fixture.https_origin.rsplit(":", 1)[1])}
        blocked_port = next(port for port in range(1, 65536) if port not in used_ports)
        blocked = f"http://127.0.0.1:{blocked_port}/policy-blocked"
        cursor, _ = self.operation("blocked", "native-sdk.webview.navigate",
                                   {"label": "smoke", "url": blocked}, False)
        time.sleep(0.5)
        check(all(record.event.url != blocked for record in self.log.events(cursor) if record.event),
              "policy-rejected URL emitted lifecycle")
        self.operation("smoke-close", "native-sdk.webview.close", {"label": "smoke"})

        for index in range(1, 18):
            label, url = f"closing-{index}", f"{base}/slow/{index}"
            _, started = self.create(f"create-{index}", label, url)
            navigation_id = started.event.navigation_id  # type: ignore[union-attr]
            cursor, _ = self.operation(f"close-{index}", "native-sdk.webview.close", {"label": label})
            self.event(cursor, navigation_id=navigation_id, phase="cancelled")
            self.one_terminal(navigation_id)

        self.operation("sentinel", "native-sdk.window.create",
                       {"label": "sentinel", "title": "Lifecycle sentinel", "width": 320, "height": 240})
        parent_url = f"{base}/slow/parent-close"
        _, parent = self.create("parent-child", "parent-child", parent_url)
        parent_id = parent.event.navigation_id  # type: ignore[union-attr]
        cursor = self.log.cursor()
        raw_path = self.raw_parent_close()
        self.event(cursor, navigation_id=parent_id, phase="cancelled")
        deadline = time.monotonic() + 5
        while raw_path.exists() and time.monotonic() < deadline:
            self.app_alive(); time.sleep(0.1)
        check(not raw_path.exists(), f"raw command was not consumed: {raw_path.name}")
        self.one_terminal(parent_id)

        snapshot = self.cli_run("snapshot")
        check("dispatch_errors=0" in snapshot, f"runtime finished with dispatch errors: {snapshot!r}")
        self.final_health()

    def final_health(self) -> None:
        self.app_alive()
        text = self.log.text()
        check(self.tls_navigation_id is not None, "TLS matrix case did not run")
        self.one_terminal(self.tls_navigation_id)
        check(all(record.event is None or record.event.navigation_id != self.tls_navigation_id or record.event.phase != "finished"
                  for record in self.log.events()), "TLS navigation eventually emitted finished")
        check(all(record.event.label != "main" for record in self.log.events() if record.event),
              'reserved label "main" emitted lifecycle')
        check(PRIVATE_ORIGIN not in text, "private WebView2 asset origin leaked into the public log")
        for marker in ('name="dispatch.error"', "platform callback failed", "CallbackFailed",
                       "WebViewNavigationCapacityExceeded", "Segmentation fault", "access violation", "fatal error", "crash"):
            check(marker.lower() not in text.lower(), f"app log contains failure marker {marker!r}")
        pending = sorted(path.name for path in AUTOMATION.glob("command-*.txt"))
        check(not pending, f"automation queue retained commands: {pending}")


def synthetic(navigation_id: int, phase: str, url: str, label: str = "smoke") -> str:
    return ('ts=1 name="webview.navigation" window_id=1 '
            f'label="{label}" navigation_id={navigation_id} phase="{phase}" url="{url}" failure_class=""\n')


def self_test() -> None:
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "events.log"
        path.write_text(synthetic(40, "started", "https://stale.invalid"), encoding="utf-8")
        log, cursor = Log(path), path.stat().st_size
        with path.open("a", encoding="utf-8") as stream:
            stream.write(synthetic(40, "cancelled", "https://stale.invalid"))
            stream.write(synthetic(41, "started", ASSET_URL, "asset-encoded"))
            stream.write(synthetic(41, "finished", ASSET_URL, "asset-encoded"))
        records = log.events(cursor)
        check([record.event.navigation_id for record in records if record.event] == [40, 41, 41], "cursor/ID parse failed")
        check(records[0].offset < records[1].offset < records[2].offset, "event order parse failed")
        check(log.terminal_count(40) == log.terminal_count(41) == 1, "terminal count failed")
        check(records[1].event is not None and records[1].event.url == ASSET_URL, "encoded URL changed")

    fingerprint = "a" * 64
    valid = {
        "version": 1,
        "http_origin": "http://127.0.0.1:49152",
        "https_origin": "https://127.0.0.1:49153",
        "certificate_sha256": fingerprint,
    }
    parsed = parse_fixture_metadata(json.dumps(valid), fingerprint)
    check(parsed.http_origin == valid["http_origin"] and parsed.https_origin == valid["https_origin"],
          "valid fixture metadata changed")
    invalid_values = [
        "not json",
        "[]",
        json.dumps({**valid, "extra": True}),
        json.dumps({**valid, "version": True}),
        json.dumps({**valid, "version": 2}),
        json.dumps({**valid, "http_origin": "http://localhost:49152"}),
        json.dumps({**valid, "http_origin": "http://127.0.0.1:0"}),
        json.dumps({**valid, "http_origin": "http://127.0.0.1:49152/path"}),
        json.dumps({**valid, "https_origin": "http://127.0.0.1:49153"}),
        json.dumps({**valid, "https_origin": "https://127.0.0.1:49152"}),
        json.dumps({**valid, "certificate_sha256": "A" * 64}),
        json.dumps(valid),
    ]
    for index, value in enumerate(invalid_values):
        try:
            parse_fixture_metadata(value, "b" * 64 if index == len(invalid_values) - 1 else fingerprint)
        except Failure:
            continue
        raise Failure(f"invalid fixture metadata case {index} was accepted")
    print("webview navigation smoke self-test ok")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=lambda value: Path(value).expanduser().resolve())
    parser.add_argument("--cli", type=lambda value: Path(value).expanduser().resolve())
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        check(args.app is None and args.cli is None, "--self-test cannot be combined with --app or --cli")
        self_test(); return 0
    parser.error("--app and --cli are required unless --self-test is used") if args.app is None or args.cli is None else None
    try:
        Smoke(args.app, args.cli).run()
    except (Failure, OSError, subprocess.SubprocessError) as error:
        print(f"webview navigation lifecycle smoke failed: {error}", file=sys.stderr)
        if LOG_PATH.is_file():
            print("---- WebView lifecycle log (last 240 lines) ----", file=sys.stderr)
            print("\n".join(LOG_PATH.read_text(encoding="utf-8", errors="replace").splitlines()[-240:]), file=sys.stderr)
        return 1
    print("webview navigation lifecycle smoke ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
