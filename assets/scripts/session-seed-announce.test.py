#!/usr/bin/env python3
"""Real writer + local HTTP regressions; no daemon, model or third-party deps."""
import contextlib
import http.server
import json
import os
from pathlib import Path
import queue
import runpy
import secrets
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

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
    def receiver(self, delay=0, status=200, redirect_url="/redirect-target"):
        received = queue.Queue()

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(handler):
                received.put((handler.path, handler.headers.get("Authorization"),
                              json.loads(handler.rfile.read(int(handler.headers["Content-Length"]))), "POST"))
                time.sleep(delay)
                handler.send_response(status)
                if status == 302:
                    handler.send_header("Location", redirect_url)
                handler.end_headers()

            def do_GET(handler):
                received.put((handler.path, handler.headers.get("Authorization"), None, "GET"))
                handler.send_response(200)
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

    def write(self, *extra, cwd=None, script=SCRIPT):
        return subprocess.run([sys.executable, str(script), "write", "--picks-up-at", "Verify HTTP continuation (agent Sol)",
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
            path, auth, event, method = received.get(timeout=1)
            self.assertEqual(method, "POST")
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

    def test_without_nofollow_reads_a_trusted_regular_file(self):
        reader = runpy.run_path(str(SCRIPT))["read_ingest_secret"]
        with mock.patch.object(os, "O_NOFOLLOW", 0, create=True):
            self.assertEqual(reader(str(self.secret_file)), self.secret)

    def test_without_nofollow_rejects_symlink_before_open(self):
        reader = runpy.run_path(str(SCRIPT))["read_ingest_secret"]
        link = mock.Mock(st_mode=stat.S_IFLNK | 0o777, st_dev=1, st_ino=1)
        with mock.patch.object(os, "O_NOFOLLOW", 0, create=True), mock.patch("os.lstat", return_value=link), mock.patch("os.open") as opener:
            self.assertIsNone(reader(str(self.secret_file)))
            opener.assert_not_called()

    def test_without_nofollow_rejects_replacement_between_lstat_and_open(self):
        reader = runpy.run_path(str(SCRIPT))["read_ingest_secret"]
        replacement = self.config / "replacement"
        replacement.write_text(secrets.token_hex(32))
        replacement.chmod(0o600)
        original_open = os.open

        def swapped_open(path, flags):
            os.replace(str(replacement), str(self.secret_file))
            return original_open(path, flags)

        with mock.patch.object(os, "O_NOFOLLOW", 0, create=True), mock.patch("os.open", side_effect=swapped_open), mock.patch("os.read") as read:
            self.assertIsNone(reader(str(self.secret_file)))
            read.assert_not_called()

    def test_without_nofollow_rejects_link_swap_after_descriptor_open(self):
        reader = runpy.run_path(str(SCRIPT))["read_ingest_secret"]
        initial = os.lstat(str(self.secret_file))
        link = mock.Mock(st_mode=stat.S_IFLNK | 0o777, st_dev=initial.st_dev, st_ino=initial.st_ino)
        with mock.patch.object(os, "O_NOFOLLOW", 0, create=True), mock.patch("os.lstat", side_effect=[initial, link]), mock.patch("os.read") as read:
            self.assertIsNone(reader(str(self.secret_file)))
            read.assert_not_called()

    def test_without_nofollow_missing_unreadable_or_unidentified_secret_fails_closed(self):
        reader = runpy.run_path(str(SCRIPT))["read_ingest_secret"]
        with mock.patch.object(os, "O_NOFOLLOW", 0, create=True):
            self.assertIsNone(reader(str(self.config / "missing")))
            with mock.patch("os.open", side_effect=PermissionError("fixture unreadable")):
                self.assertIsNone(reader(str(self.secret_file)))
            info = os.stat(str(self.secret_file))
            unidentified = mock.Mock(st_mode=info.st_mode, st_dev=info.st_dev, st_ino=0, st_uid=info.st_uid)
            with mock.patch("os.fstat", return_value=unidentified), mock.patch("os.read") as read:
                self.assertIsNone(reader(str(self.secret_file)))
                read.assert_not_called()

    def test_remote_plaintext_url_never_sends(self):
        self.env["CHROXY_INGEST_URL"] = "http://192.0.2.1/api/events"
        self.assert_success(self.write())
        module = runpy.run_path(str(SCRIPT))
        seed = str(self.root / "handoffs" / "NEXT-demo.md")
        with mock.patch.dict(os.environ, self.env, clear=True), mock.patch("urllib.request.OpenerDirector.open") as transport:
            module["announce_seed_http"](seed)
            transport.assert_not_called()
        # Negative control: deleting the loopback guard must reach transport.
        source = SCRIPT.read_text()
        mutant = source.replace("if not loopback:\n            return", "if False:\n            return", 1)
        self.assertNotEqual(source, mutant)
        namespace = {"__file__": str(SCRIPT), "__name__": "fixture_mutant"}
        exec(compile(mutant, str(SCRIPT), "exec"), namespace)
        with mock.patch.dict(os.environ, self.env, clear=True), mock.patch("urllib.request.OpenerDirector.open") as transport:
            namespace["announce_seed_http"](seed)
            self.assertEqual(transport.call_count, 1, "remote guard mutant must be detected")

    def test_cross_origin_redirect_is_observed_and_guard_removal_goes_red(self):
        with self.receiver() as (target, target_port):
            with self.receiver(status=302, redirect_url="http://127.0.0.1:%s/redirect-target" % target_port) as (origin, _):
                self.assert_success(self.write())
                self.assertEqual(origin.qsize(), 1)
                self.assertTrue(target.empty(), "redirect destination must see no request of any method")
                source = SCRIPT.read_text()
                mutant = source.replace("urllib.request.ProxyHandler({}), NoRedirect()", "urllib.request.ProxyHandler({})", 1)
                self.assertNotEqual(source, mutant)
                mutant_script = self.root / "redirect-mutant.py"
                mutant_script.write_text(mutant)
                self.assert_success(self.write(script=mutant_script))
                self.assertEqual(target.get(timeout=1)[3], "GET", "redirect guard mutant must be detected")

    def test_pulse_only_refresh_does_not_announce_wave_completion(self):
        with self.receiver() as (received, _):
            seed = self.assert_success(self.write())
            received.get(timeout=1)
            pulse = self.root / "pulse.json"
            pulse.write_text(json.dumps({"at": "2026-08-11T00:00:00Z", "line": "delta: no baseline | WARN: none",
                                         "state": {"scope": "demo", "tests": "PASS #123"}}))
            result = subprocess.run([sys.executable, str(SCRIPT), "write", "--refresh-pulse", str(pulse)],
                                    cwd=self.repo, env=self.env, capture_output=True, text=True, timeout=5)
            self.assert_success(result)
            self.assertIn("last_pulse:", seed.read_text())
            self.assertTrue(received.empty(), "metadata refresh is not wave completion")

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
