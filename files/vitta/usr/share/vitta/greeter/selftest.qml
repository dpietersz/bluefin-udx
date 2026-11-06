import QtQuick
import Quickshell

// Noninteractive behaviour test for the greeter: the real Theme, Auth and
// Card wired as in shell.qml, driven against the preview backend with a
// scripted submit. Run it via `vitta-greeter-preview --selftest`, which sets
// VITTA_GREETER_PREVIEW=1, the scenario and an offscreen platform, and turns
// the printed "SELFTEST RESULT" line into the exit status.
ShellRoot {
    id: root

    readonly property string password: "hunter2"
    readonly property string code: "123456"
    // R14: what greetd must launch, gdm-equivalent session variables included.
    readonly property var expectedEnvironment: [
        "XDG_SESSION_TYPE=wayland",
        "XDG_SESSION_DESKTOP=niri",
        "XDG_CURRENT_DESKTOP=niri:GNOME"
    ]

    property int failures: 0
    property var pending: null   // { cond, what, next, deadline }

    Theme { id: theme }
    Auth { id: auth }

    FloatingWindow {
        id: window
        title: "vitta-greeter-selftest"
        implicitWidth: 1280
        implicitHeight: 800
        color: theme.bg

        Card {
            id: card
            anchors.centerIn: parent
            width: Math.min(560, Math.round(0.4 * window.width))
            theme: theme
            auth: auth
        }
    }

    readonly property var fake: auth.backend
    readonly property var login: card.loginField
    readonly property var pass: card.passwordField

    function check(ok, what) {
        if (ok) {
            console.info("SELFTEST ok   " + auth.scenario + ": " + what);
        } else {
            failures++;
            console.warn("SELFTEST FAIL " + auth.scenario + ": " + what
                         + " [status=" + JSON.stringify(card.status) + " statusError=" + card.statusError
                         + " pass=" + JSON.stringify(pass.text) + " passFocus=" + pass.input.activeFocus
                         + " login=" + JSON.stringify(login.text) + " busy=" + auth.busy
                         + " awaiting=" + JSON.stringify(auth.awaiting) + "]");
        }
    }

    function finish() {
        console.info("SELFTEST RESULT " + (failures === 0 ? "PASS" : "FAIL") + " " + auth.scenario
                     + " (" + failures + " failed)");
        Qt.quit();
    }

    // Poll until cond() holds, then run next(); give up after 5 s.
    function waitFor(cond, what, next) {
        pending = { cond: cond, what: what, next: next, deadline: Date.now() + 5000 };
        poll.start();
    }

    Timer {
        id: poll
        interval: 25
        repeat: true
        onTriggered: {
            const p = root.pending;
            if (p.cond()) {
                stop();
                root.pending = null;
                p.next();
            } else if (Date.now() > p.deadline) {
                stop();
                root.pending = null;
                root.check(false, "timed out waiting for " + p.what);
                root.finish();
            }
        }
    }

    function submit() {
        pass.text = password;
        card.submitPassword();
    }

    function sameList(a, b) {
        return JSON.stringify(Array.from(a || [])) === JSON.stringify(b);
    }

    function isRed() {
        return card.statusError && Qt.colorEqual(card.statusLabel.color, theme.error);
    }

    // Shared by badpass and error: red message, attempt cancelled, password
    // cleared and focused, user name kept, nothing launched, retry possible.
    function expectFailure(message) {
        const createsBefore = fake.createCount;
        submit();
        check(auth.busy, "submit starts an attempt");
        // Focus elsewhere while greetd works, so the refocus is really tested.
        login.input.forceActiveFocus();
        check(!pass.input.activeFocus, "focus moved off the password field");
        waitFor(() => !auth.busy, "the attempt to end", () => {
            check(card.status === message, "status is " + JSON.stringify(message));
            check(isRed(), "status is red (theme.error)");
            check(fake.cancelCount >= 1, "greetd session cancelled");
            check(pass.text === "", "password cleared");
            check(pass.input.activeFocus, "password field focused");
            check(login.text === auth.lastUser, "user name kept");
            check(fake.launches.length === 0, "nothing launched");
            submit();
            check(fake.createCount === createsBefore + 2, "a retry creates a new session");
            auth.cancel();
            finish();
        });
    }

    function expectLaunch(responses) {
        check(fake.launches.length === 1, "launched exactly once");
        const l = fake.launches[0] || {};
        check(sameList(l.command, ["niri-session"]), "launch command is niri-session");
        check(sameList(l.environment, expectedEnvironment),
              "launch environment is " + JSON.stringify(expectedEnvironment)
              + " (got " + JSON.stringify(Array.from(l.environment || [])) + ")");
        check(l.quit === true, "greeter quits on launch");
        check(sameList(fake.responses, responses), "greetd got the expected answers");
        check(card.status === "starting niri-session…" && !card.statusError, "status: starting niri-session…");
        check(login.text === auth.lastUser, "user name shown");
    }

    function runOk() {
        submit();
        waitFor(() => fake.launches.length > 0, "launch", () => {
            expectLaunch([password]);
            finish();
        });
    }

    function runMultiprompt() {
        submit();
        waitFor(() => auth.awaiting === "echo", "the echo prompt", () => {
            check(card.status === "Verification code:" && !card.statusError, "echo prompt shown, not red");
            check(card.answeringEcho && login.label === "answer:", "user field relabelled answer:");
            check(login.input.activeFocus, "answer field focused");
            // Escape (Field.cancelled -> card.cancel) mid-prompt.
            const cancelsBefore = fake.cancelCount;
            card.cancel();
            check(fake.cancelCount === cancelsBefore + 1, "Escape cancels the greetd session");
            check(!auth.busy && auth.awaiting === "", "attempt reset");
            check(login.text === auth.lastUser && login.label === "login:", "user name restored");
            check(pass.text === "", "password cleared");
            check(pass.input.activeFocus, "password field focused");
            check(card.status === "", "status cleared");
            // Full run: answer the code, the held password answers the hidden prompt.
            submit();
            waitFor(() => auth.awaiting === "echo", "the echo prompt again", () => {
                login.text = code;
                card.submitUser();
                waitFor(() => fake.launches.length > 0, "launch", () => {
                    expectLaunch([code, password]);
                    finish();
                });
            });
        });
    }

    Timer {
        // Let Card.onCompleted prefill and focus first.
        interval: 300
        running: true
        onTriggered: {
            if (!auth.preview) {
                console.warn("SELFTEST FAIL refusing to run without VITTA_GREETER_PREVIEW=1");
                Qt.quit();
                return;
            }
            check(auth.lastUser !== "" && login.text === auth.lastUser, "last user prefilled");
            check(pass.input.activeFocus, "password field focused at start");
            switch (auth.scenario) {
            case "ok": root.runOk(); break;
            case "badpass": root.expectFailure("Authentication failure"); break;
            case "error": root.expectFailure("preview: greetd could not start the session"); break;
            case "multiprompt": root.runMultiprompt(); break;
            default:
                root.check(false, "unknown scenario");
                root.finish();
            }
        }
    }
}
