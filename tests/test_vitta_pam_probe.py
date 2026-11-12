"""Unit tests for tests/smoke/pam_probe.py that need neither root nor a PAM service.

The smoke gates run the probe for real against the image's greetd stack.
"""

import contextlib
import ctypes
import ctypes.util
import importlib.util
from importlib.machinery import SourceFileLoader
import io
from pathlib import Path
import subprocess
import sys
import time
import unittest


sys.dont_write_bytecode = True
PROBE = Path(__file__).resolve().parent / "smoke/pam_probe.py"


def load_probe():
    loader = SourceFileLoader("pam_probe", str(PROBE))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class PamProbeArgumentTests(unittest.TestCase):
    def setUp(self):
        self.probe = load_probe()

    def test_parses_the_gate_interface(self):
        args = self.probe.parse_args(
            ["greetd", "vittaprobe", "", "--expect", "fail", "--max-seconds", "10"]
        )
        self.assertEqual((args.service, args.user, args.password), ("greetd", "vittaprobe", ""))
        self.assertEqual((args.expect, args.max_seconds), ("fail", 10.0))
        self.assertEqual((args.expect_message, args.forbid_message), ([], []))

    def test_expect_and_max_seconds_are_required_and_checked(self):
        for argv in (
            ["greetd", "u", "p", "--max-seconds", "5"],
            ["greetd", "u", "p", "--expect", "success"],
            ["greetd", "u", "p", "--expect", "maybe", "--max-seconds", "5"],
            ["greetd", "u", "p", "--expect", "success", "--max-seconds", "0"],
        ):
            with self.subTest(argv=argv), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as raised:
                    self.probe.parse_args(argv)
                self.assertEqual(raised.exception.code, 2)


class PamProbeVerdictTests(unittest.TestCase):
    NOTICE = "notice"

    def setUp(self):
        self.probe = load_probe()
        self.info = self.probe.PAM_TEXT_INFO
        self.prompt = self.probe.PAM_PROMPT_ECHO_OFF

    def verdict(self, code, elapsed, messages, expect="fail", max_seconds=10, expect_messages=(), forbid_messages=(), conversation_errors=()):
        return self.probe.verdict(
            code=code,
            elapsed=elapsed,
            messages=messages,
            expect=expect,
            max_seconds=max_seconds,
            expect_messages=list(expect_messages),
            forbid_messages=list(forbid_messages),
            conversation_errors=list(conversation_errors),
        )

    def test_correct_password_passes(self):
        ok, reason = self.verdict(0, 0.1, [(self.prompt, "Password: ")], "success", 5)
        self.assertTrue(ok, reason)

    def test_success_carrying_a_forbidden_message_fails(self):
        ok, reason = self.verdict(0, 0.1, [(self.prompt, "Password: "), (self.info, self.NOTICE)], "success", 5, forbid_messages=[self.NOTICE])
        self.assertFalse(ok)
        self.assertIn("forbidden message", reason)

    def test_refusal_with_expected_message_passes(self):
        ok, reason = self.verdict(7, 2.1, [(self.prompt, "Password: "), (self.info, self.NOTICE)], expect_messages=[self.NOTICE])
        self.assertTrue(ok, reason)

    def test_refusal_without_expected_message_fails(self):
        ok, reason = self.verdict(7, 2.1, [(self.prompt, "Password: ")], expect_messages=[self.NOTICE])
        self.assertFalse(ok)
        self.assertIn("missing message", reason)

    def test_expected_message_must_match_exactly(self):
        ok, _ = self.verdict(7, 2.1, [(self.info, self.NOTICE + " ")], expect_messages=[self.NOTICE])
        self.assertFalse(ok)

    def test_wrong_result_fails_both_ways(self):
        ok, reason = self.verdict(0, 0.1, [], expect="fail")
        self.assertFalse(ok)
        self.assertIn("expected fail", reason)
        ok, reason = self.verdict(7, 0.1, [], expect="success")
        self.assertFalse(ok)
        self.assertIn("expected success", reason)

    def test_slow_conversation_fails_even_with_right_result(self):
        ok, reason = self.verdict(7, 10.5, [(self.info, self.NOTICE)], max_seconds=10, expect_messages=[self.NOTICE])
        self.assertFalse(ok)
        self.assertIn("10.5", reason)

    def test_conversation_error_fails_whatever_pam_returned(self):
        ok, reason = self.verdict(7, 0.1, [], conversation_errors=["RuntimeError"])
        self.assertFalse(ok)
        self.assertIn("conversation", reason)
        ok, _ = self.verdict(0, 0.1, [], expect="success", conversation_errors=["RuntimeError"])
        self.assertFalse(ok)


class PamProbeConversationTests(unittest.TestCase):
    """Drive the pam_conv callback with ctypes structures, as libpam would."""

    def setUp(self):
        self.probe = load_probe()
        self.libc = ctypes.CDLL(ctypes.util.find_library("c"))
        self.libc.free.argtypes = [ctypes.c_void_p]

    def call(self, conversation, styled):
        messages = [self.probe.PamMessage(style, text.encode()) for style, text in styled]
        pointers = (ctypes.POINTER(self.probe.PamMessage) * len(messages))(*[ctypes.pointer(m) for m in messages])
        response = ctypes.POINTER(self.probe.PamResponse)()
        rc = conversation.callback(len(messages), pointers, ctypes.pointer(response), None)
        return rc, response

    def test_prompts_get_the_password_and_messages_are_recorded(self):
        conversation = self.probe.Conversation("s3cret", self.libc)
        styled = [
            (self.probe.PAM_PROMPT_ECHO_OFF, "Password: "),
            (self.probe.PAM_TEXT_INFO, "notice"),
            (self.probe.PAM_ERROR_MSG, "boom"),
            (self.probe.PAM_PROMPT_ECHO_ON, "Login: "),
        ]
        with contextlib.redirect_stdout(io.StringIO()) as out:
            rc, response = self.call(conversation, styled)
        self.assertEqual(rc, self.probe.PAM_SUCCESS)
        self.assertEqual(conversation.messages, styled)
        self.assertEqual(ctypes.string_at(response[0].resp), b"s3cret")
        self.assertIsNone(response[1].resp)
        self.assertIsNone(response[2].resp)
        self.assertEqual(ctypes.string_at(response[3].resp), b"s3cret")
        self.assertNotIn("s3cret", out.getvalue())
        self.assertIn("[text-info] notice", out.getvalue())
        for index in range(len(styled)):
            self.libc.free(response[index].resp)
        self.libc.free(ctypes.cast(response, ctypes.c_void_p))

    def test_empty_password_answers_with_an_empty_string(self):
        conversation = self.probe.Conversation("", self.libc)
        with contextlib.redirect_stdout(io.StringIO()):
            rc, response = self.call(conversation, [(self.probe.PAM_PROMPT_ECHO_OFF, "Password: ")])
        self.assertEqual(rc, self.probe.PAM_SUCCESS)
        self.assertIsNotNone(response[0].resp, "empty answer is a string, not NULL")
        self.assertEqual(ctypes.string_at(response[0].resp), b"")
        self.libc.free(response[0].resp)
        self.libc.free(ctypes.cast(response, ctypes.c_void_p))


class FakePam:
    """Stands in for libpam: pam_authenticate drives the real conversation callback."""

    def __init__(self, probe, libc, result, styled):
        self.probe, self.libc, self.result, self.styled = probe, libc, result, styled

    def pam_start(self, service, user, conv_ref, handle_ref):
        self.conv = conv_ref._obj
        return self.probe.PAM_SUCCESS

    def pam_authenticate(self, handle, flags):
        probe = self.probe
        messages = [probe.PamMessage(style, text.encode()) for style, text in self.styled]
        pointers = (ctypes.POINTER(probe.PamMessage) * len(messages))(*[ctypes.pointer(m) for m in messages])
        response = ctypes.POINTER(probe.PamResponse)()
        # Through the C trampoline, as libpam calls it: an escaping exception would read as 0.
        rc = self.conv.conv(len(messages), pointers, ctypes.pointer(response), None)
        if rc != probe.PAM_SUCCESS:
            return 7
        if response:
            for index in range(len(messages)):
                self.libc.free(response[index].resp)
            self.libc.free(ctypes.cast(response, ctypes.c_void_p))
        return self.result

    def pam_end(self, handle, code):
        return self.probe.PAM_SUCCESS

    def pam_strerror(self, handle, code):
        return b"fake"


class RaisingStrdup:
    """A strdup stand-in that raises; it accepts restype/argtypes like a ctypes function."""

    def __call__(self, _value):
        raise RuntimeError("boom")


class RaisingLibc:
    """Real libc, except strdup raises inside the callback."""

    def __init__(self, libc):
        self.calloc, self.free = libc.calloc, libc.free
        self.strdup = RaisingStrdup()


class PamProbeMainTests(unittest.TestCase):
    PASSWORD = "s3cret-Pw"

    def setUp(self):
        self.probe = load_probe()
        self.libc = ctypes.CDLL(ctypes.util.find_library("c"))
        self.libc.free.argtypes = [ctypes.c_void_p]
        self.prompt = [(self.probe.PAM_PROMPT_ECHO_OFF, "Password: "), (self.probe.PAM_TEXT_INFO, "notice")]

    def run_main(self, result, expect, libc=None):
        conv_libc = libc or self.libc
        self.probe.load_libraries = lambda: (FakePam(self.probe, self.libc, result, self.prompt), conv_libc)
        with contextlib.redirect_stdout(io.StringIO()) as out:
            rc = self.probe.main(["greetd", "u", self.PASSWORD, "--expect", expect, "--max-seconds", "5"])
        return rc, out.getvalue()

    def test_output_never_contains_the_password(self):
        # F4: real check over everything main prints, for passing and failing verdicts.
        for result in (0, 7):
            for expect in ("success", "fail"):
                with self.subTest(result=result, expect=expect):
                    rc, output = self.run_main(result, expect)
                    self.assertEqual(rc, 0 if (result == 0) == (expect == "success") else 1)
                    self.assertIn("notice", output)
                    self.assertNotIn(self.PASSWORD, output)

    def test_raising_callback_returns_conv_err_and_never_reports_success(self):
        # F3: an exception escaping a ctypes callback returns 0, which libpam reads as success.
        conversation = self.probe.Conversation(self.PASSWORD, RaisingLibc(self.libc))
        messages = [self.probe.PamMessage(self.probe.PAM_PROMPT_ECHO_OFF, b"Password: ")]
        pointers = (ctypes.POINTER(self.probe.PamMessage) * 1)(ctypes.pointer(messages[0]))
        response = ctypes.POINTER(self.probe.PamResponse)()
        with contextlib.redirect_stdout(io.StringIO()) as out:
            rc = conversation.callback(1, pointers, ctypes.pointer(response), None)
        self.assertEqual(rc, self.probe.PAM_CONV_ERR)
        self.assertFalse(response, "no response array is handed to libpam on error")
        self.assertEqual(conversation.errors, ["RuntimeError"])
        self.assertNotIn(self.PASSWORD, out.getvalue())
        for expect in ("success", "fail"):
            with self.subTest(expect=expect):
                rc, output = self.run_main(0, expect, libc=RaisingLibc(self.libc))
                self.assertEqual(rc, 1)
                self.assertIn("FAIL: conversation callback failed", output)
                self.assertNotIn(self.PASSWORD, output)

    def test_hard_stop_when_pam_never_returns(self):
        # F2/R41: the bound holds even if pam_authenticate blocks; the probe exits non-zero
        # with one FAIL line within --max-seconds plus the grace.
        script = (
            "import sys, time\n"
            f"sys.path.insert(0, {str(PROBE.parent)!r})\n"
            "import pam_probe as probe\n"
            "class Stuck:\n"
            "    def pam_start(self, *a): return 0\n"
            "    def pam_authenticate(self, *a): time.sleep(60); return 0\n"
            "    def pam_end(self, *a): return 0\n"
            "    def pam_strerror(self, *a): return b'x'\n"
            "import ctypes, ctypes.util\n"
            "probe.load_libraries = lambda: (Stuck(), ctypes.CDLL(ctypes.util.find_library('c')))\n"
            "sys.exit(probe.main(['greetd', 'u', 'pw', '--expect', 'success', '--max-seconds', '0.5']))\n"
        )
        started = time.monotonic()
        done = subprocess.run([sys.executable, "-B", "-W", "ignore", "-c", script], capture_output=True, text=True, timeout=30)
        elapsed = time.monotonic() - started
        self.assertNotEqual(done.returncode, 0)
        self.assertLess(elapsed, 0.5 + self.probe.HARD_STOP_GRACE + 3)
        self.assertRegex(done.stdout, r"(?m)^FAIL: .*did not return")
        self.assertEqual(done.stderr, "")


if __name__ == "__main__":
    unittest.main()
