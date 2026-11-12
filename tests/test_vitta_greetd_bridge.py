"""End-to-end tests for the Vitta greetd bridge and its scripted fake."""

import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import select
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import unittest


sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
BRIDGE = ROOT / "files/vitta/usr/libexec/vitta/vitta-greetd-bridge"
FAKE = ROOT / "tests/smoke/fake_greetd.py"


def load_bridge_module():
    loader = importlib.machinery.SourceFileLoader("vitta_greetd_bridge", str(BRIDGE))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def cpu_seconds(process):
    fields = Path(f"/proc/{process.pid}/stat").read_text().split()
    return (int(fields[13]) + int(fields[14])) / os.sysconf("SC_CLK_TCK")


def read_line(stream, timeout=2):
    """Read one newline-delimited byte string without letting a test hang."""
    deadline = time.monotonic() + timeout
    buffered = getattr(stream, "_vitta_buffer", b"")
    while b"\n" not in buffered:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise AssertionError("timed out waiting for a line")
        ready, _, _ = select.select([stream], [], [], remaining)
        if not ready:
            raise AssertionError("timed out waiting for a line")
        chunk = os.read(stream.fileno(), 4096)
        if not chunk:
            raise AssertionError("stream closed before a line arrived")
        buffered += chunk
    line, buffered = buffered.split(b"\n", 1)
    stream._vitta_buffer = buffered
    return line


class VittaGreetdBridgeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(dir="/tmp"))
        self.socket_path = self.tmp / "g.sock"
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.server = None
        self.bridge = None

    def addCleanupProcess(self, attribute):
        def cleanup():
            process = getattr(self, attribute)
            if process is None:
                return
            if process.stdin:
                process.stdin.close()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=2)
            for stream in (process.stdout, process.stderr):
                if stream:
                    stream.close()
        self.addCleanup(cleanup)

    def start_server(self, script="ok", password_file=None):
        command = [sys.executable, "-B", str(FAKE), "--socket", str(self.socket_path), "--script", script, "--timeout", "8"]
        if password_file is not None:
            command.extend(["--password-file", str(password_file)])
        self.server = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.addCleanupProcess("server")
        self.assertEqual(read_line(self.server.stdout), b"READY")

    def start_bridge(self, socket_path=None, timeout=None):
        env = os.environ.copy()
        if socket_path is None:
            env["GREETD_SOCK"] = str(self.socket_path)
        elif socket_path is False:
            env.pop("GREETD_SOCK", None)
        else:
            env["GREETD_SOCK"] = str(socket_path)
        if timeout is not None:
            env["VITTA_GREETD_BRIDGE_TIMEOUT"] = str(timeout)
        self.bridge = subprocess.Popen(
            [str(BRIDGE)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env
        )
        self.addCleanupProcess("bridge")

    def request(self, request):
        self.bridge.stdin.write(json.dumps(request, ensure_ascii=False, separators=(",", ":")).encode() + b"\n")
        self.bridge.stdin.flush()
        return json.loads(read_line(self.bridge.stdout))

    def log(self):
        log = Path(f"{self.socket_path}.log")
        return [json.loads(line) for line in log.read_text().splitlines()]

    def wait_for_log_count(self, count):
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            if len(self.log()) >= count:
                return
            time.sleep(0.01)
        self.fail("timed out waiting for fake greetd log")

    def close_bridge(self):
        self.bridge.stdin.close()
        self.assertEqual(self.bridge.wait(timeout=2), 0)
        return self.bridge.stderr.read().decode()

    def authenticate(self, password="right"):
        prompt = self.request({"type": "create_session", "username": "dimitri"})
        self.assertEqual((prompt["type"], prompt["auth_message_type"]), ("auth_message", "secret"))
        return self.request({"type": "post_auth_message_response", "response": password})

    def test_ok_roundtrip(self):
        self.start_server()
        self.start_bridge()
        self.assertEqual(self.authenticate(), {"type": "success"})
        self.assertEqual(self.request({"type": "start_session", "cmd": ["niri-session"], "env": []}), {"type": "success"})
        self.assertEqual(len(self.log()), 3)
        self.assertEqual(self.close_bridge(), "")

    def test_split_replies_are_delivered_whole(self):
        self.start_server("split")
        self.start_bridge()
        self.assertEqual(self.authenticate(), {"type": "success"})
        self.assertEqual(self.request({"type": "start_session", "cmd": ["niri-session"], "env": []}), {"type": "success"})
        self.assertEqual(self.close_bridge(), "")

    def test_merged_replies_are_delivered_one_per_line(self):
        self.start_server("merged")
        self.start_bridge()
        prompt = self.request({"type": "create_session", "username": "dimitri"})
        self.assertEqual((prompt["type"], prompt["auth_message_type"]), ("auth_message", "secret"))
        with self.assertRaises(AssertionError):
            read_line(self.bridge.stdout, timeout=0.5)
        self.assertEqual(self.request({"type": "post_auth_message_response", "response": "right"}), {"type": "success"})
        self.assertEqual(self.close_bridge(), "")

    def test_badpass_then_cancel(self):
        self.start_server("badpass")
        self.start_bridge()
        reply = self.authenticate("wrong")
        self.assertEqual((reply["type"], reply["error_type"]), ("error", "auth_error"))
        self.assertEqual(self.request({"type": "cancel_session"}), {"type": "success"})
        self.assertEqual(self.close_bridge(), "")

    def test_special_characters_reach_greetd_unchanged(self):
        username = 'a"b\\c é'
        password = 'p"\\\n ü'
        password_file = self.tmp / "password"
        password_file.write_text(password)
        self.start_server(password_file=password_file)
        self.start_bridge()
        self.assertEqual(self.request({"type": "create_session", "username": username})["type"], "auth_message")
        self.assertEqual(self.request({"type": "post_auth_message_response", "response": password}), {"type": "success"})
        logged = self.log()
        self.assertTrue(logged[0]["username"] == username, "username changed")
        self.assertEqual(logged[1]["response_len"], len(password))
        self.assertTrue(logged[1]["response_ok"])
        self.assertEqual(self.close_bridge(), "")

    def test_greetd_closes_socket(self):
        self.start_server("died")
        self.start_bridge()
        self.assertEqual(self.authenticate()["type"], "error")
        self.assertEqual(self.bridge.wait(timeout=2), 1)
        self.assertEqual(self.bridge.stderr.read().decode(), "")

    def test_no_socket(self):
        self.start_bridge(socket_path=False)
        reply = json.loads(read_line(self.bridge.stdout))
        self.assertEqual((reply["type"], reply["error_type"]), ("error", "bridge"))
        self.assertEqual(self.bridge.wait(timeout=2), 1)
        self.assertEqual(self.bridge.stderr.read().decode(), "")

    def test_bad_input_line_is_refused_not_forwarded(self):
        self.start_server()
        self.start_bridge()
        self.bridge.stdin.write(b"not json\n")
        self.bridge.stdin.flush()
        reply = json.loads(read_line(self.bridge.stdout))
        self.assertEqual((reply["type"], reply["error_type"]), ("error", "bridge"))
        self.assertEqual(self.log(), [])
        self.assertEqual(self.request({"type": "create_session", "username": "dimitri"})["type"], "auth_message")
        self.assertEqual(self.close_bridge(), "")

    def test_password_never_leaves_through_stderr_or_argv(self):
        password = "private-password"
        self.start_server()
        self.start_bridge()
        self.assertEqual(self.authenticate(password)["error_type"], "auth_error")
        self.assertEqual(self.bridge.args, [str(BRIDGE)])
        self.bridge.stdin.close()
        self.assertEqual(self.bridge.wait(timeout=2), 0)
        self.assertFalse(password in self.bridge.stderr.read().decode(), "password leaked")

    def test_take_frame_handles_partial_and_merged_frames(self):
        bridge = load_bridge_module()
        first = b'{"text":"caf\xc3\xa9"}'
        second = b'{"type":"success"}'
        buffer = bytearray()
        for byte in struct.pack("=I", len(first)) + first:
            buffer.append(byte)
            if len(buffer) < 4 + len(first):
                self.assertIsNone(bridge.take_frame(buffer))
        self.assertEqual(bridge.take_frame(buffer), first)
        self.assertEqual(buffer, bytearray())

        buffer.extend(struct.pack("=I", len(first)) + first + struct.pack("=I", len(second)) + second)
        self.assertEqual(bridge.take_frame(buffer), first)
        self.assertEqual(bridge.take_frame(buffer), second)
        self.assertIsNone(bridge.take_frame(buffer))

        buffer.extend(struct.pack("=I", bridge.MAX_REPLY + 1))
        with self.assertRaises(ValueError):
            bridge.take_frame(buffer)

    def test_idle_helper_does_not_spin(self):
        self.start_server()
        self.start_bridge()
        before = cpu_seconds(self.bridge)
        time.sleep(1)
        used = cpu_seconds(self.bridge) - before
        self.assertTrue(used < 0.2, f"CPU seconds: {used:.3f}")
        self.assertEqual(self.close_bridge(), "")

    def test_stalled_partial_reply_does_not_spin(self):
        self.start_server("partial-stall")
        self.start_bridge(timeout=2)
        self.bridge.stdin.write(b'{"type":"create_session"}\n')
        self.bridge.stdin.flush()
        self.wait_for_log_count(1)
        before = cpu_seconds(self.bridge)
        time.sleep(1.5)
        used = cpu_seconds(self.bridge) - before
        self.assertTrue(used < 0.3, f"CPU seconds: {used:.3f}")
        reply = json.loads(read_line(self.bridge.stdout, timeout=2))
        self.assertEqual(reply, {"type": "error", "error_type": "bridge", "description": "greetd did not answer in time"})
        self.assertEqual(self.bridge.wait(timeout=2), 1)
        self.assertEqual(self.bridge.stderr.read().decode(), "")

    def test_silent_greetd_times_out(self):
        self.start_server("silent")
        self.start_bridge(timeout=1)
        self.bridge.stdin.write(b'{"type":"create_session"}\n')
        self.bridge.stdin.flush()
        reply = json.loads(read_line(self.bridge.stdout, timeout=3))
        self.assertEqual(reply, {"type": "error", "error_type": "bridge", "description": "greetd did not answer in time"})
        self.assertEqual(self.bridge.wait(timeout=2), 1)
        self.assertEqual(self.bridge.stderr.read().decode(), "")

    def test_stdin_eof_while_greetd_is_silent_exits_quietly(self):
        self.start_server("silent")
        self.start_bridge()
        self.bridge.stdin.write(b'{"type":"create_session"}\n')
        self.bridge.stdin.flush()
        self.wait_for_log_count(1)
        self.bridge.stdin.close()
        self.assertEqual(self.bridge.wait(timeout=2), 0)
        self.assertEqual(self.bridge.stdout.read(), b"")
        self.assertEqual(self.bridge.stderr.read().decode(), "")

    def test_queued_request_then_stdin_eof_exits_at_once(self):
        self.start_server("silent")
        self.start_bridge()
        self.bridge.stdin.write(b'{"type":"create_session"}\n')
        self.bridge.stdin.flush()
        self.wait_for_log_count(1)
        self.bridge.stdin.write(b'{"type":"start_session"}\n')
        self.bridge.stdin.close()
        self.assertEqual(self.bridge.wait(timeout=2), 0)
        self.assertEqual(self.bridge.stdout.read(), b"")
        self.assertEqual(self.bridge.stderr.read().decode(), "")

    def test_stdin_eof_after_complete_requests_keeps_their_replies(self):
        self.start_server()
        self.start_bridge()
        self.bridge.stdin.write(b'{"type":"create_session"}\n{"type":"start_session"}\n')
        self.bridge.stdin.close()
        self.assertEqual(json.loads(read_line(self.bridge.stdout))["type"], "auth_message")
        self.assertEqual(json.loads(read_line(self.bridge.stdout)), {"type": "success"})
        self.assertEqual(self.bridge.wait(timeout=2), 0)
        self.assertEqual(self.bridge.stderr.read().decode(), "")

    def test_second_request_is_not_forwarded_before_first_reply(self):
        self.start_server("probe-early")
        self.start_bridge()
        self.bridge.stdin.write(b'{"type":"create_session"}\n{"type":"start_session"}\n')
        self.bridge.stdin.flush()
        self.assertEqual(json.loads(read_line(self.bridge.stdout))["type"], "auth_message")
        self.wait_for_log_count(2)
        self.assertEqual(self.log()[1], {"probe_early_bytes": False})
        self.assertEqual(json.loads(read_line(self.bridge.stdout)), {"type": "success"})
        self.assertEqual([entry["type"] for entry in self.log() if "type" in entry], ["create_session", "start_session"])
        self.assertEqual(self.close_bridge(), "")

    def test_lone_surrogate_input_is_refused_and_next_request_works(self):
        self.start_server()
        self.start_bridge()
        self.bridge.stdin.write(b'{"type":"create_session","username":"\\ud800"}\n')
        self.bridge.stdin.flush()
        reply = json.loads(read_line(self.bridge.stdout))
        self.assertEqual((reply["type"], reply["error_type"]), ("error", "bridge"))
        self.assertEqual(self.log(), [])
        self.assertEqual(self.request({"type": "create_session"})["type"], "auth_message")
        self.assertEqual(self.close_bridge(), "")

    def test_replies_are_ascii_escaped_and_unicode_is_restored(self):
        self.start_server("unicode")
        self.start_bridge()
        self.bridge.stdin.write(b'{"type":"create_session"}\n')
        self.bridge.stdin.flush()
        raw = read_line(self.bridge.stdout)
        self.assertTrue(all(byte < 128 for byte in raw), "reply was not ASCII escaped")
        self.assertEqual(json.loads(raw)["auth_message"], "caf\u00e9 \u00fc \U0001f600")
        self.assertEqual(self.close_bridge(), "")

    def test_lone_surrogate_reply_is_ascii_escaped_without_traceback(self):
        self.start_server("surrogate")
        self.start_bridge()
        self.bridge.stdin.write(b'{"type":"create_session"}\n')
        self.bridge.stdin.flush()
        raw = read_line(self.bridge.stdout)
        self.assertTrue(all(byte < 128 for byte in raw), "reply was not ASCII escaped")
        self.assertEqual(json.loads(raw)["description"], "\ud800")
        self.assertEqual(self.close_bridge(), "")

    def test_long_line_is_discarded_and_next_request_works(self):
        self.start_server()
        self.start_bridge()
        self.bridge.stdin.write(b"{" + b"x" * (70 * 1024) + b"}\n")
        self.bridge.stdin.flush()
        reply = json.loads(read_line(self.bridge.stdout))
        self.assertEqual((reply["type"], reply["error_type"]), ("error", "bridge"))
        self.assertEqual(self.log(), [])
        self.assertEqual(self.request({"type": "create_session"})["type"], "auth_message")
        self.assertEqual(self.close_bridge(), "")

    def test_fake_log_redacts_password(self):
        password = "private-password"
        self.start_server()
        self.start_bridge()
        self.assertEqual(self.authenticate(password)["error_type"], "auth_error")
        raw_log = Path(f"{self.socket_path}.log").read_text()
        self.assertFalse(password in raw_log, "password leaked")
        self.assertTrue("response_len" in raw_log and "response_ok" in raw_log, "redaction fields missing")
        self.assertEqual(self.close_bridge(), "")

    def test_closed_stdout_exits_quietly(self):
        self.start_server()
        self.start_bridge()
        self.bridge.stdout.close()
        self.bridge.stdin.write(b'{"type":"create_session"}\n')
        self.bridge.stdin.flush()
        returncode = self.bridge.wait(timeout=2)
        stderr = self.bridge.stderr.read().decode()
        self.assertEqual(returncode, 0, stderr)
        self.assertEqual(stderr, "")


if __name__ == "__main__":
    unittest.main()
