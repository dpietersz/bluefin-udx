#!/usr/bin/env python3
"""Drive one real PAM authentication and judge its outcome.

    pam_probe.py SERVICE USER PASSWORD --expect success|fail --max-seconds N
                 [--expect-message TEXT] [--forbid-message TEXT]

Runs pam_start -> pam_authenticate -> pam_end against SERVICE with libpam via
ctypes (stdlib only, so it runs inside the image smoke gate). Every prompt,
echo off or on, is answered with PASSWORD; every PAM message is printed with
its style. The password itself is never printed. It only authenticates: no
pam_acct_mgmt, no session.

Exit 0 when all conditions hold: the result matches --expect, the whole
conversation took at most --max-seconds, each --expect-message text arrived
as a message (exact text), no --forbid-message text did and the conversation
callback never failed. Otherwise exit 1 with a one-line reason; 2 for usage
errors, 3 when PAM itself cannot start. If PAM has not returned after
--max-seconds plus HARD_STOP_GRACE, a watchdog thread prints the FAIL line
and ends the process with exit 1 (ctypes releases the GIL during the call, so
the watchdog runs while pam_authenticate blocks in C; signal handlers would
not). The gates also wrap the probe in timeout(1) for a wedged interpreter.
"""

import argparse
import ctypes
import ctypes.util
import os
import sys
import threading
import time

HARD_STOP_GRACE = 2.0

PAM_SUCCESS = 0
PAM_BUF_ERR = 5
PAM_CONV_ERR = 19

PAM_PROMPT_ECHO_OFF = 1
PAM_PROMPT_ECHO_ON = 2
PAM_ERROR_MSG = 3
PAM_TEXT_INFO = 4

STYLE_NAMES = {
    PAM_PROMPT_ECHO_OFF: "prompt-echo-off",
    PAM_PROMPT_ECHO_ON: "prompt-echo-on",
    PAM_ERROR_MSG: "error",
    PAM_TEXT_INFO: "text-info",
}


class PamMessage(ctypes.Structure):
    _fields_ = [("msg_style", ctypes.c_int), ("msg", ctypes.c_char_p)]


class PamResponse(ctypes.Structure):
    # c_void_p, not c_char_p: libpam frees resp, so it must stay the raw
    # pointer from libc strdup instead of a Python-owned bytes object.
    _fields_ = [("resp", ctypes.c_void_p), ("resp_retcode", ctypes.c_int)]


CONV_FUNC = ctypes.CFUNCTYPE(
    ctypes.c_int,
    ctypes.c_int,
    ctypes.POINTER(ctypes.POINTER(PamMessage)),
    ctypes.POINTER(ctypes.POINTER(PamResponse)),
    ctypes.c_void_p,
)


class PamConv(ctypes.Structure):
    _fields_ = [("conv", CONV_FUNC), ("appdata_ptr", ctypes.c_void_p)]


class Conversation:
    """pam_conv callback: answers prompts with the password, records messages."""

    def __init__(self, password, libc):
        self._password = password.encode()
        self._libc = libc
        libc.calloc.restype = ctypes.c_void_p
        libc.calloc.argtypes = [ctypes.c_size_t, ctypes.c_size_t]
        libc.strdup.restype = ctypes.c_void_p
        libc.strdup.argtypes = [ctypes.c_char_p]
        libc.free.restype = None
        libc.free.argtypes = [ctypes.c_void_p]
        self.messages = []
        self.errors = []
        self.callback = self._callback
        self.c_callback = CONV_FUNC(self._callback)

    def _callback(self, num_msg, msg, resp, _appdata):
        # An exception escaping a ctypes callback makes it return 0, which libpam
        # reads as PAM_SUCCESS with no answer: never let one through.
        try:
            return self._answer(num_msg, msg, resp)
        except Exception as error:  # noqa: BLE001 - any failure must become PAM_CONV_ERR
            self.errors.append(type(error).__name__)
            # Type name only: the message could carry the password.
            print(f"pam: conversation callback failed ({type(error).__name__})", flush=True)
            return PAM_CONV_ERR

    def _answer(self, num_msg, msg, resp):
        if num_msg <= 0:
            return PAM_CONV_ERR
        # libpam frees the array and every resp string, so both come from libc.
        block = self._libc.calloc(num_msg, ctypes.sizeof(PamResponse))
        if not block:
            return PAM_BUF_ERR
        answers = ctypes.cast(block, ctypes.POINTER(PamResponse))
        try:
            for index in range(num_msg):
                style = msg[index].contents.msg_style
                text = (msg[index].contents.msg or b"").decode(errors="replace")
                self.messages.append((style, text))
                print(f"pam: [{STYLE_NAMES.get(style, f'style-{style}')}] {text}", flush=True)
                if style in (PAM_PROMPT_ECHO_OFF, PAM_PROMPT_ECHO_ON):
                    answer = self._libc.strdup(self._password)
                    if not answer:
                        self._release(answers, block, num_msg)
                        return PAM_BUF_ERR
                    answers[index].resp = answer
        except Exception:
            self._release(answers, block, num_msg)
            raise
        resp[0] = answers
        return PAM_SUCCESS

    def _release(self, answers, block, num_msg):
        # calloc zeroed the array, so unanswered slots hold NULL and free(NULL) is a no-op.
        for index in range(num_msg):
            self._libc.free(answers[index].resp)
        self._libc.free(block)


def verdict(code, elapsed, messages, expect, max_seconds, expect_messages, forbid_messages, conversation_errors=()):
    """(ok, one-line reason) from the PAM result code, duration, messages and callback errors."""
    texts = [text for _style, text in messages]
    if conversation_errors:
        return False, f"conversation callback failed ({', '.join(conversation_errors)}), PAM returned {code}"
    if expect == "success" and code != PAM_SUCCESS:
        return False, f"expected success, PAM returned {code}"
    if expect == "fail" and code == PAM_SUCCESS:
        return False, "expected fail, PAM returned success"
    if elapsed > max_seconds:
        return False, f"took {elapsed:.1f}s, limit {max_seconds:g}s"
    for wanted in expect_messages:
        if wanted not in texts:
            return False, f"missing message {wanted!r}"
    for unwanted in forbid_messages:
        if unwanted in texts:
            return False, f"forbidden message {unwanted!r} arrived"
    return True, f"{expect} in {elapsed:.1f}s, {len(messages)} message(s)"


def positive_seconds(value):
    seconds = float(value)
    if seconds <= 0:
        raise argparse.ArgumentTypeError("must be > 0")
    return seconds


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("service")
    parser.add_argument("user")
    parser.add_argument("password")
    parser.add_argument("--expect", required=True, choices=("success", "fail"))
    parser.add_argument("--max-seconds", required=True, type=positive_seconds)
    parser.add_argument("--expect-message", action="append", default=[])
    parser.add_argument("--forbid-message", action="append", default=[])
    return parser.parse_args(argv)


def load_libraries():
    pam_name = ctypes.util.find_library("pam") or "libpam.so.0"
    libc_name = ctypes.util.find_library("c") or "libc.so.6"
    pam = ctypes.CDLL(pam_name)
    libc = ctypes.CDLL(libc_name)
    pam.pam_start.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.POINTER(PamConv), ctypes.POINTER(ctypes.c_void_p)]
    pam.pam_start.restype = ctypes.c_int
    pam.pam_authenticate.argtypes = [ctypes.c_void_p, ctypes.c_int]
    pam.pam_authenticate.restype = ctypes.c_int
    pam.pam_end.argtypes = [ctypes.c_void_p, ctypes.c_int]
    pam.pam_end.restype = ctypes.c_int
    pam.pam_strerror.argtypes = [ctypes.c_void_p, ctypes.c_int]
    pam.pam_strerror.restype = ctypes.c_char_p
    return pam, libc


def start_watchdog(deadline, max_seconds):
    """Daemon timer: if PAM has not returned by deadline, print FAIL and exit 1 at once."""

    def hard_stop():
        sys.stdout.write(f"FAIL: PAM did not return within {max_seconds:g}s (hard stop after {deadline:g}s)\n")
        sys.stdout.flush()
        os._exit(1)

    timer = threading.Timer(deadline, hard_stop)
    timer.daemon = True
    timer.start()
    return timer


def main(argv=None):
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        pam, libc = load_libraries()
    except OSError as error:
        print(f"FAIL: cannot load libpam/libc: {error}")
        return 3

    conversation = Conversation(args.password, libc)
    conv = PamConv(conversation.c_callback, None)
    handle = ctypes.c_void_p()
    watchdog = start_watchdog(args.max_seconds + HARD_STOP_GRACE, args.max_seconds)
    started = time.monotonic()
    try:
        rc = pam.pam_start(args.service.encode(), args.user.encode(), ctypes.byref(conv), ctypes.byref(handle))
        if rc != PAM_SUCCESS:
            print(f"FAIL: pam_start({args.service}) returned {rc}")
            return 3
        code = pam.pam_authenticate(handle, 0)
        meaning = (pam.pam_strerror(handle, code) or b"?").decode(errors="replace")
        pam.pam_end(handle, code)
        elapsed = time.monotonic() - started
    finally:
        watchdog.cancel()

    print(f"pam: pam_authenticate = {code} ({meaning}) after {elapsed:.2f}s")
    ok, reason = verdict(
        code=code,
        elapsed=elapsed,
        messages=conversation.messages,
        expect=args.expect,
        max_seconds=args.max_seconds,
        expect_messages=args.expect_message,
        forbid_messages=args.forbid_message,
        conversation_errors=conversation.errors,
    )
    print(("ok: " if ok else "FAIL: ") + reason)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
