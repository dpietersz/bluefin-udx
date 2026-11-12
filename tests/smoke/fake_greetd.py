#!/usr/bin/python3
"""Small scripted greetd server for bridge and greeter smoke tests."""

import argparse
import json
import os
from pathlib import Path
import select
import socket
import struct
import time


PAUSE = 0.05
# What greetd 0.10.3 answers to cancel_session once PAM's worker is gone,
# e.g. right after an auth_error.
CANCEL_ERROR = {
    "type": "error",
    "error_type": "error",
    "description": "unable to send message: Connection refused (os error 111)",
}


def frame(message):
    body = json.dumps(message, ensure_ascii=False, separators=(",", ":")).encode()
    return struct.pack("=I", len(body)) + body


def receive_exact(connection, count, deadline):
    chunks = []
    remaining = count
    while remaining:
        if time.monotonic() >= deadline:
            return None
        try:
            chunk = connection.recv(remaining)
        except socket.timeout:
            continue
        if not chunk:
            return None
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def receive_message(connection, deadline):
    header = receive_exact(connection, 4, deadline)
    if header is None:
        return None
    (length,) = struct.unpack("=I", header)
    body = receive_exact(connection, length, deadline)
    if body is None:
        return None
    return json.loads(body.decode())


def redact(request, password):
    logged = dict(request)
    if "response" in logged:
        response = logged.pop("response")
        logged["response_len"] = len(response) if isinstance(response, str) else None
        logged["response_ok"] = response == password
    return logged


def send_reply(connection, reply, split, delayed=False):
    if delayed:
        time.sleep(0.5)
    payload = frame(reply)
    if not split:
        connection.sendall(payload)
        return
    connection.sendall(payload[:4])
    time.sleep(PAUSE)
    middle = 4 + (len(payload) - 4) // 2
    connection.sendall(payload[4:middle])
    time.sleep(PAUSE)
    connection.sendall(payload[middle:])


def send_raw_reply(connection, body):
    connection.sendall(struct.pack("=I", len(body)) + body)


def saw_early_bytes(connection):
    ready, _, _ = select.select([connection], [], [], 0.5)
    if not ready:
        return False
    try:
        return bool(connection.recv(1, socket.MSG_PEEK))
    except (BlockingIOError, socket.timeout):
        return False


def serve_client(connection, args, password, log, deadline):
    phase = "new"
    while True:
        request = receive_message(connection, deadline)
        if request is None:
            return
        log.write(json.dumps(redact(request, password), ensure_ascii=False, separators=(",", ":")) + "\n")
        log.flush()
        if args.script == "probe-early" and phase == "new":
            log.write(json.dumps({"probe_early_bytes": saw_early_bytes(connection)}) + "\n")
            log.flush()
        if args.script == "silent":
            time.sleep(max(0, deadline - time.monotonic()))
            return
        if args.script == "partial-stall":
            connection.sendall(frame({"type": "success"})[:1])
            time.sleep(max(0, deadline - time.monotonic()))
            return
        request_type = request.get("type")
        if request_type == "cancel_session":
            send_reply(connection, CANCEL_ERROR if args.cancel_error else {"type": "success"},
                       args.script == "split", args.script == "delayed")
            phase = "new"
        elif request_type == "start_session":
            send_reply(connection, {"type": "success"}, args.script == "split", args.script == "delayed")
        elif request_type == "create_session":
            if args.script == "surrogate":
                send_raw_reply(connection, b'{"type":"error","description":"\\ud800"}')
                continue
            if args.script == "unicode":
                reply = {"type": "auth_message", "auth_message_type": "info", "auth_message": "café ü 😀"}
                phase = "done"
            elif args.script == "multiprompt":
                reply = {"type": "auth_message", "auth_message_type": "visible", "auth_message": "Login: "}
                phase = "multiprompt_password"
            else:
                reply = {"type": "auth_message", "auth_message_type": "secret", "auth_message": "Password: "}
                phase = "password"
            if args.script == "merged":
                connection.sendall(frame(reply) + frame({"type": "success"}))
                phase = "merged_owed"
            else:
                send_reply(connection, reply, args.script == "split", args.script == "delayed")
        elif request_type == "post_auth_message_response":
            if args.script == "merged" and phase == "merged_owed":
                phase = "done"
                continue
            if phase == "multiprompt_password":
                reply = {"type": "auth_message", "auth_message_type": "secret", "auth_message": "Password: "}
                phase = "password"
            elif phase == "info":
                reply = {"type": "success"}
                phase = "done"
            elif args.script == "died":
                return
            elif request.get("response") == password:
                if args.script == "info":
                    reply = {"type": "auth_message", "auth_message_type": "info", "auth_message": "Welcome"}
                    phase = "info"
                else:
                    reply = {"type": "success"}
                    phase = "done"
            else:
                reply = {"type": "error", "error_type": "auth_error", "description": "Authentication failed"}
                phase = "new"
            send_reply(connection, reply, args.script == "split", args.script == "delayed")
        else:
            send_reply(
                connection,
                {"type": "error", "error_type": "error", "description": "unexpected request"},
                args.script == "split",
                args.script == "delayed",
            )


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True)
    parser.add_argument(
        "--script",
        choices=(
            "ok", "badpass", "multiprompt", "info", "split", "merged", "died", "silent", "delayed", "unicode",
            "surrogate", "probe-early", "partial-stall",
        ),
        required=True,
    )
    parser.add_argument("--password-file")
    parser.add_argument("--keep", action="store_true")
    parser.add_argument("--cancel-error", action="store_true", help="answer cancel_session as greetd 0.10.3 does after a failed login")
    parser.add_argument("--timeout", type=float, default=30)
    return parser.parse_args()


def main():
    args = parse_args()
    path = Path(args.socket)
    password = Path(args.password_file).read_text() if args.password_file else "right"
    if path.exists():
        path.unlink()
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        listener.bind(str(path))
        listener.listen(1)
        listener.settimeout(0.2)
        deadline = time.monotonic() + args.timeout
        with open(f"{path}.log", "w", encoding="utf-8") as log:
            print("READY", flush=True)
            while time.monotonic() < deadline:
                try:
                    connection, _ = listener.accept()
                except socket.timeout:
                    continue
                with connection:
                    connection.settimeout(0.2)
                    serve_client(connection, args, password, log, deadline)
                if not args.keep:
                    break
    finally:
        listener.close()
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
