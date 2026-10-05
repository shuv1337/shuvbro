#!/usr/bin/env python3
import importlib.util
import io
import json
import os
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock


READER_PATH = Path(__file__).parents[1] / "bin" / "backends" / "herdr-eventwait.py"
SPEC = importlib.util.spec_from_file_location("herdr_eventwait", READER_PATH)
READER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(READER)


class FailingSocket:
    def settimeout(self, _timeout):
        pass

    def recv(self, _size):
        raise OSError("receive failed")


class ClosingStreamSocket:
    def __init__(self):
        self.chunks = [
            b'{"result":{"type":"subscription_started"}}\n',
            b"",
        ]

    def settimeout(self, _timeout):
        pass

    def connect(self, _path):
        pass

    def sendall(self, _request):
        pass

    def recv(self, _size):
        return self.chunks.pop(0)


class RejectedSubscriptionSocket(ClosingStreamSocket):
    def __init__(self):
        self.chunks = [b'{"result":{"type":"not_started"}}\n']


class EventWaitReadLineTest(unittest.TestCase):
    def test_deadline_is_clean_timeout(self):
        left, right = socket.socketpair()
        self.addCleanup(left.close)
        self.addCleanup(right.close)

        line, buf, outcome = READER._read_line(left, b"", time.monotonic())

        self.assertIsNone(line)
        self.assertEqual(buf, b"")
        self.assertEqual(outcome, "timeout")

    def test_peer_closure_is_runtime_failure(self):
        left, right = socket.socketpair()
        self.addCleanup(left.close)
        right.close()

        line, buf, outcome = READER._read_line(
            left, b"", time.monotonic() + 1
        )

        self.assertIsNone(line)
        self.assertEqual(buf, b"")
        self.assertEqual(outcome, "closed")

    def test_receive_error_is_runtime_failure(self):
        line, buf, outcome = READER._read_line(
            FailingSocket(), b"", time.monotonic() + 1
        )

        self.assertIsNone(line)
        self.assertEqual(buf, b"")
        self.assertEqual(outcome, "error")

    def test_main_reports_early_stream_closure(self):
        stdout = io.StringIO()
        with mock.patch.object(READER.socket, "socket", return_value=ClosingStreamSocket()):
            with mock.patch.object(READER.sys, "stdout", stdout):
                result = READER.main(["herdr-eventwait.py", "socket", "1", "pane"])

        self.assertEqual(result, 4)
        self.assertEqual(stdout.getvalue(), "@subscribed\n")

    def test_main_does_not_signal_readiness_before_valid_ack(self):
        stdout = io.StringIO()
        with mock.patch.object(
            READER.socket, "socket", return_value=RejectedSubscriptionSocket()
        ):
            with mock.patch.object(READER.sys, "stdout", stdout):
                result = READER.main(["herdr-eventwait.py", "socket", "1", "pane"])

        self.assertEqual(result, 3)
        self.assertEqual(stdout.getvalue(), "")


class WatcherEventWaitShutdownTest(unittest.TestCase):
    """Run the real watcher/adapter/reader against a private fake Unix socket."""

    @staticmethod
    def process_table():
        rows = subprocess.check_output(
            ["ps", "-axo", "pid=,ppid=,pgid=,stat="], text=True
        ).splitlines()
        return {
            int(pid): (int(parent), int(group), status)
            for pid, parent, group, status in (row.split() for row in rows)
        }

    @classmethod
    def descendants(cls, pid):
        table = cls.process_table()
        found = {pid}
        while True:
            children = {p for p, (parent, _, _) in table.items() if parent in found}
            if children <= found:
                return found
            found |= children

    def check_shutdown(self, sig, before_ack=False):
        root = READER_PATH.parents[2]
        with tempfile.TemporaryDirectory(prefix="fm-ev-", dir="/tmp") as scratch:
            home = Path(scratch)
            state = home / "state"
            state.mkdir()
            (home / "config").mkdir()
            fakebin = home / "fakebin"
            fakebin.mkdir()
            sock_path = str(home / "socket")
            (state / "task.meta").write_text(
                "window=fake:pane\nbackend=herdr\nkind=ship\n"
            )
            # Only the session lookup and idle level reconcile need answers.
            # Every Herdr invocation resolves to this stub, never a live session.
            herdr = fakebin / "herdr"
            herdr.write_text(
                "#!/bin/sh\n"
                'case "$1 $2" in\n'
                "'session list') printf '%s\\n' "
                + "'"
                + json.dumps({"sessions": [{"name": "fake", "socket_path": sock_path}]})
                + "';;\n"
                "'agent get') printf '%s\\n' "
                "'{\"result\":{\"agent\":{\"agent_status\":\"idle\"}}}';;\n"
                "*) exit 1;;\nesac\n"
            )
            herdr.chmod(0o700)
            reader_pid_file = home / "reader.pid"
            wrapper = home / "reader.py"
            wrapper.write_text(
                "import os, sys\n"
                f"open({str(reader_pid_file)!r}, 'w').write(str(os.getpid()))\n"
                f"os.execv(sys.executable, [sys.executable, {str(READER_PATH)!r}, *sys.argv[1:]])\n"
            )
            server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            server.bind(sock_path)
            server.listen(1)
            server.settimeout(15)
            ready = threading.Event()
            closed = threading.Event()
            errors = []

            def serve():
                try:
                    conn, _ = server.accept()
                    with conn:
                        conn.settimeout(15)
                        request = b""
                        while b"\n" not in request:
                            request += conn.recv(65536)
                        self.assertEqual(json.loads(request)["method"], "events.subscribe")
                        if not before_ack:
                            conn.sendall(b'{"result":{"type":"subscription_started"}}\n')
                        ready.set()
                        self.assertEqual(conn.recv(65536), b"")
                        closed.set()
                except Exception as exc:
                    errors.append(exc)
                    ready.set()

            thread = threading.Thread(target=serve, daemon=True)
            thread.start()
            env = dict(os.environ)
            env.update(
                PATH=f"{fakebin}:{os.environ['PATH']}",
                FM_HOME=scratch,
                FM_ROOT_OVERRIDE=str(root),
                FM_STATE_OVERRIDE=str(state),
                FM_CONFIG_OVERRIDE=str(home / "config"),
                FM_POLL="60",
                FM_CHECK_INTERVAL="999999",
                FM_HEARTBEAT="999999",
                FM_BACKEND_HERDR_EVENTS_FORCE="1",
                FM_BACKEND_HERDR_EVENT_READER=f"{sys.executable} {wrapper}",
                TMPDIR=scratch,
            )
            watcher = subprocess.Popen(
                ["bash", str(root / "bin" / "fm-watch.sh")],
                env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            )
            tree = set()
            try:
                self.assertTrue(ready.wait(15), "watcher never reached the socket wait")
                self.assertFalse(errors, str(errors))
                time.sleep(0.1)  # Let the acknowledged idle reconcile park in read.
                self.assertIsNone(watcher.poll(), "watcher exited before the signal")
                reader_pid = int(reader_pid_file.read_text())
                tree = self.descendants(watcher.pid)
                self.assertIn(reader_pid, tree, "test did not exercise a socket grandchild")
                files = list(state.glob(".watch-event-output.*"))
                # The baseline fails on shutdown latency; the fixed path also
                # has a private record file whose mode is part of the contract.
                for path in files:
                    self.assertEqual(path.stat().st_mode & 0o777, 0o600)
                start = time.monotonic()
                watcher.send_signal(sig)
                stdout, stderr = watcher.communicate(timeout=1)
                elapsed = time.monotonic() - start
                self.assertLess(elapsed, 1, "watcher missed the arm retirement deadline")
                self.assertEqual(len(files), 1, "event wait had no private output file")
                self.assertEqual(watcher.returncode, 1, (stdout, stderr))
                self.assertTrue(closed.wait(1), "socket reader retained its connection")
                table = self.process_table()
                self.assertFalse(tree & table.keys(), "reader process tree survived shutdown")
                self.assertFalse(list(state.glob(".watch-event-output.*")))
                self.assertFalse(list(home.glob("fm-herdr-eventwait.*")))
                self.assertFalse((state / ".watch.lock" / "pid").exists())
                print(f"watcher {sig.name} shutdown: {elapsed:.3f}s, pipes closed and reader/FIFO/output removed")
            finally:
                # Also bounded on the unfixed baseline: never leave a 60s
                # reader behind when the regression deliberately fails.
                tree |= self.descendants(watcher.pid)
                for pid in tree - {watcher.pid}:
                    try:
                        os.kill(pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                if watcher.poll() is None:
                    watcher.kill()
                watcher.communicate(timeout=3)
                server.close()
                thread.join(timeout=1)

    def test_signals_interrupt_subscribed_event_wait(self):
        for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
            with self.subTest(signal=sig.name):
                self.check_shutdown(sig)

    def test_term_interrupts_subscription_ack_wait(self):
        self.check_shutdown(signal.SIGTERM, before_ack=True)


if __name__ == "__main__":
    unittest.main()
