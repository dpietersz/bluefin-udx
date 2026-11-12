# Vitta greeter: own greetd client (bridge) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Vitta login screen no longer freezes when greetd's reply arrives in two parts: the greeter talks to greetd through its own small client instead of Quickshell's built-in one, with the look and behaviour unchanged.

**Architecture:** A stdlib-Python helper, `/usr/libexec/vitta/vitta-greetd-bridge`, owns the greetd socket and the wire framing (4-byte length + JSON, read to completion) and exchanges one JSON object per line with the greeter over stdin/stdout. A new QML component, `GreetdBridge.qml`, runs the helper with Quickshell's `Process` and offers the same surface `Auth.qml` uses today (`createSession`, `respond`, `cancelSession`, `launch`; signals `authMessage`, `authFailure`, `readyToLaunch`, `launched`, `error`). `Auth.qml` switches its real backend from the `Greetd` singleton to the bridge; the preview's fake backend stays.

**Tech Stack:** Python 3.14 stdlib (`socket`, `struct`, `json`), Quickshell 0.2.1 QML (`Quickshell.Io` `Process`, `SplitParser`), greetd 0.10.3 IPC, `unittest`, the existing `vitta-greeter-preview --selftest` harness, both smoke gates.

**Spec:** Owner decision 2026-11-12 (option B) after the T580 login screen froze on a wrong password. Evidence, in the ledger `.superpowers/sdd/2026-11-06-vitta/progress.md` and in `.superpowers/sdd/2026-11-12-vitta-greetd-bridge/evidence/`: the greeter log from the T580 (`Received unexpected greetd response ""`, then a reply fragment), Quickshell's client at the shipped commit (`quickshell-dacfa9d-connection.cpp`: one `read(4)` + one `read(length)` per `readyRead`, no loop; a cancel's late `success` taken as "authenticated") and at upstream master (`quickshell-master-connection.cpp`, the corrected behaviour), a fake greetd server and a real-greetd rig from the earlier experiments.

## Global Constraints

- Password only at the login screen; no fingerprint logic. The look, the texts and the session launch stay exactly as they are: `backend.launch(["niri-session"], ["XDG_SESSION_TYPE=wayland", "XDG_SESSION_DESKTOP=niri", "XDG_CURRENT_DESKTOP=niri:GNOME"], true)` stays byte-identical in `Auth.qml` (a smoke gate greps it).
- greetd IPC: every message is a 4-byte length in native byte order followed by that many bytes of UTF-8 JSON. Requests: `create_session {username}`, `post_auth_message_response {response?}`, `start_session {cmd, env}`, `cancel_session`. Replies: `success`, `error {error_type: "auth_error"|"error", description}`, `auth_message {auth_message_type: "visible"|"secret"|"info"|"error", auth_message}`. greetd answers each request with exactly one reply, in order, and the client must answer every `auth_message`, also `info` and `error` ones.
- Never more than one request waiting for its reply on the socket. A reply is paired with the request that caused it, never with a later one.
- The password never appears in any log, on stderr, in the helper's argv or environment, or in a test's output.
- Shared Vitta files only (`files/vitta/`); nothing in `files/system/`; no new packages. `bluefin-udx*` recipes and CI behaviour unchanged.
- Smoke-gate shell inside `podman run … -c '…'` uses only double quotes; the smoke `run:` block contains no `${{ }}`; new gate lines go in both `.github/workflows/build.yml` and `scripts/local-build-test.sh`, identical, under `IS_VITTA`; never compare `$RECIPE_NAME` to a literal; every assertion can fail and prints FAIL/MISS instead of aborting.
- The greeter must never hang: every state has a way out that needs no reboot.
- No full local image builds; no desktop windows on the owner's machine; no sudo or system changes on this P14s; every shell command under `timeout`.

## Review Focus

1. **A reply that arrives in pieces or glued to the next one** (header alone, body in two chunks, two replies in one read): each reply is delivered once, whole, in order → Task 1 unit tests with a fake greetd that splits and merges on purpose; Task 2 selftest scenario `bridge-split`.
2. **Wrong password:** the failure text is shown in the error colour, the fields are usable again, and the reply to the greeter's own `cancel_session` is not shown as a second error → Task 2 scenario `bridge-badpass`.
3. **The helper dies or greetd closes the socket** (greetd restart, helper crash): the greeter shows an error, does not stay busy, and the next attempt starts a fresh helper → Task 2 scenario `bridge-died`.
4. **Messages that need no answer from the user** (`info`, `error` from PAM, e.g. a password-expiry warning): shown, acknowledged to greetd, login continues → Task 2 scenario `bridge-info`.
5. **A user name or password with characters that matter to JSON or to a line protocol** (quotes, backslash, newline, non-ASCII): arrives at greetd unchanged, one request per line → Task 1 unit test.

---

### Task 1: Bridge helper and fake greetd

**Files:**
- Create: `files/vitta/usr/libexec/vitta/vitta-greetd-bridge` (mode 0755), `tests/smoke/fake_greetd.py`, `tests/test_vitta_greetd_bridge.py`

**Interfaces:**
- Produces: `vitta-greetd-bridge` (no arguments; socket path from `$GREETD_SOCK`). stdin: one greetd request as a JSON object per line. stdout: one line per greetd reply, the reply's JSON object unchanged, flushed. It forwards a request only after the previous reply has been read completely. On a missing or unreachable socket, EOF from greetd, a short read, or a reply that is not valid JSON it prints one line `{"type":"error","error_type":"bridge","description":"<what happened>"}` and exits 1. An input line that is not a JSON object gets the same kind of error line and is not forwarded (the helper keeps running). EOF on stdin: exit 0. Nothing else is written to stdout; stderr never contains a request's content.
- Produces: `python3 tests/smoke/fake_greetd.py --socket PATH --script NAME` (scripted server for tests and the selftest). Scripts: `ok` (prompt `Password: `, accepts `right`, then `success` to `start_session`), `badpass` (auth error for any other password), `multiprompt` (visible prompt, then secret), `info` (an `info` message after the password, then success), `split` (every reply sent as header, pause, half the body, pause, rest), `merged` (the reply to request N held back and sent in one write together with the reply to N+1), `died` (closes the socket after the password). It writes every request it received, one JSON per line with the password replaced by its length, to `PATH.log`.

- [ ] **Step 1: Failing tests** in `tests/test_vitta_greetd_bridge.py` (each starts the fake server on a temp socket and the helper as a subprocess with `timeout=10`):
  - `test_ok_roundtrip`: create → `auth_message` secret; response `right` → `success`; `start_session` → `success`; three output lines, in order.
  - `test_split_replies_are_delivered_whole`: script `split`; same three lines, each valid JSON.
  - `test_merged_replies_are_delivered_one_per_line`: script `merged`; two requests give two lines, in order.
  - `test_badpass_then_cancel`: wrong password → `error`/`auth_error`; `cancel_session` → its own reply line; exactly two lines after the prompt.
  - `test_special_characters_reach_greetd_unchanged`: user `a"b\\c é`, password `p"\\\n ü`: the fake's log shows the same user name and the right password length.
  - `test_greetd_closes_socket`: script `died` → one `bridge` error line, exit code 1.
  - `test_no_socket`: `GREETD_SOCK` unset or pointing nowhere → one `bridge` error line, exit 1, within 2 s.
  - `test_bad_input_line_is_refused_not_forwarded`: `not json` → `bridge` error line; the fake's log has no request; a following valid request still works.
  - `test_password_never_leaves_through_stderr_or_argv`: stderr of all runs above does not contain the password; the helper is started without arguments.
- [ ] **Step 2:** Run `python3 -m unittest tests/test_vitta_greetd_bridge.py -v` → FAIL (files missing).
- [ ] **Step 3:** Implement the fake server, then the helper (blocking loop: read line → frame and send → read exactly 4 bytes → read exactly N bytes → print line).
- [ ] **Step 4:** Tests PASS, output pristine. `python3 -m py_compile` on both files.
- [ ] **Step 5:** Commit `feat(vitta-greeter): own greetd client helper with complete reads`.

### Task 2: Greeter uses the bridge — login-focused review

**Files:**
- Create: `files/vitta/usr/share/vitta/greeter/GreetdBridge.qml`
- Modify: `files/vitta/usr/share/vitta/greeter/Auth.qml` (backend selection only, plus what the selftest needs), `files/vitta/usr/share/vitta/greeter/selftest.qml`, `files/vitta/usr/bin/vitta-greeter-preview`, `tests/test_vitta_overlay.py`, both smoke gates, `CLAUDE.md`, `RECIPE.md`, `docs/how-to/vitta-p14s-acceptance.md` and `docs/how-to/vitta-t580-acceptance.md` (the "login screen can lose sync" note)

**Interfaces:**
- Consumes: Task 1 helper and fake server.
- Produces `GreetdBridge.qml`, same surface as the `Greetd` singleton as far as `Auth.qml` uses it: `readonly property bool available` (true when `GREETD_SOCK` is set); `createSession(name)`, `respond(text)`, `cancelSession()`, `launch(command, environment, quit)`; signals `authMessage(message, error, responseRequired, echoResponse)`, `authFailure(message)`, `readyToLaunch()`, `launched()`, `error(error)`. Helper path overridable with `VITTA_GREETD_BRIDGE` (tests).
- `Auth.qml`: `backend` is `fake` in preview, else the bridge. The `Greetd` import goes away.

Behaviour of `GreetdBridge.qml` (exact):
- It keeps a FIFO of the request kinds it has sent (`create`, `respond`, `ack`, `start`, `cancel`) and pairs each reply line with the oldest entry. It sends the next request only when the FIFO is empty; requests asked for meanwhile wait in order.
- Reply `auth_message`: `visible` → `authMessage(text, false, true, true)`; `secret` → `(text, false, true, false)`; `info` → `(text, false, false, false)` and then an acknowledging `post_auth_message_response` without `response` (kind `ack`); `error` → `(text, true, false, false)` and the same acknowledgement.
- Reply `success` to `create`/`respond`/`ack` → `readyToLaunch()`; to `start` → `launched()`, and when `quit` was true the greeter quits; to `cancel` → nothing.
- Reply `error`: to `cancel` → nothing (this is the "Connection refused" that overwrote "Authentication failure" before); `auth_error` to anything else → `authFailure(description)`; other errors → `error(description)`.
- `cancelSession()` when no session was created since the last final reply sends nothing.
- A `bridge` error line or the helper exiting: clear the FIFO and waiting requests, emit `error(...)`, and start a fresh helper on the next `createSession`.

- [ ] **Step 1: Failing selftests.** `vitta-greeter-preview --selftest` gains a second group that runs the REAL `Auth.qml` + `GreetdBridge.qml` (no preview fake) against `fake_greetd.py`, when `VITTA_FAKE_GREETD` names that script (the smoke gates set it to `/smoke/fake_greetd.py`; without it the group is skipped with a visible `SKIP` line and the unit test `test_gates_run_bridge_selftest` makes sure the gates set it). Scenarios, asserting the status line, field state, and the fake's request log:
  - `bridge-ok`: password `right` → launch requested with the exact command and environment; requests `create_session`, `post_auth_message_response`, `start_session`.
  - `bridge-badpass`: failure text in the error colour, fields usable, then a second attempt with `right` succeeds; no "Connection refused" or other second error shown.
  - `bridge-split`: script `split`, wrong password first (the T580 case), then the right one → same as above.
  - `bridge-info`: info text shown, login completes, the log shows the acknowledgement.
  - `bridge-multiprompt`: as today's `multiprompt`, through the bridge.
  - `bridge-died`: error shown, not busy; with the fake restarted on script `ok`, a new attempt succeeds.
  The four existing preview scenarios and the cage edge check stay unchanged and still pass.
- [ ] **Step 2:** Run the selftest in a container (`ghcr.io/dpietersz/vitta:stable`, repo `files/vitta` at `/repo-vitta`, `tests/smoke` at `/smoke`, read-only) → the six new scenarios FAIL.
- [ ] **Step 3:** Implement `GreetdBridge.qml`, the `Auth.qml` switch, the preview-script group.
- [ ] **Step 4:** Selftest PASS (four old, six new, cage). `python3 -m unittest discover -s tests -p "test_vitta_*.py"` PASS. Add `test_auth_uses_the_bridge_backend` (no `Quickshell.Services.Greetd` import in the greeter directory; `Auth.qml` backend line) and `test_gates_run_bridge_selftest` to `tests/test_vitta_overlay.py`.
- [ ] **Step 5: Real greetd, once, in a container** (not a gate): with the rig in the evidence directory (`exp2-real-greetd-setup.sh`), run real greetd 0.10.3 with the image's PAM file and drive the helper by hand or by script: wrong password → `auth_error` line; right password → `success`. Record commands and output in the report. If the rig cannot be made to work within 15 minutes, say so and stop; the T580 test covers it.
- [ ] **Step 6:** Gates (`IS_VITTA`, both files): helper executable; `GreetdBridge.qml` present; `python3 -m py_compile` of the helper; the selftest runs with `VITTA_FAKE_GREETD=/smoke/fake_greetd.py` and its log line names all ten scenarios. Docs: one paragraph in `CLAUDE.md` (why the greeter has its own greetd client; where the helper and the fake server live), `RECIPE.md` note, and in both runbooks replace the "login screen can lose sync" follow-up with one line on recovery that is still valid (`Ctrl+Alt+F3`, `sudo systemctl restart greetd`).
- [ ] **Step 7:** Commit `feat(vitta-greeter): talk to greetd through the bridge`.

### Task 3: Review and hand-over

- [ ] **Step 1:** Controller pushes, opens the PR, watches the four legs, reads both Vitta legs' logs for the ten selftest scenarios.
- [ ] **Step 2:** Whole-branch review with a login brief (pairing of replies, every state has a way out, password handling, what happens on both laptops).
- [ ] **Step 3:** **Stop:** owner merges. After the main build publishes, the T580 (on `vitta:testing`) takes the update; the owner tries a wrong password several times, then the right one. Only then is the P14s switched.
