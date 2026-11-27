#!/usr/bin/env python3
"""Tests for laptop-agent startup auth and bounded output capture.

Run with: python3 -m unittest discover -s pkgs/laptop-agent/tests
Wired as the flake check `laptop-agent-tests` (Linux).
"""
import contextlib
import errno
import http.client
import io
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path
from unittest.mock import patch

AGENT = Path(__file__).resolve().parents[1] / "src" / "laptop_agent.py"


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class EmptyTokenTest(unittest.TestCase):
    """PR #1459 codex P1: an empty/whitespace token must fail closed."""

    def _run_with_token(self, text):
        with tempfile.NamedTemporaryFile("w", suffix="-token",
                                         delete=False) as f:
            f.write(text)
            token = f.name
        try:
            env = dict(os.environ,
                       LAPTOP_AGENT_TOKEN_FILE=token,
                       LAPTOP_AGENT_HOST="127.0.0.1",
                       LAPTOP_AGENT_PORT=str(free_port()),
                       LAPTOP_AGENT_STATE=tempfile.mkdtemp())
            return subprocess.run([sys.executable, str(AGENT)], env=env,
                                  capture_output=True, text=True, timeout=20)
        finally:
            os.unlink(token)

    def test_empty_token_refuses_to_start(self):
        p = self._run_with_token("")
        self.assertEqual(p.returncode, 3, p.stderr)
        self.assertIn("refusing to start", p.stderr)

    def test_whitespace_token_refuses_to_start(self):
        p = self._run_with_token("  \n\t\n")
        self.assertEqual(p.returncode, 3, p.stderr)

    def test_missing_token_file_refuses_to_start(self):
        env = dict(os.environ,
                   LAPTOP_AGENT_TOKEN_FILE="/nonexistent/token",
                   LAPTOP_AGENT_HOST="127.0.0.1",
                   LAPTOP_AGENT_PORT=str(free_port()),
                   LAPTOP_AGENT_STATE=tempfile.mkdtemp())
        p = subprocess.run([sys.executable, str(AGENT)], env=env,
                           capture_output=True, text=True, timeout=20)
        self.assertEqual(p.returncode, 3, p.stderr)


class StartupEnvValidationTest(unittest.TestCase):
    """#1510: invalid PORT/SLOTS must exit 3 naming var+value, no traceback."""

    def _run_with_env(self, extra):
        with tempfile.NamedTemporaryFile("w", suffix="-token",
                                         delete=False) as f:
            f.write("test-token\n")
            token = f.name
        try:
            env = dict(os.environ,
                       LAPTOP_AGENT_TOKEN_FILE=token,
                       LAPTOP_AGENT_HOST="127.0.0.1",
                       LAPTOP_AGENT_PORT=str(free_port()),
                       LAPTOP_AGENT_STATE=tempfile.mkdtemp())
            env.update(extra)
            return subprocess.run([sys.executable, str(AGENT)], env=env,
                                  capture_output=True, text=True, timeout=20)
        finally:
            os.unlink(token)

    def test_invalid_port_refuses_to_start(self):
        for value in ("abc", "0", "99999", "-1"):
            with self.subTest(LAPTOP_AGENT_PORT=value):
                p = self._run_with_env({"LAPTOP_AGENT_PORT": value})
                self.assertEqual(p.returncode, 3, p.stderr)
                self.assertIn("invalid LAPTOP_AGENT_PORT=", p.stderr)
                self.assertIn(repr(value), p.stderr)
                self.assertNotIn("Traceback", p.stderr)

    def test_invalid_slots_refuses_to_start(self):
        for value in ("abc", "0", "-1"):
            with self.subTest(LAPTOP_AGENT_SLOTS=value):
                p = self._run_with_env({"LAPTOP_AGENT_SLOTS": value})
                self.assertEqual(p.returncode, 3, p.stderr)
                self.assertIn("invalid LAPTOP_AGENT_SLOTS=", p.stderr)
                self.assertIn(repr(value), p.stderr)
                self.assertNotIn("Traceback", p.stderr)

    def test_invalid_header_timeout_refuses_to_start(self):
        for value in ("abc", "0", "-1"):
            with self.subTest(LAPTOP_AGENT_HEADER_TIMEOUT_S=value):
                p = self._run_with_env(
                    {"LAPTOP_AGENT_HEADER_TIMEOUT_S": value})
                self.assertEqual(p.returncode, 3, p.stderr)
                self.assertIn(
                    "invalid LAPTOP_AGENT_HEADER_TIMEOUT_S=", p.stderr)
                self.assertIn(repr(value), p.stderr)
                self.assertNotIn("Traceback", p.stderr)

    def test_invalid_body_timeout_refuses_to_start(self):
        for value in ("abc", "0", "-1"):
            with self.subTest(LAPTOP_AGENT_BODY_TIMEOUT_S=value):
                p = self._run_with_env(
                    {"LAPTOP_AGENT_BODY_TIMEOUT_S": value})
                self.assertEqual(p.returncode, 3, p.stderr)
                self.assertIn(
                    "invalid LAPTOP_AGENT_BODY_TIMEOUT_S=", p.stderr)
                self.assertIn(repr(value), p.stderr)
                self.assertNotIn("Traceback", p.stderr)


class AuthHeaderTest(unittest.TestCase):
    """A request without the header must be rejected, not treated as ""."""

    def test_missing_header_rejected(self):
        token = "s" * 32
        with tempfile.NamedTemporaryFile("w", delete=False) as f:
            f.write(token + "\n")
            token_path = f.name
        port = free_port()
        env = dict(os.environ,
                   LAPTOP_AGENT_TOKEN_FILE=token_path,
                   LAPTOP_AGENT_HOST="127.0.0.1",
                   LAPTOP_AGENT_PORT=str(port),
                   LAPTOP_AGENT_STATE=tempfile.mkdtemp())
        proc = subprocess.Popen([sys.executable, str(AGENT)], env=env,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.time() + 10
            while time.time() < deadline:
                try:
                    urllib.request.urlopen(
                        f"http://127.0.0.1:{port}/health", timeout=1)
                except urllib.error.HTTPError as e:
                    self.assertEqual(e.code, 401)
                    break
                except (urllib.error.URLError, ConnectionError):
                    time.sleep(0.1)
            else:
                self.fail("agent did not start")
            req = urllib.request.Request(
                f"http://127.0.0.1:{port}/health",
                headers={"X-Agent-Token": token})
            with urllib.request.urlopen(req, timeout=5) as r:
                self.assertEqual(r.status, 200)
                self.assertTrue(json.loads(r.read())["ok"])
        finally:
            proc.terminate()
            proc.wait(timeout=10)
            os.unlink(token_path)


class AuthNonAsciiTest(unittest.TestCase):
    """#1741: non-ASCII tokens must not crash the auth comparison.

    hmac.compare_digest on str raises TypeError for non-ASCII
    operands, which used to surface as a 400 leaking the exception
    message, and a non-ASCII token file produced a daemon that could
    never authenticate. The comparison is done on bytes: a presented
    non-ASCII token gets the uniform 401, and the correct non-ASCII
    token authenticates end to end.
    """

    def _start_agent(self, token_text):
        f = tempfile.NamedTemporaryFile("w", encoding="utf-8",
                                        delete=False)
        f.write(token_text + "\n")
        f.close()
        port = free_port()
        env = dict(os.environ,
                   LAPTOP_AGENT_TOKEN_FILE=f.name,
                   LAPTOP_AGENT_HOST="127.0.0.1",
                   LAPTOP_AGENT_PORT=str(port),
                   LAPTOP_AGENT_STATE=tempfile.mkdtemp())
        proc = subprocess.Popen([sys.executable, str(AGENT)], env=env,
                                stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE)
        self.addCleanup(os.unlink, f.name)
        self.addCleanup(proc.kill)
        deadline = time.time() + 10
        while time.time() < deadline:
            if proc.poll() is not None:
                self.fail(f"agent exited early: {proc.stderr.read()}")
            try:
                self._raw_health(port, None)
                return proc, port
            except (ConnectionError, OSError):
                time.sleep(0.1)
        self.fail("agent did not start")

    def _raw_health(self, port, token_bytes):
        with socket.create_connection(("127.0.0.1", port),
                                      timeout=5) as sock:
            lines = [b"GET /health HTTP/1.1", b"Host: 127.0.0.1",
                     b"Connection: close"]
            if token_bytes is not None:
                lines.append(b"X-Agent-Token: " + token_bytes)
            sock.sendall(b"\r\n".join(lines) + b"\r\n\r\n")
            chunks = []
            while True:
                data = sock.recv(4096)
                if not data:
                    break
                chunks.append(data)
        head, _, body = b"".join(chunks).partition(b"\r\n\r\n")
        return int(head.split(b" ")[1]), body

    def test_non_ascii_header_gets_uniform_401(self):
        _, port = self._start_agent("s" * 32)
        wrong_status, wrong_body = self._raw_health(port, b"wrong-token")
        self.assertEqual(wrong_status, 401)
        self.assertEqual(json.loads(wrong_body), {"error": "bad token"})
        for enc in ("utf-8", "latin-1"):
            status, body = self._raw_health(
                port, "caf\u00e9-token".encode(enc))
            self.assertEqual(status, 401, enc)
            self.assertEqual(json.loads(body), {"error": "bad token"}, enc)
            self.assertNotIn(b"TypeError", body)

    def test_non_ascii_token_file_authenticates(self):
        token = "t\u00f6k\u00e9n-token-0123456789"
        _, port = self._start_agent(token)
        for enc in ("utf-8", "latin-1"):
            status, body = self._raw_health(port, token.encode(enc))
            self.assertEqual(status, 200, enc)
            self.assertTrue(json.loads(body)["ok"], enc)
        status, body = self._raw_health(port, b"ascii-wrong-token")
        self.assertEqual(status, 401)
        self.assertEqual(json.loads(body), {"error": "bad token"})


class AuthFailureConnectionTest(unittest.TestCase):
    """Issue #1911: a 401 must not leave the request body on a live
    keep-alive connection.

    Oracle: on ONE http.client.HTTPConnection, a wrong-token POST with
    a body is answered 401 with `Connection: close` and the unchanged
    {"error": "bad token"} body; the follow-up right-token request on
    the same connection object is then served normally (the client
    reconnects to a clean 200) instead of being parsed as a request
    line and answered with http.server's HTML 400 Bad request syntax.
    """

    def setUp(self):
        self.token = "<MASKED_SECRET_002>"
        with tempfile.NamedTemporaryFile("w", delete=False) as f:
            f.write(self.token + "\n")
            self.token_path = f.name
        self.port = free_port()
        env = dict(os.environ,
                   LAPTOP_AGENT_TOKEN_FILE=self.token_path,
                   LAPTOP_AGENT_HOST="127.0.0.1",
                   LAPTOP_AGENT_PORT=str(self.port),
                   LAPTOP_AGENT_STATE=tempfile.mkdtemp())
        self.proc = subprocess.Popen([sys.executable, str(AGENT)], env=env,
                                     stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE)
        deadline = time.time() + 10
        while time.time() < deadline:
            try:
                conn = self._conn()
                status, _, _ = self._call(conn, "GET", "/health", self.token)
                conn.close()
                if status == 200:
                    return
            except Exception:
                time.sleep(0.1)
        self.tearDown()
        self.fail("agent did not start")

    def tearDown(self):
        self.proc.terminate()
        self.proc.wait(timeout=10)
        os.unlink(self.token_path)

    def _conn(self):
        return http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)

    def _call(self, conn, method, path, token, body=None):
        headers = {"X-Agent-Token": token,
                   "Content-Type": "application/json"}
        data = json.dumps(body).encode() if body is not None else None
        conn.request(method, path, body=data, headers=headers)
        r = conn.getresponse()
        payload = r.read()
        try:
            parsed = json.loads(payload) if payload else {}
        except ValueError:
            parsed = {}
        return r.status, r.getheader("Connection"), parsed

    def _assert_401_close_then_ok(self, path, body, ok_statuses):
        conn = self._conn()
        status, connection, parsed = self._call(
            conn, "POST", path, "WRONG-TOKEN", body)
        self.assertEqual(status, 401, parsed)
        self.assertEqual(parsed, {"error": "bad token"})
        self.assertEqual(connection, "close")
        status, _, parsed = self._call(conn, "POST", path, self.token, body)
        self.assertIn(status, ok_statuses, parsed)
        self.assertNotEqual(status, 400, parsed)
        conn.close()
        return parsed

    def test_exec_401_closes_and_reused_connection_works(self):
        parsed = self._assert_401_close_then_ok(
            "/exec", {"cmds": [{"argv": ["/bin/echo", "hi"]}]}, (200,))
        self.assertIn("results", parsed)

    def test_jobs_401_closes_and_reused_connection_works(self):
        parsed = self._assert_401_close_then_ok(
            "/jobs", {"argv": ["/bin/sh", "-c", "true"]}, (200, 202))
        self.assertIn("job_id", parsed)



class AuthedUnreadBodyConnectionTest(unittest.TestCase):
    """Issue #1916: authenticated POST paths that never parse the body
    (kill, unknown routes) must drain it before answering.

    Oracle: on ONE http.client.HTTPConnection, an authed POST with a
    JSON body to /jobs/<unknown>/kill answers 404 and to an unknown
    route answers 404, and a following GET /health on the same
    connection is served 200 -- the drained body is not parsed as the
    next request line (which used to produce http.server's HTML 400).
    """

    def setUp(self):
        self.token = "<MASKED_SECRET_003>"
        with tempfile.NamedTemporaryFile("w", delete=False) as f:
            f.write(self.token + "\n")
            self.token_path = f.name
        self.port = free_port()
        env = dict(os.environ,
                   LAPTOP_AGENT_TOKEN_FILE=self.token_path,
                   LAPTOP_AGENT_HOST="127.0.0.1",
                   LAPTOP_AGENT_PORT=str(self.port),
                   LAPTOP_AGENT_STATE=tempfile.mkdtemp())
        self.proc = subprocess.Popen([sys.executable, str(AGENT)], env=env,
                                     stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE)
        deadline = time.time() + 10
        while time.time() < deadline:
            try:
                conn = self._conn()
                status, _, _ = self._call(conn, "GET", "/health", self.token)
                conn.close()
                if status == 200:
                    return
            except Exception:
                time.sleep(0.1)
        self.tearDown()
        self.fail("agent did not start")

    def tearDown(self):
        self.proc.terminate()
        self.proc.wait(timeout=10)
        os.unlink(self.token_path)

    def _conn(self):
        return http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)

    def _call(self, conn, method, path, body=None):
        headers = {"X-Agent-Token": self.token,
                   "Content-Type": "application/json"}
        data = (body if isinstance(body, bytes) else json.dumps(body).encode()
                if body is not None else None)
        conn.request(method, path, body=data, headers=headers)
        r = conn.getresponse()
        payload = r.read()
        try:
            parsed = json.loads(payload) if payload else {}
        except ValueError:
            parsed = {}
        return r.status, r.getheader("Connection"), parsed

    def _assert_health_ok(self, conn):
        status, _, parsed = self._call(conn, "GET", "/health")
        self.assertEqual(status, 200, parsed)
        self.assertTrue(parsed.get("ok"), parsed)

    def _raw_response(self, request):
        with socket.create_connection(("127.0.0.1", self.port), timeout=2) as sock:
            sock.settimeout(2)
            sock.sendall(request)
            response = bytearray()
            while True:
                try:
                    chunk = sock.recv(4096)
                except socket.timeout:
                    self.fail("server left an ambiguous request connection open")
                if not chunk:
                    break
                response.extend(chunk)
        head, _, body = response.partition(b"\r\n\r\n")
        return head, body

    def _framing_request(self, method, path, headers, body=b""):
        wire = (f"{method} {path} HTTP/1.1\r\nHost: localhost\r\n"
                f"X-Agent-Token: {self.token}\r\n").encode()
        wire += b"".join(f"{name}: {value}\r\n".encode()
                         for name, value in headers)
        return wire + b"\r\n" + body

    def test_chunked_exec_is_rejected_and_connection_closed(self):
        chunk = b'{"cmds":[]}'
        head, body = self._raw_response(self._framing_request(
            "POST", "/exec", [("Transfer-Encoding", "chunked")],
            (f"{len(chunk):x}\r\n".encode() + chunk + b"\r\n0\r\n\r\n")))
        self.assertIn(b" 400 ", head)
        self.assertIn(b"Connection: close", head)
        self.assertIn(b"unsupported Transfer-Encoding", body)

    def test_chunked_jobs_is_rejected_and_connection_closed(self):
        chunk = b'{"argv":["/bin/true"]}'
        head, body = self._raw_response(self._framing_request(
            "POST", "/jobs", [("Transfer-Encoding", "chunked")],
            (f"{len(chunk):x}\r\n".encode() + chunk + b"\r\n0\r\n\r\n")))
        self.assertIn(b" 400 ", head)
        self.assertIn(b"Connection: close", head)
        self.assertIn(b"unsupported Transfer-Encoding", body)

    def test_duplicate_transfer_encoding_fields_are_rejected(self):
        head, body = self._raw_response(self._framing_request(
            "POST", "/exec", [("Transfer-Encoding", "identity"),
                               ("Transfer-Encoding", "chunked")]))
        self.assertIn(b" 400 ", head)
        self.assertIn(b"Connection: close", head)
        self.assertIn(b"unsupported Transfer-Encoding", body)

    def test_content_length_and_transfer_encoding_are_rejected(self):
        smuggled = b"GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n"
        head, body = self._raw_response(self._framing_request(
            "POST", "/exec", [("Content-Length", "2"),
                               ("Transfer-Encoding", "chunked")],
            b"{}" + smuggled))
        self.assertIn(b" 400 ", head)
        self.assertIn(b"Connection: close", head)
        self.assertIn(b"Content-Length and Transfer-Encoding", body)
        self.assertEqual(body.count(b"ok"), 0)

    def test_chunked_unread_post_paths_are_rejected(self):
        chunk = b"junk"
        framed = f"{len(chunk):x}\r\n".encode() + chunk + b"\r\n0\r\n\r\n"
        for path in ("/jobs/deadbeef/kill", "/no-such-route"):
            with self.subTest(path=path):
                head, body = self._raw_response(self._framing_request(
                    "POST", path, [("Transfer-Encoding", "chunked")], framed))
                self.assertIn(b" 400 ", head)
                self.assertIn(b"Connection: close", head)
                self.assertIn(b"unsupported Transfer-Encoding", body)

    def test_duplicate_content_length_exec_is_rejected(self):
        # Issue #2174: two differing Content-Length fields used to pass
        # the guard; the reader took the first value and the trailing
        # bytes were parsed as a second request on the same connection.
        smuggled = b"GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n"
        head, body = self._raw_response(self._framing_request(
            "POST", "/exec", [("Content-Length", "2"),
                              ("Content-Length", "100")],
            b"{}" + smuggled))
        self.assertIn(b" 400 ", head)
        self.assertIn(b"Connection: close", head)
        self.assertIn(b"duplicate Content-Length", body)
        self.assertEqual(body.count(b"ok"), 0)

    def test_duplicate_content_length_jobs_is_rejected(self):
        head, body = self._raw_response(self._framing_request(
            "POST", "/jobs", [("Content-Length", "2"),
                              ("Content-Length", "22")],
            b"{}"))
        self.assertIn(b" 400 ", head)
        self.assertIn(b"Connection: close", head)
        self.assertIn(b"duplicate Content-Length", body)

    def test_identical_duplicate_content_length_is_rejected(self):
        # Pinned fail-closed (#2174): identical duplicates are rejected
        # too, never silently coalesced to the first value -- no
        # intermediary normalizes requests for this daemon.
        head, body = self._raw_response(self._framing_request(
            "POST", "/exec", [("Content-Length", "2"),
                              ("Content-Length", "2")],
            b"{}"))
        self.assertIn(b" 400 ", head)
        self.assertIn(b"Connection: close", head)
        self.assertIn(b"duplicate Content-Length", body)

    def test_duplicate_content_length_unread_post_paths_are_rejected(self):
        for path in ("/jobs/deadbeef/kill", "/no-such-route"):
            with self.subTest(path=path):
                head, body = self._raw_response(self._framing_request(
                    "POST", path, [("Content-Length", "2"),
                                   ("Content-Length", "100")],
                    b"{}"))
                self.assertIn(b" 400 ", head)
                self.assertIn(b"Connection: close", head)
                self.assertIn(b"duplicate Content-Length", body)

    def test_identity_transfer_encoding_exec_is_rejected(self):
        # Issue #2170: Transfer-Encoding: identity with no
        # Content-Length declares no body length; the reader consumed
        # zero bytes and the real body was parsed as the next request.
        smuggled = b"GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n"
        head, body = self._raw_response(self._framing_request(
            "POST", "/exec", [("Transfer-Encoding", "identity")],
            b"{}" + smuggled))
        self.assertIn(b" 400 ", head)
        self.assertIn(b"Connection: close", head)
        self.assertIn(b"identity Transfer-Encoding", body)
        self.assertEqual(body.count(b"ok"), 0)

    def test_identity_transfer_encoding_jobs_is_rejected(self):
        head, body = self._raw_response(self._framing_request(
            "POST", "/jobs", [("Transfer-Encoding", "identity")],
            b"{}"))
        self.assertIn(b" 400 ", head)
        self.assertIn(b"Connection: close", head)
        self.assertIn(b"identity Transfer-Encoding", body)

    def test_identity_transfer_encoding_unread_post_paths_are_rejected(self):
        for path in ("/jobs/deadbeef/kill", "/no-such-route"):
            with self.subTest(path=path):
                head, body = self._raw_response(self._framing_request(
                    "POST", path, [("Transfer-Encoding", "identity")],
                    b"{}"))
                self.assertIn(b" 400 ", head)
                self.assertIn(b"Connection: close", head)
                self.assertIn(b"identity Transfer-Encoding", body)

    def test_kill_unknown_job_with_body_then_health_same_connection(self):
        conn = self._conn()
        status, connection, parsed = self._call(
            conn, "POST", "/jobs/deadbeef/kill",
            {"argv": ["/bin/echo", "hi"]})
        self.assertEqual(status, 404, parsed)
        self.assertEqual(parsed, {"error": "no such job"})
        self.assertNotEqual(connection, "close")
        self._assert_health_ok(conn)
        conn.close()

    def test_unknown_route_with_body_then_health_same_connection(self):
        conn = self._conn()
        status, connection, parsed = self._call(
            conn, "POST", "/no-such-route", {"argv": ["/bin/echo", "hi"]})
        self.assertEqual(status, 404, parsed)
        self.assertEqual(parsed, {"error": "no such route"})
        self.assertNotEqual(connection, "close")
        self._assert_health_ok(conn)
        conn.close()

    def test_kill_running_job_with_body_then_health_same_connection(self):
        conn = self._conn()
        status, _, parsed = self._call(
            conn, "POST", "/jobs",
            {"argv": ["/bin/sh", "-c", "sleep 30"]})
        self.assertIn(status, (200, 202), parsed)
        job_id = parsed["job_id"]
        status, connection, parsed = self._call(
            conn, "POST", f"/jobs/{job_id}/kill", {"reason": "test"})
        self.assertEqual(status, 200, parsed)
        self.assertEqual(parsed, {"ok": True, "job_id": job_id})
        self.assertNotEqual(connection, "close")
        self._assert_health_ok(conn)
        conn.close()

    def test_kill_unknown_job_without_body_still_404(self):
        conn = self._conn()
        status, _, parsed = self._call(conn, "POST", "/jobs/deadbeef/kill")
        self.assertEqual(status, 404, parsed)
        self.assertEqual(parsed, {"error": "no such job"})
        self._assert_health_ok(conn)
        conn.close()

    def test_get_health_with_body_then_health_same_connection(self):
        conn = self._conn()
        status, connection, parsed = self._call(
            conn, "GET", "/health", b"junk")
        self.assertEqual(status, 200, parsed)
        self.assertTrue(parsed["ok"])
        self.assertNotEqual(connection, "close")
        self._assert_health_ok(conn)
        conn.close()

    def test_get_unknown_route_with_body_then_health_same_connection(self):
        conn = self._conn()
        status, connection, parsed = self._call(
            conn, "GET", "/no-such-route", b"junk")
        self.assertEqual(status, 404, parsed)
        self.assertEqual(parsed, {"error": "no such route"})
        self.assertNotEqual(connection, "close")
        self._assert_health_ok(conn)
        conn.close()

    def test_get_oversized_body_returns_closing_400(self):
        conn = self._conn()
        conn.putrequest("GET", "/health")
        conn.putheader("X-Agent-Token", self.token)
        conn.putheader("Content-Length", str((1 << 20) + 1))
        conn.endheaders()
        response = conn.getresponse()
        self.assertEqual(response.status, 400)
        self.assertEqual(response.getheader("Connection"), "close")
        self.assertIn("too large", json.loads(response.read())["error"])
        conn.close()

    def test_get_truncated_body_returns_closing_400(self):
        with socket.create_connection(("127.0.0.1", self.port), timeout=5) as sock:
            sock.sendall(
                b"GET /health HTTP/1.1\r\nHost: localhost\r\n"
                + f"X-Agent-Token: {self.token}\r\n".encode()
                + b"Content-Length: 4\r\n\r\n"
            )
            sock.shutdown(socket.SHUT_WR)
            response = bytearray()
            while True:
                chunk = sock.recv(4096)
                if not chunk:
                    break
                response.extend(chunk)
        head, _, body = response.partition(b"\r\n\r\n")
        self.assertIn(b" 400 ", head)
        self.assertIn(b"Connection: close", head)
        self.assertIn(b"truncated", body)

class TailFileTest(unittest.TestCase):
    def test_job_public_samples_state_before_reading_spools(self):
        with tempfile.NamedTemporaryFile("w", suffix="-token",
                                         delete=False) as f:
            f.write("tail-test-token\n")
            token_path = f.name
        os.environ.setdefault("LAPTOP_AGENT_TOKEN_FILE", token_path)
        sys.path.insert(0, str(AGENT.parent))
        import laptop_agent as la

        with tempfile.TemporaryDirectory() as state_dir:
            with patch.object(la, "STATE_DIR", Path(state_dir)):
                job_id = "job-public-race"
                spool = la.job_dir(job_id)
                spool.mkdir(parents=True)
                (spool / "stdout").write_bytes(b"")
                (spool / "stderr").write_bytes(b"")
                job = {"id": job_id, "state": "running", "proc": None,
                       "exit": None, "cwd": "/", "cmd_repr": "test",
                       "started_at": time.time(), "ended_at": None,
                       "interrupted": False}

                def finish_job(current):
                    (spool / "stdout").write_bytes(b"final output")
                    current["state"] = "done"
                    current["exit"] = 0
                    current["ended_at"] = time.time()
                    return "done"

                with patch.object(la, "job_state", side_effect=finish_job) as state:
                    result = la.job_public(job)

        state.assert_called_once_with(job)
        self.assertEqual(result["state"], "done")
        self.assertEqual(result["stdout"], "final output")

    def test_tail_caps_and_flags(self):
        with tempfile.NamedTemporaryFile("w", delete=False) as t:
            t.write("tail-test-token\n")
            token_path = t.name
        os.environ.setdefault("LAPTOP_AGENT_TOKEN_FILE", token_path)
        sys.path.insert(0, str(AGENT.parent))
        import laptop_agent as la
        with tempfile.NamedTemporaryFile(delete=False) as f:
            f.write(b"x" * 100 + b"END")
            path = Path(f.name)
        try:
            data, cut = la.tail_file(path, 10)
            self.assertEqual(data, b"xxxxxxxEND")
            self.assertTrue(cut)
            data, cut = la.tail_file(path, 1000)
            self.assertEqual(len(data), 103)
            self.assertFalse(cut)
        finally:
            os.unlink(path)



class JobsListShapeTest(unittest.TestCase):
    """Issue #1503: GET /jobs is a summary; output lives on /jobs/<id>.

    Oracle: the module docstring's documented shapes -- the list route
    documents {job_id, state, exit, ...} with no output fields, while
    the single-job route documents stdout/stderr plus paging cursors.
    """

    def _import_agent(self):
        with tempfile.NamedTemporaryFile("w", suffix="-token",
                                         delete=False) as f:
            f.write("jobs-list-test-token\n")
            token_path = f.name
        os.environ.setdefault("LAPTOP_AGENT_TOKEN_FILE", token_path)
        sys.path.insert(0, str(AGENT.parent))
        import laptop_agent as la
        return la

    def test_summary_has_no_output_but_single_job_shape_does(self):
        la = self._import_agent()
        with tempfile.TemporaryDirectory() as state_dir:
            with patch.object(la, "STATE_DIR", Path(state_dir)):
                job_id = "job-list-shape"
                spool = la.job_dir(job_id)
                spool.mkdir(parents=True)
                (spool / "stdout").write_bytes(b"known stdout payload")
                (spool / "stderr").write_bytes(b"known stderr payload")
                job = {"id": job_id, "state": "done", "proc": None,
                       "exit": 0, "cwd": "/", "cmd_repr": "test",
                       "started_at": time.time(), "ended_at": time.time(),
                       "interrupted": False}
                summary = la.job_summary(job)
                full = la.job_public(job)
        for key in ("job_id", "state", "exit", "cwd", "cmd",
                    "started_at", "duration_ms", "interrupted",
                    "out_next", "err_next"):
            self.assertIn(key, summary)
        self.assertNotIn("stdout", summary)
        self.assertNotIn("stderr", summary)
        self.assertNotIn("known stdout payload", json.dumps(summary))
        self.assertNotIn("known stderr payload", json.dumps(summary))
        self.assertEqual(summary["out_next"], len(b"known stdout payload"))
        self.assertEqual(summary["err_next"], len(b"known stderr payload"))
        self.assertEqual(full["stdout"], "known stdout payload")
        self.assertEqual(full["stderr"], "known stderr payload")

    def test_list_route_returns_summary_single_route_returns_output(self):
        token = "jobs-list-http-token"
        with tempfile.NamedTemporaryFile("w", delete=False) as f:
            f.write(token + "\n")
            token_path = f.name
        port = free_port()
        env = dict(os.environ,
                   LAPTOP_AGENT_TOKEN_FILE=token_path,
                   LAPTOP_AGENT_HOST="127.0.0.1",
                   LAPTOP_AGENT_PORT=str(port),
                   LAPTOP_AGENT_STATE=tempfile.mkdtemp())
        proc = subprocess.Popen([sys.executable, str(AGENT)], env=env,
                                stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE)
        headers = {"X-Agent-Token": token,
                   "Content-Type": "application/json"}

        def call(method, path, body=None):
            data = json.dumps(body).encode() if body is not None else None
            req = urllib.request.Request(
                f"http://127.0.0.1:{port}{path}", data=data,
                headers=headers, method=method)
            with urllib.request.urlopen(req, timeout=5) as r:
                return json.loads(r.read())

        try:
            deadline = time.time() + 10
            while True:
                try:
                    if call("GET", "/health")["ok"]:
                        break
                except Exception:
                    if time.time() > deadline:
                        raise
                    time.sleep(0.1)
            job_id = call("POST", "/jobs", {
                "cwd": "/",
                "argv": [sys.executable, "-c",
                         "import sys; sys.stdout.write('k' * 64); "
                         "sys.stderr.write('e' * 64)"]})["job_id"]
            deadline = time.time() + 10
            single = None
            while time.time() < deadline:
                single = call("GET", f"/jobs/{job_id}")
                if single["state"] == "done":
                    break
                time.sleep(0.1)
            self.assertEqual(single["state"], "done")
            self.assertEqual(single["stdout"], "k" * 64)
            self.assertEqual(single["stderr"], "e" * 64)
            listing = call("GET", "/jobs")
            entry = [j for j in listing["jobs"] if j["job_id"] == job_id]
            self.assertEqual(len(entry), 1)
            self.assertNotIn("stdout", entry[0])
            self.assertNotIn("stderr", entry[0])
            self.assertNotIn("k" * 64, json.dumps(entry[0]))
            self.assertNotIn("e" * 64, json.dumps(entry[0]))
            self.assertEqual(entry[0]["out_next"], 64)
            self.assertEqual(entry[0]["err_next"], 64)
        finally:
            proc.terminate()
            proc.wait(timeout=10)
            os.unlink(token_path)



class JobSlotsTest(unittest.TestCase):
    """Issue #1545: POST /jobs shares the LAPTOP_AGENT_SLOTS pool.

    Oracle: with SLOTS=1 and one long-running job held, a second
    POST /jobs gets 503 busy (after the bounded 5s wait, like /exec)
    instead of running concurrently, /exec is likewise busy (shared
    pool), and once the held job ends its slot is released so a new
    job is accepted again.
    """

    def test_second_job_rejected_while_slot_held_then_accepted(self):
        token = "jobs-slots-test-token"
        with tempfile.NamedTemporaryFile("w", delete=False) as f:
            f.write(token + "\n")
            token_path = f.name
        port = free_port()
        env = dict(os.environ,
                   LAPTOP_AGENT_TOKEN_FILE=token_path,
                   LAPTOP_AGENT_HOST="127.0.0.1",
                   LAPTOP_AGENT_PORT=str(port),
                   LAPTOP_AGENT_SLOTS="1",
                   LAPTOP_AGENT_STATE=tempfile.mkdtemp())
        proc = subprocess.Popen([sys.executable, str(AGENT)], env=env,
                                stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE)
        headers = {"X-Agent-Token": token,
                   "Content-Type": "application/json"}

        def call(method, path, body=None):
            data = json.dumps(body).encode() if body is not None else None
            req = urllib.request.Request(
                f"http://127.0.0.1:{port}{path}", data=data,
                headers=headers, method=method)
            try:
                with urllib.request.urlopen(req, timeout=20) as r:
                    return r.status, json.loads(r.read())
            except urllib.error.HTTPError as e:
                return e.code, json.loads(e.read())

        try:
            deadline = time.time() + 10
            while True:
                try:
                    status, body = call("GET", "/health")
                    if status == 200 and body["ok"]:
                        break
                except Exception:
                    if time.time() > deadline:
                        raise
                    time.sleep(0.1)
            status, body = call("POST", "/jobs", {
                "cwd": "/",
                "argv": [sys.executable, "-c",
                         "import time; time.sleep(30)"]})
            self.assertEqual(status, 200, body)
            job_id = body["job_id"]
            # The single slot is held for the job's lifetime: a second
            # job must not run concurrently.
            status, body = call("POST", "/jobs", {
                "cwd": "/", "argv": [sys.executable, "-c", "pass"]})
            self.assertEqual(status, 503, body)
            self.assertEqual(body.get("error"), "busy")
            listing_status, listing = call("GET", "/jobs")
            self.assertEqual(listing_status, 200, listing)
            running = [j for j in listing["jobs"]
                       if j["state"] == "running"]
            self.assertEqual([j["job_id"] for j in running], [job_id])
            # Shared pool: /exec is busy too while the job holds the slot.
            status, body = call("POST", "/exec", {
                "cmds": [{"argv": [sys.executable, "-c", "pass"]}]})
            self.assertEqual(status, 503, body)
            # Killing the held job releases the slot for new work.
            status, body = call("POST", f"/jobs/{job_id}/kill")
            self.assertEqual(status, 200, body)
            deadline = time.time() + 15
            while time.time() < deadline:
                status, body = call("POST", "/jobs", {
                    "cwd": "/", "argv": [sys.executable, "-c", "pass"]})
                if status == 200:
                    break
                time.sleep(0.2)
            self.assertEqual(status, 200, body)
        finally:
            proc.terminate()
            proc.wait(timeout=10)
            os.unlink(token_path)

    def test_spool_creation_failure_returns_400_and_releases_slot(self):
        token = "jobs-spool-failure-test-token"
        with tempfile.NamedTemporaryFile("w", delete=False) as f:
            f.write(token + "\n")
            token_path = f.name
        state_dir = tempfile.mkdtemp()
        port = free_port()
        env = dict(os.environ,
                   LAPTOP_AGENT_TOKEN_FILE=token_path,
                   LAPTOP_AGENT_HOST="127.0.0.1",
                   LAPTOP_AGENT_PORT=str(port),
                   LAPTOP_AGENT_SLOTS="1",
                   LAPTOP_AGENT_STATE=state_dir)
        proc = subprocess.Popen([sys.executable, str(AGENT)], env=env,
                                stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE)
        headers = {"X-Agent-Token": token,
                   "Content-Type": "application/json"}

        def call(method, path, body=None):
            data = json.dumps(body).encode() if body is not None else None
            req = urllib.request.Request(
                f"http://127.0.0.1:{port}{path}", data=data,
                headers=headers, method=method)
            try:
                with urllib.request.urlopen(req, timeout=20) as r:
                    return r.status, json.loads(r.read())
            except urllib.error.HTTPError as e:
                with e:
                    return e.code, json.loads(e.read())

        try:
            deadline = time.time() + 10
            while True:
                try:
                    status, body = call("GET", "/health")
                    if status == 200 and body["ok"]:
                        break
                except Exception:
                    if time.time() > deadline:
                        raise
                    time.sleep(0.1)

            # Replace the initialized spool parent after startup.  mkdir for
            # the job's directory now fails with ENOTDIR, after slot acquire.
            jobs_dir = Path(state_dir) / "jobs"
            jobs_dir.rmdir()
            jobs_dir.write_text("not a directory")
            status, body = call("POST", "/jobs", {
                "cwd": "/", "argv": [sys.executable, "-c", "pass"]})
            self.assertEqual(status, 400, body)
            self.assertIn("error", body)

            jobs_dir.unlink()
            jobs_dir.mkdir()
            status, body = call("POST", "/jobs", {
                "cwd": "/", "argv": [sys.executable, "-c", "pass"]})
            self.assertEqual(status, 200, body)
            job_id = body["job_id"]
            deadline = time.time() + 10
            while time.time() < deadline:
                status, job = call("GET", f"/jobs/{job_id}")
                if status == 200 and job.get("state") == "done":
                    break
                time.sleep(0.05)
            self.assertEqual(status, 200, job)
            self.assertEqual(job.get("state"), "done", job)

            status, body = call("POST", "/exec", {
                "cmds": [{"argv": [sys.executable, "-c", "pass"]}]})
            self.assertEqual(status, 200, body)
        finally:
            proc.terminate()
            proc.wait(timeout=10)
            proc.stdout.close()
            proc.stderr.close()
            os.unlink(token_path)
            shutil.rmtree(state_dir, ignore_errors=True)



class ExecSpoolFailureTest(unittest.TestCase):
    """Issue #1923: POST /exec spool-dir creation OSError escapes run_one.

    Oracle: when tempfile.mkdtemp under STATE_DIR/exec raises OSError,
    run_one returns the same per-command error entry shape as a Popen
    failure ({"exit": None, "error": ...}), so POST /exec answers 200
    JSON instead of dropping the connection, and results of commands
    that already ran in the same batch are preserved.
    """

    def test_run_one_spool_oserror_returns_error_entry(self):
        with tempfile.NamedTemporaryFile("w", delete=False) as t:
            t.write("exec-spool-test-token\n")
            token_path = t.name
        os.environ.setdefault("LAPTOP_AGENT_TOKEN_FILE", token_path)
        sys.path.insert(0, str(AGENT.parent))
        import laptop_agent as la
        with tempfile.TemporaryDirectory() as td:
            good = Path(td) / "good"
            (good / "exec").mkdir(parents=True)
            blocker = Path(td) / "blocker"
            blocker.write_text("not a directory")
            spec = {"argv": [sys.executable, "-c", "print(12345)"]}
            with patch.object(la, "STATE_DIR", good):
                ok = la.run_one(spec, 10)
            self.assertEqual(ok["exit"], 0, ok)
            self.assertIn("12345", ok["stdout"])
            # STATE_DIR is now a regular file: mkdtemp(dir=STATE_DIR/exec)
            # raises NotADirectoryError, an OSError subclass.
            with patch.object(la, "STATE_DIR", blocker):
                # Batch shape of _do_POST: first cmd ran under good state,
                # second hits the spool failure; both entries survive.
                results = [ok, la.run_one(spec, 10)]
            self.assertEqual(len(results), 2)
            self.assertEqual(results[0]["exit"], 0)
            self.assertIsNone(results[1]["exit"])
            self.assertIn("error", results[1])
            self.assertIn("NotADirectoryError", results[1]["error"])
            self.assertEqual(results[1]["stdout"], "")

    def test_exec_spool_failure_returns_200_json_not_dropped(self):
        token = "exec-spool-failure-test-token"
        with tempfile.NamedTemporaryFile("w", delete=False) as f:
            f.write(token + "\n")
            token_path = f.name
        state_dir = tempfile.mkdtemp()
        port = free_port()
        env = dict(os.environ,
                   LAPTOP_AGENT_TOKEN_FILE=token_path,
                   LAPTOP_AGENT_HOST="127.0.0.1",
                   LAPTOP_AGENT_PORT=str(port),
                   LAPTOP_AGENT_STATE=state_dir)
        proc = subprocess.Popen([sys.executable, str(AGENT)], env=env,
                                stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE)
        headers = {"X-Agent-Token": token,
                   "Content-Type": "application/json"}

        def call(method, path, body=None):
            data = json.dumps(body).encode() if body is not None else None
            req = urllib.request.Request(
                f"http://127.0.0.1:{port}{path}", data=data,
                headers=headers, method=method)
            try:
                with urllib.request.urlopen(req, timeout=20) as r:
                    return r.status, json.loads(r.read())
            except urllib.error.HTTPError as e:
                with e:
                    return e.code, json.loads(e.read())

        try:
            deadline = time.time() + 10
            while True:
                try:
                    status, body = call("GET", "/health")
                    if status == 200 and body["ok"]:
                        break
                except Exception:
                    if time.time() > deadline:
                        raise
                    time.sleep(0.1)

            # Replace the initialized exec spool parent after startup:
            # mkdtemp now fails with ENOTDIR for every command.
            exec_dir = Path(state_dir) / "exec"
            exec_dir.rmdir()
            exec_dir.write_text("not a directory")
            status, body = call("POST", "/exec", {
                "cmds": [{"argv": [sys.executable, "-c", "pass"]},
                         {"argv": [sys.executable, "-c", "pass"]}]})
            # Before the fix this POST got an empty reply (dropped
            # connection); urlopen would raise instead of returning.
            self.assertEqual(status, 200, body)
            self.assertEqual(len(body["results"]), 2)
            for entry in body["results"]:
                self.assertIsNone(entry["exit"], entry)
                self.assertIn("error", entry)

            # Daemon still healthy, and /exec recovers once the spool
            # parent is a directory again.
            status, body = call("GET", "/health")
            self.assertEqual(status, 200, body)
            exec_dir.unlink()
            exec_dir.mkdir()
            status, body = call("POST", "/exec", {
                "cmds": [{"argv": [sys.executable, "-c", "pass"]}]})
            self.assertEqual(status, 200, body)
            self.assertEqual(body["results"][0]["exit"], 0, body)
        finally:
            proc.terminate()
            proc.wait(timeout=10)
            proc.stdout.close()
            proc.stderr.close()
            os.unlink(token_path)
            shutil.rmtree(state_dir, ignore_errors=True)


class MalformedRequestTest(unittest.TestCase):
    """Issue #1502: malformed input returns 400 JSON, never a drop.

    Oracle: for every malformed shape, the response is a well-formed
    JSON body carrying an "error" key with status 400, AND a
    subsequent authed GET /health on the same daemon returns 200 --
    the invariant is that arbitrary body/query bytes can never kill
    the handler or wedge the connection.
    """

    def setUp(self):
        self.token = "<MASKED_SECRET_001>"
        with tempfile.NamedTemporaryFile("w", delete=False) as f:
            f.write(self.token + "\n")
            self.token_path = f.name
        self.port = free_port()
        env = dict(os.environ,
                   LAPTOP_AGENT_TOKEN_FILE=self.token_path,
                   LAPTOP_AGENT_HOST="127.0.0.1",
                   LAPTOP_AGENT_PORT=str(self.port),
                   LAPTOP_AGENT_STATE=tempfile.mkdtemp())
        self.proc = subprocess.Popen([sys.executable, str(AGENT)], env=env,
                                     stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE)
        deadline = time.time() + 10
        while time.time() < deadline:
            try:
                status, body = self._call("GET", "/health")
                if status == 200 and body.get("ok"):
                    return
            except Exception:
                time.sleep(0.1)
        self.tearDown()
        self.fail("agent did not start")

    def tearDown(self):
        self.proc.terminate()
        self.proc.wait(timeout=10)
        os.unlink(self.token_path)

    def _conn(self):
        return http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)

    def _call(self, method, path, body=None, raw=None, conn=None):
        c = conn or self._conn()
        headers = {"X-Agent-Token": self.token,
                   "Content-Type": "application/json"}
        data = raw if raw is not None else (
            json.dumps(body).encode() if body is not None else None)
        c.request(method, path, body=data, headers=headers)
        r = c.getresponse()
        payload = r.read()
        if conn is None:
            c.close()
        try:
            parsed = json.loads(payload) if payload else {}
        except ValueError:
            parsed = {}
        return r.status, parsed

    def _assert_400_then_health(self, method, path, **kw):
        status, body = self._call(method, path, **kw)
        self.assertEqual(status, 400, body)
        self.assertIn("error", body)
        status, body = self._call("GET", "/health")
        self.assertEqual(status, 200)
        self.assertTrue(body["ok"])

    def test_invalid_json_body(self):
        self._assert_400_then_health("POST", "/exec", raw=b"{not json")

    def test_non_object_json_body(self):
        self._assert_400_then_health("POST", "/exec", raw=b"[1, 2]")

    def test_bad_content_length_header(self):
        conn = self._conn()
        conn.putrequest("POST", "/exec")
        conn.putheader("X-Agent-Token", self.token)
        conn.putheader("Content-Type", "application/json")
        conn.putheader("Content-Length", "abc")
        conn.endheaders()
        r = conn.getresponse()
        body = json.loads(r.read())
        self.assertEqual(r.status, 400, body)
        self.assertIn("error", body)
        status, body = self._call("GET", "/health")
        self.assertEqual(status, 200)
        self.assertTrue(body["ok"])

    def test_bad_content_length_with_body_closes_connection(self):
        # Codex P2 on PR #1508: unread body bytes after a framing 400
        # would otherwise be parsed as the next request. Oracle: the
        # 400 carries Connection: close, and a fresh connection's
        # authed /health still returns 200.
        conn = self._conn()
        conn.putrequest("POST", "/exec")
        conn.putheader("X-Agent-Token", self.token)
        conn.putheader("Content-Type", "application/json")
        conn.putheader("Content-Length", "abc")
        conn.endheaders(b"{}")
        r = conn.getresponse()
        body = json.loads(r.read())
        self.assertEqual(r.status, 400, body)
        self.assertIn("error", body)
        self.assertEqual(r.getheader("Connection"), "close")
        conn.close()
        status, body = self._call("GET", "/health")
        self.assertEqual(status, 200)
        self.assertTrue(body["ok"])

    def test_oversized_content_length_rejected_before_reading_body(self):
        conn = self._conn()
        conn.putrequest("POST", "/exec")
        conn.putheader("X-Agent-Token", self.token)
        conn.putheader("Content-Type", "application/json")
        conn.putheader("Content-Length", str((1 << 20) + 1))
        # A partial body must not make the handler wait for the declared size.
        conn.endheaders(b"{}")
        r = conn.getresponse()
        body = json.loads(r.read())
        self.assertEqual(r.status, 400, body)
        self.assertEqual(body["error"], "request body too large")
        self.assertEqual(r.getheader("Connection"), "close")
        conn.close()
        status, body = self._call("GET", "/health")
        self.assertEqual(status, 200)
        self.assertTrue(body["ok"])

    def test_content_length_at_max_body_is_accepted(self):
        body = {"cmds": [{"cwd": os.getcwd(),
                          "argv": [sys.executable, "-c", "pass"]}]}
        raw = json.dumps(body).encode()
        raw += b" " * ((1 << 20) - len(raw))
        status, result = self._call("POST", "/exec", raw=raw)
        self.assertEqual(status, 200, result)
        self.assertEqual(result["results"][0]["exit"], 0)

    def test_exec_timeout_not_an_integer(self):
        self._assert_400_then_health(
            "POST", "/exec",
            body={"cmds": [{"argv": [sys.executable, "-c", "pass"]}],
                  "timeout_s": "abc"})

    def test_exec_non_finite_timeout_is_rejected(self):
        conn = self._conn()
        try:
            for timeout in (float("nan"), float("inf"), float("-inf")):
                with self.subTest(timeout=timeout):
                    status, body = self._call(
                        "POST", "/exec",
                        body={"cmds": [{"argv": [sys.executable, "-c",
                                                  "pass"]}],
                              "timeout_s": timeout},
                        conn=conn)
                    self.assertEqual(status, 400, body)
                    self.assertEqual(
                        body.get("error"), "timeout_s must be an integer")
                    status, body = self._call(
                        "GET", "/health", conn=conn)
                    self.assertEqual(status, 200, body)
                    self.assertTrue(body["ok"])
        finally:
            conn.close()

    def test_exec_negative_timeout_is_clamped(self):
        status, body = self._call(
            "POST", "/exec",
            body={"cmds": [{"cwd": os.getcwd(),
                             "argv": [sys.executable, "-c", "pass"]}],
                  "timeout_s": -5})
        self.assertEqual(status, 200, body)
        self.assertEqual(body["results"][0]["exit"], 0)
        self.assertNotIn("timeout", body["results"][0])

    def test_exec_cmd_without_argv_or_shell(self):
        self._assert_400_then_health(
            "POST", "/exec", body={"cmds": [{"cwd": "/"}]})

    def test_jobs_without_argv_or_shell(self):
        self._assert_400_then_health("POST", "/jobs", body={})

    def test_jobs_argv_not_a_list(self):
        self._assert_400_then_health(
            "POST", "/jobs", body={"argv": "echo hi"})

    def test_job_query_offsets_malformed(self):
        status, body = self._call(
            "POST", "/jobs",
            body={"cwd": os.getcwd(),
                  "argv": [sys.executable, "-c", "pass"]})
        self.assertEqual(status, 200, body)
        job_id = body["job_id"]
        self._assert_400_then_health(
            "GET", f"/jobs/{job_id}?out_off=abc")
        self._assert_400_then_health(
            "GET", f"/jobs/{job_id}?err_off=-1")


class StalledHeaderTest(unittest.TestCase):
    """Issue #2067: a client that sends a partial request line or
    partial headers and then goes silent must not pin a handler thread.

    Oracle: with LAPTOP_AGENT_HEADER_TIMEOUT_S=1, a raw socket that
    sends an incomplete request line (and one that sends a complete
    request line but unterminated headers) is closed by the server
    well within the client-side 10s wait; afterwards an authenticated
    GET /health on a fresh connection still returns 200 -- the stall
    released its thread and the daemon itself is unaffected.
    """

    def setUp(self):
        self.token = "<MASKED_SECRET_003>"
        with tempfile.NamedTemporaryFile("w", delete=False) as f:
            f.write(self.token + "\n")
            self.token_path = f.name
        self.port = free_port()
        env = dict(os.environ,
                   LAPTOP_AGENT_TOKEN_FILE=self.token_path,
                   LAPTOP_AGENT_HOST="127.0.0.1",
                   LAPTOP_AGENT_PORT=str(self.port),
                   LAPTOP_AGENT_STATE=tempfile.mkdtemp(),
                   LAPTOP_AGENT_HEADER_TIMEOUT_S="1")
        self.proc = subprocess.Popen([sys.executable, str(AGENT)], env=env,
                                     stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE)
        deadline = time.time() + 10
        while time.time() < deadline:
            try:
                status, body = self._call("GET", "/health")
                if status == 200 and body.get("ok"):
                    return
            except Exception:
                time.sleep(0.1)
        self.tearDown()
        self.fail("agent did not start")

    def tearDown(self):
        self.proc.terminate()
        self.proc.wait(timeout=10)
        os.unlink(self.token_path)

    def _call(self, method, path):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        conn.request(method, path,
                     headers={"X-Agent-Token": self.token})
        r = conn.getresponse()
        payload = r.read()
        conn.close()
        try:
            parsed = json.loads(payload) if payload else {}
        except ValueError:
            parsed = {}
        return r.status, parsed

    def _assert_stalled_client_closed(self, payload):
        with socket.create_connection(("127.0.0.1", self.port),
                                      timeout=10) as s:
            s.sendall(payload)
            s.settimeout(10)
            started = time.monotonic()
            try:
                data = s.recv(4096)
            except (ConnectionResetError, BrokenPipeError):
                data = b""
            elapsed = time.monotonic() - started
        # Closed by the server with no response; had the server kept
        # the connection open, recv would have raised socket.timeout
        # at the 10s client deadline instead of returning.
        self.assertEqual(data, b"")
        self.assertLess(elapsed, 10)

    def test_partial_request_line_is_closed(self):
        self._assert_stalled_client_closed(b"GET /hea")

    def test_partial_headers_are_closed(self):
        self._assert_stalled_client_closed(
            b"GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Agent-Token:")

    def test_health_still_works_after_stalled_clients(self):
        self._assert_stalled_client_closed(b"GET /hea")
        self._assert_stalled_client_closed(
            b"GET /health HTTP/1.1\r\nHost:")
        status, body = self._call("GET", "/health")
        self.assertEqual(status, 200)
        self.assertTrue(body["ok"])


class StalledBodyTest(unittest.TestCase):
    """Issue #2291: a client that sends complete headers fast and
    then trickles the body must not pin a handler thread -- the
    #2067 header deadline stops at the headers.

    Oracle: with LAPTOP_AGENT_BODY_TIMEOUT_S=1, a raw socket that
    sends full authenticated headers (Content-Length: 100) plus a
    single body byte gets a 400 naming the timed-out body read,
    with the connection closed by the server well within the
    client-side 10s wait -- on both the parsed-body path
    (POST /exec) and the drain path (GET /health). Afterwards a
    complete fast POST /exec still returns 200: the stall released
    its thread and complete bodies are unaffected.
    """

    def setUp(self):
        self.token = "<MASKED_SECRET_004>"
        with tempfile.NamedTemporaryFile("w", delete=False) as f:
            f.write(self.token + "\n")
            self.token_path = f.name
        self.port = free_port()
        env = dict(os.environ,
                   LAPTOP_AGENT_TOKEN_FILE=self.token_path,
                   LAPTOP_AGENT_HOST="127.0.0.1",
                   LAPTOP_AGENT_PORT=str(self.port),
                   LAPTOP_AGENT_STATE=tempfile.mkdtemp(),
                   LAPTOP_AGENT_BODY_TIMEOUT_S="1")
        self.proc = subprocess.Popen([sys.executable, str(AGENT)], env=env,
                                     stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE)
        deadline = time.time() + 10
        while time.time() < deadline:
            try:
                status, body = self._call("GET", "/health")
                if status == 200 and body.get("ok"):
                    return
            except Exception:
                time.sleep(0.1)
        self.tearDown()
        self.fail("agent did not start")

    def tearDown(self):
        self.proc.terminate()
        self.proc.wait(timeout=10)
        os.unlink(self.token_path)

    def _call(self, method, path, payload=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        body = json.dumps(payload) if payload is not None else None
        conn.request(method, path, body=body,
                     headers={"X-Agent-Token": self.token})
        r = conn.getresponse()
        data = r.read()
        conn.close()
        try:
            parsed = json.loads(data) if data else {}
        except ValueError:
            parsed = {}
        return r.status, parsed

    def _assert_stalled_body_400(self, head):
        with socket.create_connection(("127.0.0.1", self.port),
                                      timeout=10) as s:
            s.sendall(head)
            s.sendall(b"{")
            s.settimeout(10)
            started = time.monotonic()
            data = b""
            try:
                while True:
                    chunk = s.recv(4096)
                    if not chunk:
                        break
                    data += chunk
            except (ConnectionResetError, BrokenPipeError):
                pass
            elapsed = time.monotonic() - started
        # Answered 400 and closed by the server; had the server kept
        # the connection open, recv would have raised socket.timeout
        # at the 10s client deadline instead of returning b"".
        self.assertLess(elapsed, 10)
        self.assertTrue(data.startswith(b"HTTP/1.1 400"), data)
        self.assertIn(b"request body read timed out", data)

    def test_stalled_exec_body_gets_400_and_close(self):
        head = (b"POST /exec HTTP/1.1\r\nHost: 127.0.0.1\r\n"
                b"X-Agent-Token: " + self.token.encode() + b"\r\n"
                b"Content-Type: application/json\r\n"
                b"Content-Length: 100\r\n\r\n")
        self._assert_stalled_body_400(head)

    def test_stalled_drained_body_gets_400_and_close(self):
        head = (b"GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\n"
                b"X-Agent-Token: " + self.token.encode() + b"\r\n"
                b"Content-Length: 100\r\n\r\n")
        self._assert_stalled_body_400(head)

    def test_fast_bodies_unaffected_after_stalled_clients(self):
        head = (b"POST /exec HTTP/1.1\r\nHost: 127.0.0.1\r\n"
                b"X-Agent-Token: " + self.token.encode() + b"\r\n"
                b"Content-Type: application/json\r\n"
                b"Content-Length: 100\r\n\r\n")
        self._assert_stalled_body_400(head)
        status, body = self._call(
            "POST", "/exec",
            {"cmds": [{"argv": [sys.executable, "-c", "pass"]}]})
        self.assertEqual(status, 200, body)
        status, body = self._call("GET", "/health")
        self.assertEqual(status, 200)
        self.assertTrue(body["ok"])


class PersistedJobTimestampTest(unittest.TestCase):
    """Issue #1513: non-numeric persisted timestamps must not crash
    startup or poison /jobs reads.

    Oracle: a spool dir whose meta.json timestamps are malformed
    (string incl. numeric string, bool, list, object) is skipped
    whole -- exactly one stderr line naming its dir, nothing added
    to JOBS, spool left on disk -- while missing/None keep today's
    defaults and well-formed jobs restore exactly as before,
    including the running->interrupted conversion.
    """

    def _import_agent(self):
        with tempfile.NamedTemporaryFile("w", suffix="-token",
                                         delete=False) as f:
            f.write("persisted-ts-test-token\n")
            token_path = f.name
        os.environ.setdefault("LAPTOP_AGENT_TOKEN_FILE", token_path)
        sys.path.insert(0, str(AGENT.parent))
        import laptop_agent as la
        return la

    def _write_job(self, state_dir, job_id, **meta):
        spool = Path(state_dir) / "jobs" / job_id
        spool.mkdir(parents=True)
        meta.setdefault("id", job_id)
        meta.setdefault("cwd", "/")
        meta.setdefault("cmd", "test")
        meta.setdefault("exit", 0)
        meta.setdefault("state", "done")
        (spool / "meta.json").write_text(json.dumps(meta))
        (spool / "stdout").write_bytes(b"")
        (spool / "stderr").write_bytes(b"")
        return spool

    def _load(self, la, state_dir):
        la.JOBS.clear()
        err = io.StringIO()
        with patch.object(la, "STATE_DIR", Path(state_dir)):
            with contextlib.redirect_stderr(err):
                la.load_persisted_jobs()
        return err.getvalue()

    def tearDown(self):
        la_mod = sys.modules.get("laptop_agent")
        if la_mod is not None:
            la_mod.JOBS.clear()

    def test_spool_root_scan_failure_restores_none_and_names_dir(self):
        la = self._import_agent()
        with tempfile.TemporaryDirectory() as state_dir:
            with patch.object(la, "_jobs_root",
                              side_effect=ValueError("escapes state")):
                stderr = self._load(la, state_dir)
            self.assertEqual(la.JOBS, {})
            lines = [ln for ln in stderr.splitlines() if ln.strip()]
            self.assertEqual(len(lines), 1, stderr)
            self.assertIn(str(Path(state_dir) / "jobs"), lines[0])
            self.assertIn("escapes state", lines[0])

    def test_started_at_string_skipped_healthy_kept_stderr_names_dir(self):
        la = self._import_agent()
        with tempfile.TemporaryDirectory() as state_dir:
            bad = self._write_job(state_dir, "bad-started",
                                  started_at="not-a-number",
                                  ended_at=200.0)
            self._write_job(state_dir, "healthy",
                            started_at=100.0, ended_at=150.0)
            stderr = self._load(la, state_dir)
            self.assertNotIn("bad-started", la.JOBS)
            self.assertIn("healthy", la.JOBS)
            self.assertTrue(bad.exists())
            lines = [ln for ln in stderr.splitlines() if ln.strip()]
            self.assertEqual(len(lines), 1, stderr)
            self.assertIn(str(bad), lines[0])
            self.assertIn("started_at", lines[0])

    def test_ended_at_string_skipped_summary_and_reaper_succeed(self):
        la = self._import_agent()
        with tempfile.TemporaryDirectory() as state_dir:
            bad = self._write_job(state_dir, "bad-ended",
                                  started_at=100.0, ended_at="never")
            self._write_job(state_dir, "healthy",
                            started_at=100.0, ended_at=150.0)
            stderr = self._load(la, state_dir)
            self.assertNotIn("bad-ended", la.JOBS)
            self.assertIn("healthy", la.JOBS)
            self.assertTrue(bad.exists())
            lines = [ln for ln in stderr.splitlines() if ln.strip()]
            self.assertEqual(len(lines), 1, stderr)
            self.assertIn(str(bad), lines[0])
            with patch.object(la, "STATE_DIR", Path(state_dir)):
                summaries = [la.job_summary(j)
                             for j in list(la.JOBS.values())]
                la.reap_old_jobs()
            self.assertEqual([s["job_id"] for s in summaries],
                             ["healthy"])

    def test_done_null_ended_at_stamped_and_reapable(self):
        # Issue #1532: a restored done job with ended_at=null kept the
        # null, so the reaper read it as "now" (spool retained forever)
        # and duration_ms grew with wall-clock time. Oracle: at load it
        # gets a finite stamp, duration is stable across reads, and
        # the reaper removes it (index + spool) once past TTL.
        la = self._import_agent()
        with tempfile.TemporaryDirectory() as state_dir:
            now = time.time()
            spool = self._write_job(state_dir, "done-null-ended",
                                    started_at=now - 48 * 3600,
                                    ended_at=None)
            stderr = self._load(la, state_dir)
            self.assertEqual(stderr, "")
            job = la.JOBS["done-null-ended"]
            self.assertIsInstance(job["ended_at"], float)
            with patch.object(la, "STATE_DIR", Path(state_dir)):
                first = la.job_summary(job)["duration_ms"]
                second = la.job_summary(job)["duration_ms"]
                self.assertEqual(first, second)
                with patch.object(la, "JOB_TTL_S", -1):
                    la.reap_old_jobs()
            self.assertNotIn("done-null-ended", la.JOBS)
            self.assertFalse(spool.exists())
    def test_non_object_meta_skipped_healthy_kept(self):
        # Issue #1522: meta.json that is valid JSON but not an object
        # gets the same skip contract as malformed timestamps.
        la = self._import_agent()
        shapes = [("[1, 2, 3]", "list-meta"), ('"hello"', "string-meta"),
                  ("42", "number-meta"), ("true", "bool-meta"),
                  ("null", "null-meta")]
        for raw, job_id in shapes:
            with self.subTest(shape=raw):
                with tempfile.TemporaryDirectory() as state_dir:
                    spool = Path(state_dir) / "jobs" / job_id
                    spool.mkdir(parents=True)
                    (spool / "meta.json").write_text(raw)
                    (spool / "stdout").write_bytes(b"")
                    (spool / "stderr").write_bytes(b"")
                    self._write_job(state_dir, "healthy",
                                    started_at=100.0, ended_at=150.0)
                    stderr = self._load(la, state_dir)
                    self.assertNotIn(job_id, la.JOBS)
                    self.assertIn("healthy", la.JOBS)
                    self.assertTrue(spool.exists())
                    lines = [ln for ln in stderr.splitlines() if ln.strip()]
                    self.assertEqual(len(lines), 1, stderr)
                    self.assertIn(str(spool), lines[0])

    def test_other_malformed_shapes_are_skipped(self):
        la = self._import_agent()
        cases = [
            ("bool-started", {"started_at": True, "ended_at": 150.0}),
            ("list-ended", {"started_at": 100.0, "ended_at": [150.0]}),
            ("numeric-string", {"started_at": "123", "ended_at": 150.0}),
            ("object-started", {"started_at": {"t": 1},
                                "ended_at": 150.0}),
        ]
        for job_id, stamps in cases:
            with self.subTest(job_id=job_id):
                with tempfile.TemporaryDirectory() as state_dir:
                    self._write_job(state_dir, job_id, **stamps)
                    self._write_job(state_dir, "healthy",
                                    started_at=100.0, ended_at=150.0)
                    stderr = self._load(la, state_dir)
                    self.assertNotIn(job_id, la.JOBS)
                    self.assertIn("healthy", la.JOBS)
                    lines = [ln for ln in stderr.splitlines()
                             if ln.strip()]
                    self.assertEqual(len(lines), 1, stderr)
                    self.assertIn(job_id, lines[0])

    def test_nonfinite_timestamps_are_skipped(self):
        la = self._import_agent()
        cases = [
            ("nan-started", {"started_at": float("nan"),
                             "ended_at": 150.0}),
            ("nan-ended", {"started_at": 100.0,
                           "ended_at": float("nan")}),
            ("inf-started", {"started_at": float("inf"),
                             "ended_at": 150.0}),
            ("neg-inf-started", {"started_at": float("-inf"),
                                 "ended_at": 150.0}),
            ("inf-ended", {"started_at": 100.0,
                           "ended_at": float("inf")}),
            ("neg-inf-ended", {"started_at": 100.0,
                               "ended_at": float("-inf")}),
        ]
        for job_id, stamps in cases:
            with self.subTest(job_id=job_id):
                with tempfile.TemporaryDirectory() as state_dir:
                    bad = self._write_job(state_dir, job_id, **stamps)
                    self._write_job(state_dir, "healthy",
                                    started_at=100.0, ended_at=150.0)
                    stderr = self._load(la, state_dir)
                    self.assertNotIn(job_id, la.JOBS)
                    self.assertIn("healthy", la.JOBS)
                    self.assertTrue(bad.exists())
                    lines = [ln for ln in stderr.splitlines()
                             if ln.strip()]
                    self.assertEqual(len(lines), 1, stderr)
                    self.assertIn(str(bad), lines[0])

    def test_oversized_int_timestamps_are_skipped(self):
        # Codex review on PR #1534: math.isfinite(10**400) raises
        # OverflowError (int too large to convert to float) instead
        # of returning False, so an oversized integer timestamp must
        # be skipped whole like the other malformed shapes, not
        # escape load_persisted_jobs() and abort startup.
        la = self._import_agent()
        cases = [
            ("huge-started", {"started_at": 10**400, "ended_at": 150.0}),
            ("huge-ended", {"started_at": 100.0, "ended_at": 10**400}),
        ]
        for job_id, stamps in cases:
            with self.subTest(job_id=job_id):
                with tempfile.TemporaryDirectory() as state_dir:
                    bad = self._write_job(state_dir, job_id, **stamps)
                    self._write_job(state_dir, "healthy",
                                    started_at=100.0, ended_at=150.0)
                    stderr = self._load(la, state_dir)
                    self.assertNotIn(job_id, la.JOBS)
                    self.assertIn("healthy", la.JOBS)
                    self.assertTrue(bad.exists())
                    lines = [ln for ln in stderr.splitlines()
                             if ln.strip()]
                    self.assertEqual(len(lines), 1, stderr)
                    self.assertIn(str(bad), lines[0])

    def test_nonfinite_skipped_summary_and_public_succeed(self):
        la = self._import_agent()
        with tempfile.TemporaryDirectory() as state_dir:
            self._write_job(state_dir, "nan-started",
                            started_at=float("nan"), ended_at=150.0)
            self._write_job(state_dir, "inf-ended",
                            started_at=100.0, ended_at=float("inf"))
            self._write_job(state_dir, "healthy",
                            started_at=100.0, ended_at=150.0)
            stderr = self._load(la, state_dir)
            self.assertEqual(sorted(la.JOBS), ["healthy"])
            lines = [ln for ln in stderr.splitlines() if ln.strip()]
            self.assertEqual(len(lines), 2, stderr)
            with patch.object(la, "STATE_DIR", Path(state_dir)):
                summaries = [la.job_summary(j)
                             for j in list(la.JOBS.values())]
                publics = [la.job_public(j)
                           for j in list(la.JOBS.values())]
                la.reap_old_jobs()
            self.assertEqual([s["job_id"] for s in summaries],
                             ["healthy"])
            self.assertEqual(summaries[0]["duration_ms"], 50000)
            self.assertEqual([p["job_id"] for p in publics],
                             ["healthy"])
            self.assertEqual(publics[0]["duration_ms"], 50000)

    def test_well_formed_restore_unchanged_and_running_interrupted(self):
        la = self._import_agent()
        with tempfile.TemporaryDirectory() as state_dir:
            self._write_job(state_dir, "done-job",
                            started_at=100.0, ended_at=150.5)
            self._write_job(state_dir, "running-job", state="running",
                            exit=None, started_at=100.0, ended_at=None)
            self._write_job(state_dir, "no-stamps")
            stderr = self._load(la, state_dir)
            self.assertEqual(stderr, "")
            done = la.JOBS["done-job"]
            self.assertEqual(done["started_at"], 100.0)
            self.assertEqual(done["ended_at"], 150.5)
            self.assertEqual(done["state"], "done")
            self.assertFalse(done["interrupted"])
            running = la.JOBS["running-job"]
            self.assertEqual(running["state"], "done")
            self.assertTrue(running["interrupted"])
            self.assertIsInstance(running["ended_at"], float)
            self.assertEqual(running["started_at"], 100.0)
            bare = la.JOBS["no-stamps"]
            self.assertEqual(bare["started_at"], 0.0)
            # #1532 supersedes the #1513 default for a done job: a
            # null/missing ended_at gets a finite load-time stamp.
            self.assertIsInstance(bare["ended_at"], float)

    def test_non_string_id_skipped_healthy_kept(self):
        # Issue #1548: a persisted meta id that is not a string must
        # not crash startup (list/object: unhashable at the JOBS
        # assignment) or poison /jobs and the reaper (number/bool:
        # TypeError at job_dir). Oracle: same skip contract as
        # #1513/#1522 -- skipped whole, exactly one stderr line naming
        # its dir, spool left on disk, healthy siblings unchanged.
        la = self._import_agent()
        cases = [
            ("numeric-id", 42),
            ("zero-id", 0),
            ("bool-id", True),
            ("false-id", False),
            ("list-id", ["a", "b"]),
            ("object-id", {"a": 1}),
        ]
        for job_id, bad_id in cases:
            with self.subTest(job_id=job_id, bad_id=repr(bad_id)):
                with tempfile.TemporaryDirectory() as state_dir:
                    bad = self._write_job(state_dir, job_id, id=bad_id,
                                          started_at=100.0,
                                          ended_at=150.0)
                    self._write_job(state_dir, "healthy",
                                    started_at=100.0, ended_at=150.0)
                    stderr = self._load(la, state_dir)
                    self.assertNotIn(job_id, la.JOBS)
                    self.assertEqual(sorted(la.JOBS), ["healthy"])
                    self.assertTrue(bad.exists())
                    lines = [ln for ln in stderr.splitlines()
                             if ln.strip()]
                    self.assertEqual(len(lines), 1, stderr)
                    self.assertIn(str(bad), lines[0])
                    self.assertIn("id", lines[0])

    def test_non_string_id_running_entry_skipped_no_meta_write(self):
        # A running entry is the _write_meta crash vector: restore
        # converts it to interrupted and _write_meta calls
        # job_dir(job["id"]) before its try block. A non-string id
        # must be skipped before any of that, spool untouched.
        la = self._import_agent()
        with tempfile.TemporaryDirectory() as state_dir:
            bad = self._write_job(state_dir, "running-bad-id", id=42,
                                  state="running", exit=None,
                                  started_at=100.0, ended_at=None)
            before = (bad / "meta.json").read_text()
            self._write_job(state_dir, "healthy",
                            started_at=100.0, ended_at=150.0)
            stderr = self._load(la, state_dir)
            self.assertEqual(sorted(la.JOBS), ["healthy"])
            self.assertEqual((bad / "meta.json").read_text(), before)
            lines = [ln for ln in stderr.splitlines() if ln.strip()]
            self.assertEqual(len(lines), 1, stderr)

    def test_non_string_id_summary_public_and_reaper_succeed(self):
        la = self._import_agent()
        with tempfile.TemporaryDirectory() as state_dir:
            self._write_job(state_dir, "list-id-job", id=[1, 2],
                            started_at=100.0, ended_at=150.0)
            self._write_job(state_dir, "numeric-id-job", id=7,
                            started_at=100.0, ended_at=150.0)
            self._write_job(state_dir, "healthy",
                            started_at=100.0, ended_at=150.0)
            stderr = self._load(la, state_dir)
            self.assertEqual(sorted(la.JOBS), ["healthy"])
            lines = [ln for ln in stderr.splitlines() if ln.strip()]
            self.assertEqual(len(lines), 2, stderr)
            with patch.object(la, "STATE_DIR", Path(state_dir)):
                summaries = [la.job_summary(j)
                             for j in list(la.JOBS.values())]
                publics = [la.job_public(j)
                           for j in list(la.JOBS.values())]
                la.reap_old_jobs()
            self.assertEqual([s["job_id"] for s in summaries],
                             ["healthy"])
            self.assertEqual([p["job_id"] for p in publics],
                             ["healthy"])

    def test_missing_null_empty_id_falls_back_to_dir_name(self):
        # Acceptance #1548: missing/null/empty-string id keeps the
        # current fallback to the spool directory name.
        la = self._import_agent()
        with tempfile.TemporaryDirectory() as state_dir:
            self._write_job(state_dir, "null-id", id=None,
                            started_at=100.0, ended_at=150.0)
            self._write_job(state_dir, "empty-id", id="",
                            started_at=100.0, ended_at=150.0)
            missing = self._write_job(state_dir, "missing-id",
                                      started_at=100.0, ended_at=150.0)
            meta = json.loads((missing / "meta.json").read_text())
            del meta["id"]
            (missing / "meta.json").write_text(json.dumps(meta))
            stderr = self._load(la, state_dir)
            self.assertEqual(stderr, "")
            self.assertEqual(sorted(la.JOBS),
                             ["empty-id", "missing-id", "null-id"])

    def test_parent_string_id_is_skipped_without_reaping_outside_jobs(self):
        # Issue #1554: a persisted traversal id must not escape the jobs
        # directory through the public serializers or startup reaper.
        la = self._import_agent()
        with tempfile.TemporaryDirectory() as state_dir:
            state = Path(state_dir)
            bad = self._write_job(
                state_dir, "bad-parent-id", id="..",
                started_at=100.0, ended_at=time.time() - 2 * la.JOB_TTL_S)
            healthy = self._write_job(
                state_dir, "healthy", started_at=100.0, ended_at=time.time())
            sentinel = state / "keep-me"
            sentinel.write_text("outside the jobs directory")

            stderr = self._load(la, state_dir)
            self.assertEqual(sorted(la.JOBS), ["healthy"])
            self.assertTrue(bad.exists())
            lines = [ln for ln in stderr.splitlines() if ln.strip()]
            self.assertEqual(len(lines), 1, stderr)
            self.assertIn(str(bad), lines[0])
            self.assertIn("id", lines[0])

            with patch.object(la, "STATE_DIR", state):
                summaries = [la.job_summary(j)
                             for j in list(la.JOBS.values())]
                publics = [la.job_public(j)
                           for j in list(la.JOBS.values())]
                la.reap_old_jobs()

            self.assertEqual([s["job_id"] for s in summaries], ["healthy"])
            self.assertEqual([p["job_id"] for p in publics], ["healthy"])
            self.assertTrue(sentinel.exists())
            self.assertTrue(healthy.exists())
            self.assertTrue(bad.exists())

    def test_separator_and_cross_job_ids_are_skipped(self):
        la = self._import_agent()
        with tempfile.TemporaryDirectory() as state_dir:
            bad_separator = self._write_job(
                state_dir, "bad-separator", id="../escape", state="running",
                exit=None, started_at=100.0, ended_at=None)
            bad_separator_meta = (bad_separator / "meta.json").read_text()
            cross_job = self._write_job(
                state_dir, "cross-job", id="healthy",
                started_at=100.0, ended_at=time.time() - 2 * la.JOB_TTL_S)
            healthy = self._write_job(
                state_dir, "healthy", started_at=100.0, ended_at=time.time())

            stderr = self._load(la, state_dir)
            self.assertEqual(sorted(la.JOBS), ["healthy"])
            self.assertEqual(la.JOBS["healthy"]["cmd_repr"], "test")
            self.assertTrue(bad_separator.exists())
            self.assertEqual((bad_separator / "meta.json").read_text(),
                             bad_separator_meta)
            self.assertFalse((Path(state_dir) / "escape").exists())
            self.assertTrue(cross_job.exists())
            lines = [ln for ln in stderr.splitlines() if ln.strip()]
            self.assertEqual(len(lines), 2, stderr)
            self.assertTrue(all(any(str(spool) in line for line in lines)
                                for spool in (bad_separator, cross_job)),
                            stderr)

            with patch.object(la, "STATE_DIR", Path(state_dir)):
                la.reap_old_jobs()
            self.assertTrue(bad_separator.exists())
            self.assertTrue(cross_job.exists())
            self.assertTrue(healthy.exists())

    def test_job_dir_rejects_non_child_and_symlink_paths(self):
        la = self._import_agent()
        with tempfile.TemporaryDirectory() as state_dir:
            state = Path(state_dir)
            jobs = state / "jobs"
            jobs.mkdir()
            outside = state / "outside"
            outside.mkdir()
            (jobs / "linked").symlink_to(outside, target_is_directory=True)
            with patch.object(la, "STATE_DIR", state):
                for job_id in ("..", ".", "../outside", "nested/job",
                               "nested\\job", "linked"):
                    with self.subTest(job_id=job_id):
                        with self.assertRaises(ValueError):
                            la.job_dir(job_id)

    def test_persisted_interrupted_true_round_trips_two_loads(self):
        # Issue #1556: _write_meta persists interrupted:true for a
        # restart-interrupted done job, but the restore hardcoded
        # interrupted=False, so a second restart dropped the marker.
        # Oracle: the flag restores faithfully and round-trips
        # unchanged through _write_meta across repeated loads.
        la = self._import_agent()
        with tempfile.TemporaryDirectory() as state_dir:
            self._write_job(state_dir, "interrupted-job",
                            interrupted=True, exit=None,
                            started_at=100.0, ended_at=150.0)
            self._write_job(state_dir, "plain-job",
                            started_at=100.0, ended_at=150.0)
            stderr = self._load(la, state_dir)
            self.assertEqual(stderr, "")
            job = la.JOBS["interrupted-job"]
            self.assertTrue(job["interrupted"])
            self.assertEqual(job["state"], "done")
            with patch.object(la, "STATE_DIR", Path(state_dir)):
                self.assertTrue(la.job_public(job)["interrupted"])
                la._write_meta(job)
                meta = json.loads((Path(state_dir) / "jobs"
                                   / "interrupted-job"
                                   / "meta.json").read_text())
            self.assertIs(meta["interrupted"], True)
            stderr = self._load(la, state_dir)
            self.assertEqual(stderr, "")
            self.assertTrue(la.JOBS["interrupted-job"]["interrupted"])
            self.assertFalse(la.JOBS["plain-job"]["interrupted"])

    def test_invalid_state_skipped_healthy_kept(self):
        # Issue #1556: a persisted state outside {running, done} was
        # restored verbatim, so /jobs served a nonexistent state and
        # the recorded exit code was suppressed. Oracle: same skip
        # contract as #1513/#1522/#1548 -- skipped whole, exactly one
        # stderr line naming its dir, spool left on disk, healthy
        # siblings unchanged.
        la = self._import_agent()
        cases = [
            ("bogus-state", "bogus-state"),
            ("numeric-state", 7),
            ("list-state", ["done"]),
            ("bool-state", True),
        ]
        for job_id, bad_state in cases:
            with self.subTest(job_id=job_id, bad_state=repr(bad_state)):
                with tempfile.TemporaryDirectory() as state_dir:
                    bad = self._write_job(state_dir, job_id,
                                          state=bad_state,
                                          started_at=100.0,
                                          ended_at=150.0)
                    self._write_job(state_dir, "healthy",
                                    started_at=100.0, ended_at=150.0)
                    stderr = self._load(la, state_dir)
                    self.assertNotIn(job_id, la.JOBS)
                    self.assertEqual(sorted(la.JOBS), ["healthy"])
                    self.assertTrue(bad.exists())
                    lines = [ln for ln in stderr.splitlines() if ln.strip()]
                    self.assertEqual(len(lines), 1, stderr)
                    self.assertIn(str(bad), lines[0])
                    self.assertIn("state", lines[0])

    def test_missing_null_state_defaults_done_and_non_bool_interrupted_skipped(self):
        # Issue #1556 acceptance: missing/null state keeps the
        # established "done" default, while a non-boolean interrupted
        # follows the loader's malformed-field handling (skip whole).
        la = self._import_agent()
        with tempfile.TemporaryDirectory() as state_dir:
            missing = self._write_job(state_dir, "missing-state",
                                      started_at=100.0, ended_at=150.0)
            meta = json.loads((missing / "meta.json").read_text())
            del meta["state"]
            (missing / "meta.json").write_text(json.dumps(meta))
            self._write_job(state_dir, "null-state", state=None,
                            started_at=100.0, ended_at=150.0)
            bad = self._write_job(state_dir, "string-interrupted",
                                  interrupted="yes",
                                  started_at=100.0, ended_at=150.0)
            self._write_job(state_dir, "healthy",
                            started_at=100.0, ended_at=150.0)
            stderr = self._load(la, state_dir)
            self.assertEqual(la.JOBS["missing-state"]["state"], "done")
            self.assertEqual(la.JOBS["null-state"]["state"], "done")
            self.assertNotIn("string-interrupted", la.JOBS)
            self.assertTrue(bad.exists())
            lines = [ln for ln in stderr.splitlines() if ln.strip()]
            self.assertEqual(len(lines), 1, stderr)
            self.assertIn(str(bad), lines[0])
            self.assertIn("interrupted", lines[0])
    def test_reap_guards_unsafe_spool_and_removes_healthy(self):
        # Issue #1560: PR #1555 made job_dir() raise ValueError, but
        # reap_old_jobs() called it unguarded after popping every dead
        # job from JOBS -- one spool replaced by a symlink aborted the
        # whole reap and the already-popped healthy spools leaked.
        # Oracle: reap returns normally, the healthy past-TTL spool is
        # removed, the unsafe spool is left in place, and exactly one
        # stderr line names the unsafe job (log-and-drop: the job is
        # already popped, so without the line the leak is silent).
        la = self._import_agent()
        with tempfile.TemporaryDirectory() as state_dir:
            state = Path(state_dir)
            jobs_root = state / "jobs"
            jobs_root.mkdir(parents=True)
            outside = state / "outside"
            outside.mkdir()
            (jobs_root / "badjob").symlink_to(outside,
                                              target_is_directory=True)
            healthy = jobs_root / "goodjob"
            healthy.mkdir()
            (healthy / "stdout").write_bytes(b"hi")
            now = time.time()
            for job_id in ("badjob", "goodjob"):
                la.JOBS[job_id] = {
                    "id": job_id, "proc": None, "cwd": "/",
                    "cmd_repr": "test", "started_at": now - 90000,
                    "ended_at": now - 90000, "exit": 0, "state": "done",
                    "interrupted": False, "_files": ()}
            err = io.StringIO()
            with patch.object(la, "STATE_DIR", state):
                with contextlib.redirect_stderr(err):
                    la.reap_old_jobs()
            self.assertEqual(la.JOBS, {})
            self.assertFalse(healthy.exists())
            self.assertTrue((jobs_root / "badjob").is_symlink())
            self.assertTrue(outside.exists())
            lines = [ln for ln in err.getvalue().splitlines() if ln.strip()]
            self.assertEqual(len(lines), 1, err.getvalue())
            self.assertIn("badjob", lines[0])

    def test_read_paths_degrade_per_job_on_unsafe_spool(self):
        # Issue #1575: job_public()/job_summary() called job_dir()
        # unguarded and _write_meta() called it outside its OSError
        # guard -- one spool replaced by a symlink after load made
        # GET /jobs answer 400 for every job. Oracle: the serializers
        # degrade per-job (poisoned job serves its in-memory record
        # with empty output/zero sizes, one stderr line naming it),
        # the healthy job reads normally, and _write_meta via
        # job_state() cannot leak ValueError.
        la = self._import_agent()
        with tempfile.TemporaryDirectory() as state_dir:
            state = Path(state_dir)
            jobs_root = state / "jobs"
            jobs_root.mkdir(parents=True)
            outside = state / "outside"
            outside.mkdir()
            (jobs_root / "badjob").symlink_to(outside,
                                              target_is_directory=True)
            (jobs_root / "runbad").symlink_to(outside,
                                              target_is_directory=True)
            healthy = jobs_root / "goodjob"
            healthy.mkdir()
            (healthy / "stdout").write_bytes(b"hi")
            (healthy / "stderr").write_bytes(b"")
            now = time.time()
            for job_id, st in (("badjob", "done"), ("goodjob", "done"),
                               ("runbad", "running")):
                la.JOBS[job_id] = {
                    "id": job_id, "proc": None, "cwd": "/",
                    "cmd_repr": "test", "started_at": now - 10,
                    "ended_at": now if st == "done" else None,
                    "exit": 0 if st == "done" else None, "state": st,
                    "interrupted": False, "_files": ()}
            err = io.StringIO()
            with patch.object(la, "STATE_DIR", state):
                with contextlib.redirect_stderr(err):
                    summaries = [la.job_summary(j)
                                 for j in la.JOBS.values()
                                 if j["state"] == "done"]
                    public_bad = la.job_public(la.JOBS["badjob"])
                    public_good = la.job_public(la.JOBS["goodjob"])
                    # job_state on a running job calls _write_meta.
                    self.assertEqual(la.job_state(la.JOBS["runbad"]),
                                     "done")
            by_id = {x["job_id"]: x for x in summaries}
            self.assertEqual(by_id["goodjob"]["out_bytes"], 2)
            self.assertEqual(by_id["badjob"]["out_bytes"], 0)
            self.assertEqual(by_id["badjob"]["err_bytes"], 0)
            self.assertEqual(public_bad["stdout"], "")
            self.assertEqual(public_bad["state"], "done")
            self.assertEqual(public_good["stdout"], "hi")
            lines = [ln for ln in err.getvalue().splitlines()
                     if ln.strip()]
            self.assertTrue(any("badjob" in ln for ln in lines),
                            err.getvalue())

class PersistedJobRestoreContractTest(unittest.TestCase):
    """Issue #1579 (design #1578 phase 1): the contract probe matrix
    for the one restore validator, generated from the field table.

    Oracle: the writer (_write_meta). Every guarded field x {wrong
    type, non-finite where numeric, bool-as-number, shape attack
    where applicable, missing, null, the writer's own well-formed
    value}: a present-but-malformed value skips the whole entry --
    exactly one stderr line naming the directory and the field,
    the spool byte-identical, a healthy sibling restored -- while
    missing/null takes the table's named default and a well-formed
    value restores verbatim. Plus both transition rows and one
    _write_meta -> reload round-trip asserting the served job is
    identical. The per-incident tests in PersistedJobTimestampTest
    above are the regression oracle; their assertions are
    unmodified -- this class only adds coverage.
    """

    def _import_agent(self):
        with tempfile.NamedTemporaryFile("w", suffix="-token",
                                         delete=False) as f:
            f.write("restore-contract-test-token\n")
            token_path = f.name
        os.environ.setdefault("LAPTOP_AGENT_TOKEN_FILE", token_path)
        sys.path.insert(0, str(AGENT.parent))
        import laptop_agent as la
        return la

    def _base_meta(self, job_id):
        return {"id": job_id, "cwd": "/", "cmd": "test",
                "started_at": 100.0, "ended_at": 150.0, "exit": 0,
                "state": "done", "interrupted": False}

    def _write_raw(self, state_dir, job_id, meta):
        spool = Path(state_dir) / "jobs" / job_id
        spool.mkdir(parents=True)
        raw = json.dumps(meta)
        (spool / "meta.json").write_text(raw)
        (spool / "stdout").write_bytes(b"")
        (spool / "stderr").write_bytes(b"")
        return spool, raw

    def _load(self, la, state_dir):
        la.JOBS.clear()
        err = io.StringIO()
        with patch.object(la, "STATE_DIR", Path(state_dir)):
            with contextlib.redirect_stderr(err):
                la.load_persisted_jobs()
        return err.getvalue()

    def tearDown(self):
        la_mod = sys.modules.get("laptop_agent")
        if la_mod is not None:
            la_mod.JOBS.clear()

    def test_field_table_covers_exactly_the_writer_fields(self):
        la = self._import_agent()
        self.assertEqual(
            [row[0] for row in la.RESTORE_FIELD_TABLE],
            ["id", "cwd", "cmd", "started_at", "ended_at",
             "exit", "state", "interrupted"])
        for row in la.RESTORE_FIELD_TABLE:
            self.assertEqual(len(row), 4, row)
        by_field = {row[0]: row for row in la.RESTORE_FIELD_TABLE}
        for field in ("exit", "cwd", "cmd"):
            self.assertIn("#1568", by_field[field][3])

    def test_malformed_matrix_rows_are_skipped(self):
        la = self._import_agent()
        ts_bad = ["123", True, False, [150.0], {"t": 1},
                  float("nan"), float("inf"), float("-inf"), 10**400]
        cases = []
        for value in ts_bad:
            cases.append(("started_at", value))
            cases.append(("ended_at", value))
        for value in [42, True, ["a"], {"a": 1},
                      "..", ".", "a/b", "a\\b", "other-job"]:
            cases.append(("id", value))
        for value in ["bogus", 7, True, ["done"], {"s": 1}]:
            cases.append(("state", value))
        for value in ["yes", 1, 0, ["true"], {"i": 1}]:
            cases.append(("interrupted", value))
        for field, value in cases:
            with self.subTest(field=field, value=repr(value)):
                with tempfile.TemporaryDirectory() as state_dir:
                    meta = self._base_meta("bad-job")
                    meta[field] = value
                    spool, raw = self._write_raw(state_dir, "bad-job",
                                                 meta)
                    self._write_raw(state_dir, "healthy",
                                    self._base_meta("healthy"))
                    stderr = self._load(la, state_dir)
                    self.assertNotIn("bad-job", la.JOBS)
                    self.assertIn("healthy", la.JOBS)
                    self.assertTrue(spool.exists())
                    self.assertEqual((spool / "meta.json").read_text(),
                                     raw)
                    lines = [ln for ln in stderr.splitlines()
                             if ln.strip()]
                    self.assertEqual(len(lines), 1, stderr)
                    self.assertIn(str(spool), lines[0])
                    self.assertIn(field, lines[0])

    def test_non_object_container_matrix_rows_are_skipped(self):
        la = self._import_agent()
        for raw in ["[1, 2, 3]", '"hello"', "42", "true", "null"]:
            with self.subTest(raw=raw):
                with tempfile.TemporaryDirectory() as state_dir:
                    spool = Path(state_dir) / "jobs" / "bad-job"
                    spool.mkdir(parents=True)
                    (spool / "meta.json").write_text(raw)
                    (spool / "stdout").write_bytes(b"")
                    (spool / "stderr").write_bytes(b"")
                    self._write_raw(state_dir, "healthy",
                                    self._base_meta("healthy"))
                    stderr = self._load(la, state_dir)
                    self.assertNotIn("bad-job", la.JOBS)
                    self.assertIn("healthy", la.JOBS)
                    self.assertEqual((spool / "meta.json").read_text(),
                                     raw)
                    lines = [ln for ln in stderr.splitlines()
                             if ln.strip()]
                    self.assertEqual(len(lines), 1, stderr)
                    self.assertIn(str(spool), lines[0])

    def test_missing_and_null_rows_take_table_defaults(self):
        la = self._import_agent()
        for field in ["started_at", "ended_at", "id", "state",
                      "interrupted"]:
            for mode in ["missing", "null"]:
                with self.subTest(field=field, mode=mode):
                    with tempfile.TemporaryDirectory() as state_dir:
                        meta = self._base_meta("case-job")
                        if mode == "missing":
                            del meta[field]
                        else:
                            meta[field] = None
                        self._write_raw(state_dir, "case-job", meta)
                        stderr = self._load(la, state_dir)
                        self.assertEqual(stderr, "")
                        job = la.JOBS["case-job"]
                        if field == "started_at":
                            self.assertEqual(job["started_at"], 0.0)
                        elif field == "ended_at":
                            # #1532 transition: stamped at load.
                            self.assertIsInstance(job["ended_at"],
                                                  float)
                        elif field == "state":
                            self.assertEqual(job["state"], "done")
                        elif field == "interrupted":
                            self.assertFalse(job["interrupted"])
        with tempfile.TemporaryDirectory() as state_dir:
            meta = self._base_meta("empty-id")
            meta["id"] = ""
            self._write_raw(state_dir, "empty-id", meta)
            self.assertEqual(self._load(la, state_dir), "")
            self.assertIn("empty-id", la.JOBS)

    def test_well_formed_writer_values_restore_verbatim(self):
        la = self._import_agent()
        with tempfile.TemporaryDirectory() as state_dir:
            self._write_raw(state_dir, "writer-job",
                            self._base_meta("writer-job"))
            meta = self._base_meta("int-stamps")
            meta["started_at"] = 100
            meta["ended_at"] = 150
            meta["interrupted"] = True
            self._write_raw(state_dir, "int-stamps", meta)
            stderr = self._load(la, state_dir)
            self.assertEqual(stderr, "")
            job = la.JOBS["writer-job"]
            self.assertEqual(job["started_at"], 100.0)
            self.assertEqual(job["ended_at"], 150.0)
            self.assertEqual(job["exit"], 0)
            self.assertEqual(job["state"], "done")
            self.assertFalse(job["interrupted"])
            self.assertEqual(job["cwd"], "/")
            self.assertEqual(job["cmd_repr"], "test")
            stamps = la.JOBS["int-stamps"]
            self.assertEqual(stamps["started_at"], 100.0)
            self.assertEqual(stamps["ended_at"], 150.0)
            self.assertTrue(stamps["interrupted"])

    def test_both_transitions_and_their_persistence(self):
        la = self._import_agent()
        with tempfile.TemporaryDirectory() as state_dir:
            running = self._base_meta("was-running")
            running.update(state="running", exit=5, ended_at=None)
            spool_r, _ = self._write_raw(state_dir, "was-running",
                                         running)
            done = self._base_meta("done-no-end")
            done["ended_at"] = None
            spool_d, _ = self._write_raw(state_dir, "done-no-end",
                                         done)
            stderr = self._load(la, state_dir)
            self.assertEqual(stderr, "")
            job = la.JOBS["was-running"]
            self.assertEqual(job["state"], "done")
            self.assertTrue(job["interrupted"])
            self.assertIsNone(job["exit"])
            self.assertIsInstance(job["ended_at"], float)
            meta_r = json.loads((spool_r / "meta.json").read_text())
            self.assertEqual(meta_r["state"], "done")
            self.assertIs(meta_r["interrupted"], True)
            self.assertIsNone(meta_r["exit"])
            self.assertEqual(meta_r["ended_at"], job["ended_at"])
            job_d = la.JOBS["done-no-end"]
            self.assertIsInstance(job_d["ended_at"], float)
            meta_d = json.loads((spool_d / "meta.json").read_text())
            self.assertEqual(meta_d["ended_at"], job_d["ended_at"])

    def test_validator_returns_a_single_reason_naming_the_field(self):
        la = self._import_agent()
        cases = [("started_at", "123"), ("ended_at", float("nan")),
                 ("id", 42), ("id", ".."), ("state", "bogus"),
                 ("interrupted", "yes")]
        with tempfile.TemporaryDirectory() as state_dir:
            with patch.object(la, "STATE_DIR", Path(state_dir)):
                for field, value in cases:
                    with self.subTest(field=field, value=repr(value)):
                        meta = self._base_meta("case-job")
                        meta[field] = value
                        job, persist, reason = \
                            la._restore_persisted_job(meta, "case-job")
                        self.assertIsNone(job)
                        self.assertFalse(persist)
                        self.assertIn(field, reason)
                job, persist, reason = la._restore_persisted_job(
                    self._base_meta("case-job"), "case-job")
                self.assertIsNotNone(job)
                self.assertIsNone(reason)

    def test_write_meta_reload_round_trip_serves_identical_job(self):
        la = self._import_agent()
        job = {"id": "round-trip", "proc": None, "cwd": "/",
               "cmd_repr": "echo hi", "started_at": 100.0,
               "ended_at": 150.0, "exit": 3, "state": "done",
               "interrupted": False, "_files": ()}
        with tempfile.TemporaryDirectory() as state_dir:
            with patch.object(la, "STATE_DIR", Path(state_dir)):
                la._write_meta(job)
            stderr = self._load(la, state_dir)
            self.assertEqual(stderr, "")
            restored = la.JOBS["round-trip"]
            for key in ("id", "cwd", "cmd_repr", "started_at",
                        "ended_at", "exit", "state", "interrupted"):
                self.assertEqual(restored[key], job[key], key)
            with patch.object(la, "STATE_DIR", Path(state_dir)):
                public = la.job_public(restored)
            self.assertEqual(public, {
                "job_id": "round-trip", "state": "done", "exit": 3,
                "cwd": "/", "cmd": "echo hi", "started_at": 100.0,
                "interrupted": False, "duration_ms": 50000,
                "stdout": "", "stderr": "", "out_next": 0,
                "err_next": 0})


class PersistedJobExitCwdCmdTest(unittest.TestCase):
    """Issue #1568: load_persisted_jobs restored exit/cwd/cmd
    verbatim -- a malformed meta.json exit was served verbatim as
    the job's exit code, and _write_meta re-persisted the junk.

    Oracle: the writer (_write_meta) only ever writes exit as an
    int returncode (negative for signal deaths) or None, and
    cwd/cmd as strings. A present value of any other shape follows
    the established skip contract -- skipped whole, exactly one
    stderr line naming its dir and the field, spool left on disk,
    healthy siblings unchanged -- while missing/None keep the
    established defaults (None / home dir / ""). The checks live
    in the one restore validator as RESTORE_FIELD_TABLE rows, per
    the #1579 fold-in rule (design #1578 phase 1).
    """

    def _import_agent(self):
        with tempfile.NamedTemporaryFile("w", suffix="-token",
                                         delete=False) as f:
            f.write("persisted-exit-cwd-cmd-test-token\n")
            token_path = f.name
        os.environ.setdefault("LAPTOP_AGENT_TOKEN_FILE", token_path)
        sys.path.insert(0, str(AGENT.parent))
        import laptop_agent as la
        return la

    def _base_meta(self, job_id):
        return {"id": job_id, "cwd": "/", "cmd": "test",
                "started_at": 100.0, "ended_at": 150.0, "exit": 0,
                "state": "done", "interrupted": False}

    def _write_raw(self, state_dir, job_id, meta):
        spool = Path(state_dir) / "jobs" / job_id
        spool.mkdir(parents=True)
        raw = json.dumps(meta)
        (spool / "meta.json").write_text(raw)
        (spool / "stdout").write_bytes(b"")
        (spool / "stderr").write_bytes(b"")
        return spool, raw

    def _load(self, la, state_dir):
        la.JOBS.clear()
        err = io.StringIO()
        with patch.object(la, "STATE_DIR", Path(state_dir)):
            with contextlib.redirect_stderr(err):
                la.load_persisted_jobs()
        return err.getvalue()

    def tearDown(self):
        la_mod = sys.modules.get("laptop_agent")
        if la_mod is not None:
            la_mod.JOBS.clear()

    def _assert_skipped(self, la, field, value):
        with tempfile.TemporaryDirectory() as state_dir:
            meta = self._base_meta("bad-job")
            meta[field] = value
            spool, raw = self._write_raw(state_dir, "bad-job", meta)
            self._write_raw(state_dir, "healthy",
                            self._base_meta("healthy"))
            stderr = self._load(la, state_dir)
            self.assertNotIn("bad-job", la.JOBS)
            self.assertIn("healthy", la.JOBS)
            self.assertTrue(spool.exists())
            self.assertEqual((spool / "meta.json").read_text(), raw)
            lines = [ln for ln in stderr.splitlines() if ln.strip()]
            self.assertEqual(len(lines), 1, stderr)
            self.assertIn(str(spool), lines[0])
            self.assertIn(field, lines[0])

    def test_non_integer_exit_skipped_healthy_kept(self):
        la = self._import_agent()
        for value in ["0", [0], {"x": 1}, 0.5, True, False]:
            with self.subTest(value=repr(value)):
                self._assert_skipped(la, "exit", value)

    def test_exit_controls_restore_verbatim(self):
        la = self._import_agent()
        with tempfile.TemporaryDirectory() as state_dir:
            for job_id, value in [("zero-exit", 0),
                                  ("negative-exit", -9),
                                  ("null-exit", None)]:
                meta = self._base_meta(job_id)
                meta["exit"] = value
                self._write_raw(state_dir, job_id, meta)
            meta = self._base_meta("missing-exit")
            del meta["exit"]
            self._write_raw(state_dir, "missing-exit", meta)
            stderr = self._load(la, state_dir)
            self.assertEqual(stderr, "")
            self.assertEqual(la.JOBS["zero-exit"]["exit"], 0)
            self.assertEqual(la.JOBS["negative-exit"]["exit"], -9)
            self.assertIsNone(la.JOBS["null-exit"]["exit"])
            self.assertIsNone(la.JOBS["missing-exit"]["exit"])

    def test_non_string_cwd_skipped_healthy_kept(self):
        la = self._import_agent()
        for value in [123, ["x"], {"x": 1}, True]:
            with self.subTest(value=repr(value)):
                self._assert_skipped(la, "cwd", value)

    def test_cwd_defaults_and_verbatim_restore(self):
        la = self._import_agent()
        with tempfile.TemporaryDirectory() as state_dir:
            for job_id, mode in [("missing-cwd", "missing"),
                                 ("null-cwd", "null"),
                                 ("empty-cwd", "empty")]:
                meta = self._base_meta(job_id)
                if mode == "missing":
                    del meta["cwd"]
                elif mode == "null":
                    meta["cwd"] = None
                else:
                    meta["cwd"] = ""
                self._write_raw(state_dir, job_id, meta)
            meta = self._base_meta("real-cwd")
            meta["cwd"] = "/work/tree"
            self._write_raw(state_dir, "real-cwd", meta)
            stderr = self._load(la, state_dir)
            self.assertEqual(stderr, "")
            for job_id in ("missing-cwd", "null-cwd", "empty-cwd"):
                self.assertEqual(la.JOBS[job_id]["cwd"],
                                 str(Path.home()))
            self.assertEqual(la.JOBS["real-cwd"]["cwd"], "/work/tree")

    def test_non_string_cmd_skipped_healthy_kept(self):
        la = self._import_agent()
        for value in [{"x": 1}, 42, ["ls"], True]:
            with self.subTest(value=repr(value)):
                self._assert_skipped(la, "cmd", value)

    def test_cmd_defaults_and_verbatim_restore(self):
        la = self._import_agent()
        with tempfile.TemporaryDirectory() as state_dir:
            for job_id, mode in [("missing-cmd", "missing"),
                                 ("null-cmd", "null"),
                                 ("empty-cmd", "empty")]:
                meta = self._base_meta(job_id)
                if mode == "missing":
                    del meta["cmd"]
                elif mode == "null":
                    meta["cmd"] = None
                else:
                    meta["cmd"] = ""
                self._write_raw(state_dir, job_id, meta)
            meta = self._base_meta("real-cmd")
            meta["cmd"] = "ls -la"
            self._write_raw(state_dir, "real-cmd", meta)
            stderr = self._load(la, state_dir)
            self.assertEqual(stderr, "")
            for job_id in ("missing-cmd", "null-cmd", "empty-cmd"):
                self.assertEqual(la.JOBS[job_id]["cmd_repr"], "")
            self.assertEqual(la.JOBS["real-cmd"]["cmd_repr"], "ls -la")

    def test_malformed_exit_summary_public_and_reaper_succeed(self):
        la = self._import_agent()
        with tempfile.TemporaryDirectory() as state_dir:
            meta = self._base_meta("bad-exit")
            meta["exit"] = "0"
            self._write_raw(state_dir, "bad-exit", meta)
            self._write_raw(state_dir, "healthy",
                            self._base_meta("healthy"))
            stderr = self._load(la, state_dir)
            self.assertEqual(sorted(la.JOBS), ["healthy"])
            lines = [ln for ln in stderr.splitlines() if ln.strip()]
            self.assertEqual(len(lines), 1, stderr)
            with patch.object(la, "STATE_DIR", Path(state_dir)):
                summaries = [la.job_summary(j)
                             for j in list(la.JOBS.values())]
                publics = [la.job_public(j)
                           for j in list(la.JOBS.values())]
                la.reap_old_jobs()
            self.assertEqual([s["job_id"] for s in summaries],
                             ["healthy"])
            self.assertEqual(publics[0]["exit"], 0)


class PersistedJobOversizedMetaTest(unittest.TestCase):
    """Issue #2094: load_persisted_jobs read each spool meta.json
    with an uncapped read_text() before parsing, so one oversized
    meta.json spiked daemon memory at startup.

    Oracle: a meta.json larger than MAX_META is rejected with one
    logged line naming its dir and the cap, without being restored;
    a normal meta.json in a sibling spool still restores (control).
    """

    def _import_agent(self):
        with tempfile.NamedTemporaryFile("w", suffix="-token",
                                         delete=False) as f:
            f.write("persisted-oversized-meta-test-token\n")
            token_path = f.name
        os.environ.setdefault("LAPTOP_AGENT_TOKEN_FILE", token_path)
        sys.path.insert(0, str(AGENT.parent))
        import laptop_agent as la
        return la

    def _base_meta(self, job_id):
        return {"id": job_id, "cwd": "/", "cmd": "test",
                "started_at": 100.0, "ended_at": 150.0, "exit": 0,
                "state": "done", "interrupted": False}

    def _write_spool(self, state_dir, job_id, raw):
        spool = Path(state_dir) / "jobs" / job_id
        spool.mkdir(parents=True)
        (spool / "meta.json").write_bytes(raw)
        (spool / "stdout").write_bytes(b"")
        (spool / "stderr").write_bytes(b"")
        return spool

    def _load(self, la, state_dir):
        la.JOBS.clear()
        err = io.StringIO()
        with patch.object(la, "STATE_DIR", Path(state_dir)):
            with contextlib.redirect_stderr(err):
                la.load_persisted_jobs()
        return err.getvalue()

    def tearDown(self):
        la_mod = sys.modules.get("laptop_agent")
        if la_mod is not None:
            la_mod.JOBS.clear()

    def test_oversized_meta_skipped_normal_meta_restores(self):
        la = self._import_agent()
        with tempfile.TemporaryDirectory() as state_dir:
            big = dict(self._base_meta("big-job"))
            big["cmd"] = "x" * (la.MAX_META + 1)
            big_spool = self._write_spool(
                state_dir, "big-job", json.dumps(big).encode())
            self.assertGreater(
                (big_spool / "meta.json").stat().st_size, la.MAX_META)
            self._write_spool(state_dir, "healthy",
                              json.dumps(self._base_meta("healthy")).encode())
            stderr = self._load(la, state_dir)
            self.assertNotIn("big-job", la.JOBS)
            self.assertIn("healthy", la.JOBS)
            lines = [ln for ln in stderr.splitlines() if ln.strip()]
            self.assertEqual(len(lines), 1, stderr)
            self.assertIn(str(big_spool), lines[0])
            self.assertIn("meta.json exceeds", lines[0])


class ReaperStartupTest(unittest.TestCase):
    """#1504: past-TTL finished jobs are reaped at startup, with no
    new POST /jobs — the daemon is only ever health-polled here.

    Oracle: a persisted done job whose ended_at is past the 24h TTL
    loses both its index entry and its spool dir at startup, while a
    within-TTL done job and a restored (interrupted) job survive.
    """

    def _write_job(self, state_dir, job_id, **meta):
        spool = Path(state_dir) / "jobs" / job_id
        spool.mkdir(parents=True)
        meta.setdefault("id", job_id)
        meta.setdefault("cwd", "/")
        meta.setdefault("cmd", "test")
        meta.setdefault("exit", 0)
        meta.setdefault("state", "done")
        (spool / "meta.json").write_text(json.dumps(meta))
        (spool / "stdout").write_bytes(b"")
        (spool / "stderr").write_bytes(b"")
        return spool

    def test_past_ttl_restored_job_reaped_at_startup(self):
        now = time.time()
        with tempfile.TemporaryDirectory() as state_dir:
            old = self._write_job(state_dir, "old-done",
                                  started_at=now - 26 * 3600,
                                  ended_at=now - 25 * 3600)
            fresh = self._write_job(state_dir, "fresh-done",
                                    started_at=now - 7200,
                                    ended_at=now - 3600)
            running = self._write_job(state_dir, "was-running",
                                      state="running", exit=None,
                                      started_at=now - 26 * 3600,
                                      ended_at=None)
            with tempfile.NamedTemporaryFile("w", delete=False) as f:
                f.write("reaper-test-token\n")
                token_path = f.name
            port = free_port()
            env = dict(os.environ,
                       LAPTOP_AGENT_TOKEN_FILE=token_path,
                       LAPTOP_AGENT_HOST="127.0.0.1",
                       LAPTOP_AGENT_PORT=str(port),
                       LAPTOP_AGENT_STATE=state_dir)
            proc = subprocess.Popen([sys.executable, str(AGENT)], env=env,
                                    stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE)
            try:
                req = urllib.request.Request(
                    f"http://127.0.0.1:{port}/jobs",
                    headers={"X-Agent-Token": "reaper-test-token"})
                deadline = time.time() + 15
                jobs = None
                while time.time() < deadline:
                    try:
                        with urllib.request.urlopen(req, timeout=2) as r:
                            jobs = json.loads(r.read())["jobs"]
                        break
                    except (urllib.error.URLError, ConnectionError):
                        time.sleep(0.1)
                else:
                    self.fail("agent did not start")
                ids = {j["job_id"] for j in jobs}
                self.assertEqual(ids, {"fresh-done", "was-running"})
                self.assertFalse(old.exists())
                self.assertTrue(fresh.exists())
                self.assertTrue(running.exists())
            finally:
                proc.terminate()
                proc.wait(timeout=10)
                os.unlink(token_path)

    def test_unsafe_persisted_ids_do_not_escape_jobs_at_startup(self):
        now = time.time()
        with tempfile.TemporaryDirectory() as state_dir:
            state = Path(state_dir)
            bad_parent = self._write_job(
                state_dir, "bad-parent", id="..", started_at=now - 26 * 3600,
                ended_at=now - 25 * 3600)
            bad_separator = self._write_job(
                state_dir, "bad-separator", id="a/b",
                started_at=now - 26 * 3600, ended_at=now - 25 * 3600)
            cross_job = self._write_job(
                state_dir, "cross-job", id="healthy",
                started_at=now - 26 * 3600, ended_at=now - 25 * 3600)
            healthy = self._write_job(
                state_dir, "healthy", started_at=now - 3600,
                ended_at=now - 1800)
            sentinel = state / "keep-me"
            sentinel.write_text("state outside jobs must survive")

            with tempfile.NamedTemporaryFile("w", delete=False) as f:
                f.write("reaper-test-token\n")
                token_path = f.name
            port = free_port()
            env = dict(os.environ,
                       LAPTOP_AGENT_TOKEN_FILE=token_path,
                       LAPTOP_AGENT_HOST="127.0.0.1",
                       LAPTOP_AGENT_PORT=str(port),
                       LAPTOP_AGENT_STATE=state_dir)
            proc = subprocess.Popen([sys.executable, str(AGENT)], env=env,
                                    stdout=subprocess.DEVNULL,
                                    stderr=subprocess.DEVNULL)
            try:
                req = urllib.request.Request(
                    f"http://127.0.0.1:{port}/jobs",
                    headers={"X-Agent-Token": "reaper-test-token"})
                deadline = time.time() + 15
                jobs = None
                while time.time() < deadline:
                    try:
                        with urllib.request.urlopen(req, timeout=2) as r:
                            jobs = json.loads(r.read())["jobs"]
                        break
                    except (urllib.error.URLError, ConnectionError):
                        time.sleep(0.1)
                else:
                    self.fail("agent did not start")

                self.assertEqual({j["job_id"] for j in jobs}, {"healthy"})
                self.assertEqual(jobs[0]["cmd"], "test")
                self.assertTrue(sentinel.exists())
                self.assertTrue(healthy.exists())
                self.assertTrue(bad_parent.exists())
                self.assertTrue(bad_separator.exists())
                self.assertTrue(cross_job.exists())
            finally:
                proc.terminate()
                proc.wait(timeout=10)
                os.unlink(token_path)


if __name__ == "__main__":
    unittest.main()


MAX_EXEC_COMMANDS = int(re.search(
    r"^MAX_EXEC_COMMANDS = (\d+)", AGENT.read_text(), re.M).group(1))


class ExecBatchBoundsTest(unittest.TestCase):
    """Issue #1842: one POST /exec batch must not hold a SEMA slot for
    an unbounded aggregate duration.

    Oracle: a batch of exactly MAX_EXEC_COMMANDS runs to completion; a
    batch one command larger is rejected 400 before any command runs
    or any slot is taken; and a batch whose early command consumes the
    shared timeout budget reports the later commands as batch-deadline
    timeouts without launching them.
    """

    def setUp(self):
        self.token = "<MASKED_SECRET_002>"
        with tempfile.NamedTemporaryFile("w", delete=False) as f:
            f.write(self.token + "\n")
            self.token_path = f.name
        self.port = free_port()
        self.state = tempfile.mkdtemp()
        env = dict(os.environ,
                   LAPTOP_AGENT_TOKEN_FILE=self.token_path,
                   LAPTOP_AGENT_HOST="127.0.0.1",
                   LAPTOP_AGENT_PORT=str(self.port),
                   LAPTOP_AGENT_STATE=self.state)
        self.proc = subprocess.Popen([sys.executable, str(AGENT)], env=env,
                                     stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE)
        deadline = time.time() + 10
        while time.time() < deadline:
            try:
                status, body = self._call("GET", "/health")
                if status == 200 and body.get("ok"):
                    return
            except Exception:
                time.sleep(0.1)
        self.tearDown()
        self.fail("agent did not start")

    def tearDown(self):
        self.proc.terminate()
        self.proc.wait(timeout=10)
        os.unlink(self.token_path)

    def _call(self, method, path, body=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.port,
                                          timeout=60)
        try:
            conn.request(method, path,
                         body=json.dumps(body).encode()
                         if body is not None else None,
                         headers={"X-Agent-Token": self.token,
                                  "Content-Type": "application/json"})
            resp = conn.getresponse()
            return resp.status, json.loads(resp.read().decode())
        finally:
            conn.close()

    @staticmethod
    def _pass_cmd():
        return {"argv": [sys.executable, "-c", "pass"]}

    def test_batch_at_max_commands_is_accepted(self):
        status, body = self._call(
            "POST", "/exec",
            body={"cmds": [self._pass_cmd()
                           for _ in range(MAX_EXEC_COMMANDS)],
                  "timeout_s": 120})
        self.assertEqual(status, 200, body)
        self.assertEqual(len(body["results"]), MAX_EXEC_COMMANDS)
        self.assertTrue(all(r["exit"] == 0 for r in body["results"]))

    def test_batch_one_over_max_is_rejected_and_runs_nothing(self):
        marker = os.path.join(self.state, "oversized-ran")
        cmds = [self._pass_cmd() for _ in range(MAX_EXEC_COMMANDS)]
        cmds.append({"argv": [sys.executable, "-c",
                              f"open({marker!r}, 'w').write('x')"]})
        status, body = self._call("POST", "/exec",
                                  body={"cmds": cmds, "timeout_s": 120})
        self.assertEqual(status, 400, body)
        self.assertIn("MAX_EXEC_COMMANDS", body.get("error", ""))
        self.assertFalse(os.path.exists(marker))
        # The rejection took no slot: an ordinary request still works.
        status, body = self._call("POST", "/exec",
                                  body={"cmds": [self._pass_cmd()]})
        self.assertEqual(status, 200, body)
        self.assertEqual(body["results"][0]["exit"], 0)

    def test_aggregate_deadline_stops_later_commands(self):
        marker = os.path.join(self.state, "after-deadline-ran")
        cmds = [
            {"argv": [sys.executable, "-c", "import time; time.sleep(5)"]},
            {"argv": [sys.executable, "-c",
                      f"open({marker!r}, 'w').write('x')"]},
        ]
        status, body = self._call("POST", "/exec",
                                  body={"cmds": cmds, "timeout_s": 1})
        self.assertEqual(status, 200, body)
        first, second = body["results"]
        self.assertTrue(first.get("timeout"), first)
        self.assertIsNone(first["exit"])
        self.assertEqual(second.get("error"), "batch deadline exceeded")
        self.assertTrue(second.get("timeout"), second)
        self.assertFalse(os.path.exists(marker))


class WriteMetaFailureTest(unittest.TestCase):
    """Issue #2037: _write_meta swallowed every OSError from the
    meta.json write, so a failed final (done) write left the last
    successful state -- "running" -- on disk, and the job restored
    after restart as interrupted with exit null, with no stderr line.

    Oracle: a transiently failing final write is retried and lands,
    so the restored job keeps its real exit instead of a fabricated
    interrupted/exit-null; a persistently failing write reports
    exactly one stderr line naming the job id (matching the job_dir
    branch) and leaves the on-disk meta untouched. The restore
    contract (#1578) is unchanged: an entry that is still "running"
    on disk restores as interrupted, which is now a visible failure
    rather than a silent one.
    """

    def _import_agent(self):
        with tempfile.NamedTemporaryFile("w", suffix="-token",
                                         delete=False) as f:
            f.write("write-meta-test-token\n")
            token_path = f.name
        os.environ.setdefault("LAPTOP_AGENT_TOKEN_FILE", token_path)
        sys.path.insert(0, str(AGENT.parent))
        import laptop_agent as la
        return la

    def _write_job(self, state_dir, job_id, **meta):
        spool = Path(state_dir) / "jobs" / job_id
        spool.mkdir(parents=True)
        meta.setdefault("id", job_id)
        meta.setdefault("cwd", "/")
        meta.setdefault("cmd", "test")
        meta.setdefault("exit", 0)
        meta.setdefault("state", "done")
        (spool / "meta.json").write_text(json.dumps(meta))
        (spool / "stdout").write_bytes(b"")
        (spool / "stderr").write_bytes(b"")
        return spool

    def _done_job(self, job_id, now):
        return {"id": job_id, "proc": None, "cwd": "/", "cmd_repr": "test",
                "started_at": now - 10.0, "ended_at": now, "exit": 0,
                "state": "done", "interrupted": False, "_files": ()}

    def tearDown(self):
        la_mod = sys.modules.get("laptop_agent")
        if la_mod is not None:
            la_mod.JOBS.clear()

    def test_transient_write_failure_retried_real_exit_restored(self):
        la = self._import_agent()
        with tempfile.TemporaryDirectory() as state_dir:
            job_id = "write-retry-job"
            now = time.time()
            # The last successful write left the job "running" on disk.
            self._write_job(state_dir, job_id, state="running",
                            exit=None, started_at=now - 10.0,
                            ended_at=None)
            orig_write_text = Path.write_text
            calls = {"n": 0}

            def flaky_write_text(self, data, *args, **kwargs):
                calls["n"] += 1
                if calls["n"] == 1:
                    raise OSError(errno.ENOSPC,
                                  "No space left on device")
                return orig_write_text(self, data, *args, **kwargs)

            err = io.StringIO()
            with patch.object(la, "STATE_DIR", Path(state_dir)):
                with contextlib.redirect_stderr(err):
                    with patch.object(Path, "write_text",
                                      flaky_write_text):
                        la._write_meta(self._done_job(job_id, now))
            # The retry landed: no failure line, and the on-disk meta
            # is the finished job, not the stale running one.
            self.assertEqual(err.getvalue(), "")
            self.assertEqual(calls["n"], 2)
            on_disk = json.loads(
                (Path(state_dir) / "jobs" / job_id
                 / "meta.json").read_text())
            self.assertEqual(on_disk["state"], "done")
            self.assertEqual(on_disk["exit"], 0)
            # After a restart the job restores with its real exit --
            # not the fabricated interrupted/exit-null of #2037.
            la.JOBS.clear()
            err = io.StringIO()
            with patch.object(la, "STATE_DIR", Path(state_dir)):
                with contextlib.redirect_stderr(err):
                    la.load_persisted_jobs()
            self.assertEqual(err.getvalue(), "")
            job = la.JOBS[job_id]
            self.assertEqual(job["state"], "done")
            self.assertEqual(job["exit"], 0)
            self.assertFalse(job["interrupted"])
            self.assertEqual(la.job_public(job)["exit"], 0)

    def test_persistent_write_failure_logs_one_line_naming_job(self):
        la = self._import_agent()
        with tempfile.TemporaryDirectory() as state_dir:
            job_id = "write-fail-job"
            now = time.time()
            spool = self._write_job(state_dir, job_id, state="running",
                                    exit=None, started_at=now - 10.0,
                                    ended_at=None)
            before = (spool / "meta.json").read_text()

            def failing_write_text(self, data, *args, **kwargs):
                raise OSError(errno.ENOSPC, "No space left on device")

            err = io.StringIO()
            with patch.object(la, "STATE_DIR", Path(state_dir)):
                with contextlib.redirect_stderr(err):
                    with patch.object(Path, "write_text",
                                      failing_write_text):
                        la._write_meta(self._done_job(job_id, now))
            lines = [ln for ln in err.getvalue().splitlines()
                     if ln.strip()]
            self.assertEqual(len(lines), 1, err.getvalue())
            self.assertIn(job_id, lines[0])
            self.assertIn("cannot write meta", lines[0])
            # The failed write changed nothing on disk.
            self.assertEqual((spool / "meta.json").read_text(), before)
            # The #1578 restore contract is unchanged for an entry
            # that is still "running" on disk: it restores as
            # interrupted -- now with the failure visible on stderr
            # instead of silent.
            la.JOBS.clear()
            err = io.StringIO()
            with patch.object(la, "STATE_DIR", Path(state_dir)):
                with contextlib.redirect_stderr(err):
                    la.load_persisted_jobs()
            self.assertEqual(err.getvalue(), "")
            job = la.JOBS[job_id]
            self.assertTrue(job["interrupted"])
            self.assertIsNone(job["exit"])
