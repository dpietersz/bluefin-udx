import QtQuick
import Quickshell
import Quickshell.Io

// The greeter's greetd client: the same surface as Quickshell's Greetd
// singleton as far as Auth.qml uses it, backed by /usr/libexec/vitta/
// vitta-greetd-bridge. The helper owns the greetd socket and reads whole
// replies; here one JSON object per line goes each way. Quickshell's own
// client lost its place when a reply arrived in two parts (T580, 2026-11-12).
//
// Pairing: `sent` holds the kind of the request on the wire (at most one:
// the next request is written only once its reply has arrived), `waiting`
// the requests asked for meanwhile, in order. Each reply line belongs to the
// oldest sent request. Whatever goes wrong with the helper (a "bridge" error
// line, its exit, a line that is not JSON, failing to start) clears both,
// emits error() once, and the next createSession() starts a fresh helper, so
// Auth.qml is never left busy.
Scope {
    id: bridge

    readonly property string socketPath: String(Quickshell.env("GREETD_SOCK") || "")
    readonly property bool available: socketPath !== ""
    readonly property string helperPath: String(Quickshell.env("VITTA_GREETD_BRIDGE") || "/usr/libexec/vitta/vitta-greetd-bridge")
    // Test-only (vitta-greeter-preview --selftest): stay up after
    // start_session so the selftest can inspect what follows.
    readonly property bool selftestNoQuit: Quickshell.env("VITTA_GREETER_SELFTEST_NO_QUIT") === "1"
    // Auth.qml turns this off in preview mode: no helper is started then.
    property bool active: true

    signal authMessage(string message, bool error, bool responseRequired, bool echoResponse)
    signal authFailure(string message)
    signal readyToLaunch()
    signal launched()
    signal error(string error)

    // [{ kind, quit, stale }]: kind is create, respond, ack, start or cancel.
    property var sent: []
    // [{ kind, quit, request }] not written yet.
    property var waiting: []
    // A session was created and neither cancelled nor started since.
    property bool sessionOpen: false
    // The helper process has started and has not failed.
    property bool helperUp: false
    // The current helper's failure was already reported (error() emitted).
    property bool helperReported: false

    function createSession(name) {
        sessionOpen = true;
        enqueue("create", { type: "create_session", username: String(name) }, false);
    }

    function respond(text) {
        enqueue("respond", { type: "post_auth_message_response", response: String(text) }, false);
    }

    function cancelSession() {
        if (!sessionOpen) return;
        // greetd schedules the session when it gets start_session: once that
        // is written, the launch completes (success: launched() and quit; an
        // error still reaches Auth.qml) and no cancel_session follows it.
        if (sent.some(entry => entry.kind === "start")) return;
        sessionOpen = false;
        // Replies to what the cancelled attempt has on the wire are swallowed,
        // and what it has not sent yet is dropped: cancel_session resets greetd.
        sent = sent.map(entry => ({ kind: entry.kind, quit: entry.quit, stale: true }));
        waiting = waiting.filter(entry => entry.kind === "cancel");
        enqueue("cancel", { type: "cancel_session" }, false);
    }

    function launch(command, environment, quit) {
        enqueue("start", {
            type: "start_session",
            cmd: Array.from(command).map(String),
            env: Array.from(environment).map(String)
        }, quit === true);
    }

    function enqueue(kind, request, quit) {
        waiting = waiting.concat([{ kind: kind, quit: quit, request: request }]);
        pump();
    }

    // Write the next waiting request if nothing is on the wire, starting the
    // helper first when it is not up (started() calls pump again).
    function pump() {
        if (sent.length > 0 || waiting.length === 0) return;
        if (!helperUp) {
            // A failed helper that has not exited yet restarts from
            // onRunningChanged once it is gone.
            if (!helper.running && available && active) helper.running = true;
            else if (!available || !active) lost("greetd is not reachable (GREETD_SOCK unset)");
            return;
        }
        const next = waiting[0];
        waiting = waiting.slice(1);
        sent = sent.concat([{ kind: next.kind, quit: next.quit, stale: false }]);
        helper.write(JSON.stringify(next.request) + "\n");
    }

    // The helper can no longer be used: forget every request, stop it if it
    // still runs, and tell Auth.qml (which resets and shows the message).
    function lost(description) {
        sent = [];
        waiting = [];
        sessionOpen = false;
        helperUp = false;
        helperReported = true;
        if (helper.running) helper.running = false;
        bridge.error(description !== "" ? description : "greetd bridge stopped");
    }

    function handleLine(line) {
        // A helper that was already given up on (lost()) has nothing to say.
        if (!helperUp || line.trim() === "") return;
        let reply;
        try {
            reply = JSON.parse(line);
        } catch (e) {
            reply = null;
        }
        if (reply === null || typeof reply !== "object") {
            lost("greetd bridge sent an invalid line");
            return;
        }
        if (reply.type === "error" && reply.error_type === "bridge") {
            lost(String(reply.description || ""));
            return;
        }
        if (sent.length === 0) {
            // Nothing asked: not a reply to us. Never happens with a sane helper.
            console.warn("vitta-greeter: ignoring an unrequested greetd reply of type " + String(reply.type));
            return;
        }
        const entry = sent[0];
        sent = sent.slice(1);
        if (!entry.stale) dispatch(entry, reply);
        pump();
    }

    function dispatch(entry, reply) {
        const description = String(reply.description || "");
        switch (reply.type) {
        case "auth_message": {
            if (entry.kind === "cancel") return;
            const text = String(reply.auth_message || "");
            switch (reply.auth_message_type) {
            case "visible": authMessage(text, false, true, true); return;
            case "secret": authMessage(text, false, true, false); return;
            case "info":
            case "error":
                authMessage(text, reply.auth_message_type === "error", false, false);
                // greetd waits for an answer to these too; none if the
                // attempt was cancelled meanwhile.
                if (sessionOpen) enqueue("ack", { type: "post_auth_message_response" }, false);
                return;
            default:
                error("greetd sent an unknown message type");
                return;
            }
        }
        case "success":
            switch (entry.kind) {
            case "cancel": return;
            case "start":
                sessionOpen = false;
                launched();
                if (entry.quit && !selftestNoQuit) Qt.quit();
                return;
            default:
                readyToLaunch();
                return;
            }
        case "error":
            // e.g. "Connection refused" when PAM's worker is already gone.
            if (entry.kind === "cancel") return;
            if (reply.error_type === "auth_error") authFailure(description);
            else error(description);
            return;
        default:
            if (entry.kind !== "cancel") error("greetd sent an unknown reply");
            return;
        }
    }

    Process {
        id: helper
        command: [bridge.helperPath]
        stdinEnabled: true
        // Started at once so it is connected before the first login; restarted
        // by pump() on the next createSession() after it is gone.
        running: bridge.available && bridge.active

        stdout: SplitParser {
            onRead: line => bridge.handleLine(line)
        }

        onStarted: {
            bridge.helperUp = true;
            bridge.helperReported = false;
            bridge.pump();
        }

        // Exit, crash or failure to start (Quickshell then emits no exited()).
        onRunningChanged: {
            if (running) return;
            const wasUp = bridge.helperUp;
            bridge.helperUp = false;
            if (!bridge.helperReported)
                bridge.lost(wasUp ? "greetd bridge stopped" : "could not start the greetd bridge");
            // Only requests asked for after the failure are left: start anew.
            bridge.helperReported = false;
            bridge.pump();
        }
    }
}
