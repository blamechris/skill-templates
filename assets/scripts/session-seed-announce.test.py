#!/usr/bin/env python3
"""Real writer + local HTTP regressions; no daemon, model or third-party deps."""
import contextlib
import http.server
import json
import os
from pathlib import Path
import queue
import secrets
import subprocess
import sys
import tempfile
import threading
import time
import unittest

SCRIPT = Path(__file__).with_name("session-seed.py")


class AnnouncementTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="seed-announce-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "demo"
        self.repo.mkdir()
        subprocess.run(["git", "init", "-q", "-b", "main", str(self.repo)], check=True)
        subprocess.run(["git", "-C", str(self.repo), "-c", "user.name=Fixture", "-c", "user.email=fixture@example.test",
                        "commit", "-q", "--allow-empty", "-m", "fixture"], check=True)
        self.config = self.root / "config"
        self.config.mkdir()
        self.secret = secrets.token_hex(32)
        self.secret_file = self.config / "ingest-secret"
        self.secret_file.write_text(self.secret)
        self.secret_file.chmod(0o600)
        self.body = self.root / "body.md"
        self.body.write_text("## STATE\n\n- Completed HTTP integration checks; no PR is open.\n"
                             "- Read assets/scripts/session-seed.py and the HTTP tests first.\n\n"
                             "## TL;DR — what shipped\n\nPrivate seed body marker stays on disk.\n")
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(("CHROXY_", "CLAUDE_", "GIT_"))}
        self.env.update(HOME=str(self.root), CHROXY_CONFIG_DIR=str(self.config),
                        CLAUDE_HANDOFF_DIR=str(self.root / "handoffs"), CLAUDE_CODE_SESSION_ID="fixture-session")

    @contextlib.contextmanager
    def receiver(self, delay=0, status=200):
        received = queue.Queue()

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(handler):
                received.put((handler.path, handler.headers.get("Authorization"),
                              json.loads(handler.rfile.read(int(handler.headers["Content-Length"])))))
                time.sleep(delay)
                handler.send_response(status)
                if status == 302:
                    handler.send_header("Location", "/redirect-target")
                handler.end_headers()

            def log_message(handler, *args):
                pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        server.daemon_threads = True
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.env["CHROXY_INGEST_URL"] = "http://127.0.0.1:%s/api/events" % server.server_port
        try:
            yield received, server.server_port
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)

    def write(self, *extra, cwd=None):
        return subprocess.run([sys.executable, str(SCRIPT), "write", "--picks-up-at", "Verify HTTP continuation (agent Sol)",
                               "--boundary-reason", "package complete", "--next",
                               "Verify continuation. Acceptance: paths arrive without seed content.", "--body-file", str(self.body), *extra],
                              cwd=cwd or self.repo, env=self.env, capture_output=True, text=True, timeout=5)

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)
        seed = self.root / "handoffs" / "NEXT-demo.md"
        self.assertEqual(result.stdout, "seed: %s\n" % seed)
        self.assertEqual(result.stderr, "")
        self.assertIn("Private seed body marker", seed.read_text())
        return seed

    def test_success_paths_only_and_config_discovery(self):
        with self.receiver() as (received, port):
            del self.env["CHROXY_INGEST_URL"]
            (self.config / "config.json").write_text(json.dumps({"host": "0.0.0.0", "port": port}))
            seed = self.assert_success(self.write())
            path, auth, event = received.get(timeout=1)
            self.assertEqual(path, "/api/events")
            self.assertEqual(auth, "Bearer " + self.secret)
            self.assertEqual(set(event), {"source", "type", "ts", "data"})
            self.assertEqual(event["source"], "session-seed")
            self.assertEqual(event["type"], "wave_complete")
            self.assertLess(abs(event["ts"] - time.time() * 1000), 5000)
            self.assertEqual(event["data"], {"seedPath": str(seed), "cwd": str(self.repo.resolve())})
            self.assertNotIn("Private seed body marker", json.dumps(event))
            self.assertTrue(received.empty())

    def test_linked_worktree_announces_durable_main_checkout(self):
        linked = self.root / "linked"
        subprocess.run(["git", "-C", str(self.repo), "worktree", "add", "-q", "-b", "fixture", str(linked)], check=True)
        with self.receiver() as (received, _):
            self.assert_success(self.write(cwd=linked))
            event = received.get(timeout=1)[2]
            subprocess.run(["git", "-C", str(self.repo), "worktree", "remove", str(linked)], check=True)
            self.assertEqual(event["data"]["cwd"], str(self.repo.resolve()))
            self.assertTrue(Path(event["data"]["cwd"]).is_dir())

    def test_refused_write_does_not_announce(self):
        with self.receiver() as (received, _):
            self.body.write_text("")
            self.assertEqual(self.write().returncode, 1)
            self.assertTrue(received.empty())

    def test_offline_preserves_output_exit_and_seed(self):
        with self.receiver() as (_, port):
            pass
        self.env["CHROXY_INGEST_URL"] = "http://127.0.0.1:%s/api/events" % port
        self.assert_success(self.write())

    def test_timeout_is_bounded_and_preserves_seed(self):
        with self.receiver(delay=2) as (received, _):
            started = time.monotonic()
            self.assert_success(self.write())
            self.assertLess(time.monotonic() - started, 1.5)
            self.assertEqual(received.qsize(), 1)

    def test_http_failures_and_redirect_never_change_success_or_retry(self):
        for status in (302, 401, 500):
            with self.subTest(status=status), self.receiver(status=status) as (received, _):
                self.assert_success(self.write())
                self.assertEqual(received.qsize(), 1)

    def test_missing_untrusted_symlink_secret_and_opt_out_do_not_send(self):
        with self.receiver() as (received, _):
            self.secret_file.chmod(0o644)
            self.assert_success(self.write())
            self.secret_file.unlink()
            self.assert_success(self.write())
            target = self.root / "target"
            target.write_text(self.secret)
            target.chmod(0o600)
            self.secret_file.symlink_to(target)
            self.assert_success(self.write())
            self.env["CHROXY_INGEST_SECRET"] = self.secret
            self.env["CHROXY_SEED_ANNOUNCE"] = "0"
            self.assert_success(self.write())
            self.assertTrue(received.empty())

    def test_remote_plaintext_url_never_sends(self):
        self.env["CHROXY_INGEST_URL"] = "http://192.0.2.1/api/events"
        self.assert_success(self.write())

    def test_unproved_write_does_not_announce(self):
        with self.receiver() as (received, _):
            result = self.write("--no-verify")
            self.assertEqual(result.returncode, 0)
            self.assertTrue(result.stdout.startswith("wrote (UNPROVED): "))
            self.assertEqual(result.stderr, "")
            self.assertTrue(received.empty())

    def test_slow_dns_is_covered_by_total_deadline(self):
        # Socket timeouts do not bound getaddrinfo. A normal Python startup
        # fixture delays that system call so the child deadline is exercised.
        startup = self.root / "startup"
        startup.mkdir()
        (startup / "sitecustomize.py").write_text(
            "import socket,time\noriginal=socket.getaddrinfo\n"
            "def slow(*args, **kwargs):\n time.sleep(5)\n return original(*args, **kwargs)\n"
            "socket.getaddrinfo=slow\n")
        self.env["PYTHONPATH"] = str(startup)
        self.env["CHROXY_INGEST_URL"] = "https://example.test/api/events"
        started = time.monotonic()
        self.assert_success(self.write())
        self.assertLess(time.monotonic() - started, 1.5)

    @unittest.skipUnless(hasattr(os, "mkfifo"), "requires POSIX FIFO")
    def test_stalled_config_and_nonregular_secret_are_bounded(self):
        with self.receiver() as (received, _):
            del self.env["CHROXY_INGEST_URL"]
            os.mkfifo(self.config / "config.json", 0o600)
            started = time.monotonic()
            self.assert_success(self.write())
            self.assertLess(time.monotonic() - started, 1.5)
            self.secret_file.unlink()
            os.mkfifo(self.secret_file, 0o600)
            self.assert_success(self.write())
            self.assertTrue(received.empty())


if __name__ == "__main__":
    unittest.main()
