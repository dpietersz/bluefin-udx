import QtQuick
import QtTest
import Quickshell
import Quickshell.Io

// Noninteractive behaviour test for the greeter: the real Theme, Auth and
// LoginScreen wired as in shell.qml, driven against the preview backend with a
// scripted submit. Run it via `vitta-greeter-preview --selftest`, which sets
// VITTA_GREETER_PREVIEW=1, the scenario and an offscreen platform, and turns
// the printed "SELFTEST RESULT" line into the exit status.
// With VITTA_GREETER_SELFTEST_BRIDGE=bridge-<name> (and no preview) it drives
// the real GreetdBridge.qml + vitta-greetd-bridge against fake_greetd.py on
// GREETD_SOCK instead; the preview script also checks the fake's request log.
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
    // Set by vitta-greeter-preview --selftest for its run inside headless cage
    // with the launcher's flags: only the edge-to-edge checks, no scenario.
    readonly property bool cageCheck: String(Quickshell.env("VITTA_GREETER_SELFTEST_CAGE") || "") === "1"
    property var pending: null   // { cond, what, next, deadline }

    // Bridge group (see the header). Its right password is fake_greetd.py's.
    readonly property string bridgeScenario: String(Quickshell.env("VITTA_GREETER_SELFTEST_BRIDGE") || "")
    readonly property string scenarioName: bridgeScenario !== "" ? bridgeScenario : auth.scenario
    readonly property string rightPassword: "right"
    readonly property string wrongPassword: "wrong"
    property int failedCount: 0
    property var notices: []
    property int launchCount: 0
    // bridge-died: set once the preview script has restarted fake greetd.
    property bool greetdBack: false

    Theme { id: theme }
    Auth { id: auth }

    FloatingWindow {
        id: window
        title: "vitta-greeter-selftest"
        implicitWidth: 1280
        implicitHeight: 800
        color: theme.bg

        LoginScreen {
            id: card
            anchors.fill: parent
            theme: theme
            auth: auth
        }

        // Real key events through the window to whatever item has focus.
        TestEvent { id: keys }
    }

    readonly property var fake: auth.backend
    readonly property var login: card.loginField
    readonly property var pass: card.passwordField

    Connections {
        target: auth
        function onFailed(text) { root.failedCount++; }
        function onNotice(text, isError) { root.notices = root.notices.concat([{ text: text, isError: isError }]); }
    }

    Connections {
        target: auth.backend
        function onLaunched() {
            root.launchCount++;
            // bridge-ok runs without VITTA_GREETER_SELFTEST_NO_QUIT: the bridge
            // quits the greeter right after this signal, so judge now.
            if (root.scenarioName === "bridge-ok") root.bridgeOkLaunched();
        }
    }

    // bridge-died: is the marker file there yet?
    Process {
        id: markerCheck
        command: ["test", "-e", String(Quickshell.env("VITTA_GREETER_SELFTEST_MARKER") || "/nonexistent")]
        onExited: (code, status) => { if (code === 0) root.greetdBack = true; }
    }

    Timer {
        interval: 50
        repeat: true
        running: root.bridgeScenario === "bridge-died" && !root.greetdBack
        onTriggered: if (!markerCheck.running) markerCheck.running = true
    }

    function check(ok, what) {
        if (ok) {
            console.info("SELFTEST ok   " + scenarioName + ": " + what);
        } else {
            failures++;
            console.warn("SELFTEST FAIL " + scenarioName + ": " + what
                         + " [status=" + JSON.stringify(card.status) + " statusError=" + card.statusError
                         + " pass=" + JSON.stringify(pass.text) + " passFocus=" + pass.input.activeFocus
                         + " login=" + JSON.stringify(login.text) + " busy=" + auth.busy
                         + " awaiting=" + JSON.stringify(auth.awaiting) + "]");
        }
    }

    function report() {
        console.info("SELFTEST RESULT " + (failures === 0 ? "PASS" : "FAIL") + " " + scenarioName
                     + " (" + failures + " failed)");
    }

    function finish() {
        report();
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

    // Tab / Shift+Tab move focus between the two fields (both directions
    // cycle), as real key presses on the focused item. They must not submit,
    // answer greetd or type a tab. Shift+Tab is sent both as xkb delivers it
    // (Key_Backtab) and as Key_Tab with Shift held. `from`/`to` are the
    // field the test starts on and the other one; ends back on `from`.
    function pressTab(backwards, viaBacktab) {
        const key = backwards && viaBacktab ? Qt.Key_Backtab : Qt.Key_Tab;
        keys.keyClick(key, backwards ? Qt.ShiftModifier : Qt.NoModifier, -1);
    }

    function expectTabCycle(what, from, to) {
        const before = { create: fake.createCount, responses: fake.responses.length,
                         from: from.text, to: to.text, status: card.status };
        check(from.input.activeFocus, what + ": starts on the " + from.label.replace(":", "") + " field");
        pressTab(false, false);
        check(to.input.activeFocus && !from.input.activeFocus, what + ": Tab moves focus to the other field");
        pressTab(false, false);
        check(from.input.activeFocus, what + ": Tab again cycles back");
        pressTab(true, true);
        check(to.input.activeFocus, what + ": Shift+Tab (Key_Backtab) moves to the other field");
        pressTab(true, false);
        check(from.input.activeFocus, what + ": Shift+Tab (Tab+Shift) moves back");
        check(from.text === before.from && to.text === before.to, what + ": no tab typed, field texts unchanged");
        check(fake.createCount === before.create && fake.responses.length === before.responses,
              what + ": Tab neither submits nor answers greetd");
        check(card.status === before.status, what + ": status unchanged");
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
            expectTabCycle("echo prompt", login, pass);
            check(card.answeringEcho && login.label === "answer:", "still answering the echo prompt after Tab");
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

    // R20 layout A at the current window size: four touching full-width
    // bands of round(0.022 h), the block centred at 40 % of the height, the
    // logo (round(0.24 h)) centred on it in a bg circle of radius 0.54 x logo
    // painted between bands and logo, and clock, date, fields, status,
    // footer and power buttons inside the screen, clear of the bands, the
    // gap and each other.
    function box(item) {
        const p = item.mapToItem(card, 0, 0);
        return { x0: p.x, y0: p.y, x1: p.x + item.width, y1: p.y + item.height };
    }

    function overlaps(a, b) {
        return a.x0 < b.x1 && b.x0 < a.x1 && a.y0 < b.y1 && b.y0 < a.y1;
    }

    function checkLayout() {
        card.bandBlock.forceLayout();
        card.form.forceLayout();
        const w = card.width, h = card.height;
        const tag = "layout " + w + "x" + h + ": ";
        const band = Math.round(0.022 * h);
        const centre = Math.round(0.4 * h);
        const rows = Array.from(card.bandBlock.children)
            .filter(c => c.color !== undefined)
            .map(c => box(c));
        const colours = Array.from(card.bandBlock.children)
            .filter(c => c.color !== undefined)
            .map(c => c.color);
        check(rows.length === 4, tag + "four bands");
        check(rows.every(r => r.x0 === 0 && r.x1 === w), tag + "bands run edge to edge");
        check(rows.every(r => r.y1 - r.y0 === band), tag + "each band is round(0.022 h) = " + band + " px");
        check(rows.every((r, i) => i === 0 || r.y0 === rows[i - 1].y1), tag + "bands touch, top to bottom");
        check(rows.length === 4 && (rows[0].y0 + rows[3].y1) / 2 === centre,
              tag + "band block centred at 40 % (y " + centre + ")");
        check(colours.length === 4 && [theme.stripe1, theme.stripe2, theme.stripe3, theme.stripe4]
              .every((c, i) => Qt.colorEqual(colours[i], c)), tag + "bands are stripe1..4");
        const logo = box(card.logo), gap = box(card.logoGap);
        const logoSize = Math.round(0.24 * h);
        check(card.logo.width === logoSize && card.logo.height === logoSize, tag + "logo is round(0.24 h) = " + logoSize + " px");
        check(Math.abs((logo.x0 + logo.x1) / 2 - w / 2) <= 1 && Math.abs((logo.y0 + logo.y1) / 2 - centre) <= 1,
              tag + "logo centred horizontally and on the band block");
        check(card.logoGap.width === 2 * Math.round(0.54 * logoSize) && card.logoGap.radius === card.logoGap.width / 2
              && Qt.colorEqual(card.logoGap.color, theme.bg), tag + "bg gap circle of radius 0.54 x logo");
        check(Math.abs((gap.x0 + gap.x1) / 2 - (logo.x0 + logo.x1) / 2) <= 1
              && Math.abs((gap.y0 + gap.y1) / 2 - (logo.y0 + logo.y1) / 2) <= 1, tag + "gap circle concentric with the logo");
        const order = [card.bandBlock, card.logoGap, card.logo].map(i => card.children.indexOf(i));
        check(order[0] >= 0 && order[0] < order[1] && order[1] < order[2], tag + "painted bands, then gap, then logo");
        const items = {
            clock: card.clockLabel, date: card.dateLabel, bands: card.bandBlock, gap: card.logoGap,
            login: login, password: pass, status: card.statusLabel, footer: card.footerLabel,
            power: card.powerButtons
        };
        const names = Object.keys(items);
        const boxes = names.map(n => box(items[n]));
        boxes.forEach((b, i) => check(b.x0 >= 0 && b.y0 >= 0 && b.x1 <= w && b.y1 <= h, tag + names[i] + " inside the screen"));
        for (let i = 0; i < names.length; i++) {
            for (let j = i + 1; j < names.length; j++) {
                // The bands run into the gap circle by design (R20).
                if (names[i] === "bands" && names[j] === "gap") continue;
                check(!overlaps(boxes[i], boxes[j]), tag + names[i] + " clear of " + names[j]);
            }
        }
        check(logo.x0 >= gap.x0 && logo.x1 <= gap.x1 && logo.y0 >= gap.y0 && logo.y1 <= gap.y1, tag + "logo inside its gap");
    }

    // Check the layout at common screen sizes. The offscreen window does not
    // follow implicitWidth/Height once shown, so the screen item is detached
    // from it, sized directly, and re-anchored afterwards.
    function checkLayouts(sizes) {
        card.anchors.fill = undefined;
        for (const size of sizes) {
            card.width = size[0];
            card.height = size[1];
            checkLayout();
        }
        card.anchors.fill = card.parent;
        check(card.width === window.width && card.height === window.height, "screen fills the window again");
    }

    // Under cage the window must cover the whole output, and the screen the
    // whole window. A client-side decoration (Qt's bradient, drawn when cage
    // answers xdg-decoration with client_side) takes its frame out of the
    // output: the window shrinks by 6x33 and white edges show around it.
    function coversOutput() {
        return !!window.screen && window.width === window.screen.width && window.height === window.screen.height;
    }

    Timer {
        id: cagePoll
        property real deadline: 0
        interval: 25
        repeat: true
        onTriggered: {
            if (!root.coversOutput() && Date.now() < deadline) return;
            stop();
            const s = window.screen;
            root.check(root.coversOutput(), "cage: window " + window.width + "x" + window.height
                       + " covers the whole output " + (s ? s.width + "x" + s.height : "(no screen)"));
            root.check(card.width === window.width && card.height === window.height, "cage: screen fills the window");
            root.check(Qt.colorEqual(window.color, theme.bg), "cage: window background is theme.bg");
            root.finish();
        }
    }

    function startScenario() {
        check(pass.input.activeFocus, "password field still focused after the layout checks");
        check(Qt.colorEqual(pass.border.color, theme.focus) && Qt.colorEqual(login.border.color, theme.muted),
              "focused field border is theme.focus, the other theme.muted");
        expectTabCycle("idle", pass, login);
        pass.input.forceActiveFocus();
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

    // ---- bridge group ---------------------------------------------------------
    function submitWith(password) {
        pass.text = password;
        card.submitPassword();
    }

    function errorNotices() {
        return notices.filter(n => n.isError);
    }

    // A login that ended in niri-session being started through greetd (the
    // fake's log, checked by the preview script, holds the exact request).
    function expectBridgeLaunch(failuresBefore) {
        check(launchCount === 1, "launched exactly once");
        check(card.status === "starting niri-session…" && !card.statusError, "status: starting niri-session…");
        check(login.text === auth.lastUser, "user name shown");
        check(failedCount === failuresBefore, "no further failure shown");
        check(errorNotices().length === 0, "no error message shown");
    }

    // The bridge has failed the attempt: red message, fields usable again.
    function expectBridgeFailure(message) {
        check(card.status === message, "status is " + JSON.stringify(message));
        check(isRed(), "status is red (theme.error)");
        check(failedCount === 1, "exactly one failure shown");
        check(pass.text === "", "password cleared");
        check(pass.input.activeFocus, "password field focused");
        check(login.text === auth.lastUser, "user name kept");
        check(launchCount === 0, "nothing launched");
    }

    function bridgeOkLaunched() {
        expectBridgeLaunch(0);
        report();
        // Output after the verdict fails the run in the preview script.
        quitGuard.start();
    }

    Timer {
        id: quitGuard
        interval: 5000
        onTriggered: {
            root.check(false, "the greeter quits after start_session succeeded");
            root.finish();
        }
    }

    function runBridgeOk() {
        submitWith(rightPassword);
        check(auth.busy, "submit starts an attempt");
        // The verdict is printed from onLaunched; this only catches a hang.
        waitFor(() => false, "launch", () => {});
    }

    // Wrong password, then the right one: the reply to the greeter's own
    // cancel_session must neither show nor shift later replies.
    function runBridgeBadpass() {
        submitWith(wrongPassword);
        check(auth.busy, "submit starts an attempt");
        waitFor(() => !auth.busy, "the failed attempt to end", () => {
            expectBridgeFailure("Authentication failed");
            submitWith(rightPassword);
            check(auth.busy, "the retry starts an attempt");
            waitFor(() => launchCount > 0, "launch after the retry", () => {
                expectBridgeLaunch(1);
                finish();
            });
        });
    }

    function runBridgeInfo() {
        submitWith(rightPassword);
        waitFor(() => launchCount > 0, "launch", () => {
            check(notices.length === 1 && notices[0].text === "Welcome" && !notices[0].isError,
                  "info message shown, not red (got " + JSON.stringify(notices) + ")");
            expectBridgeLaunch(0);
            finish();
        });
    }

    function runBridgeMultiprompt() {
        submitWith(rightPassword);
        waitFor(() => auth.awaiting === "echo", "the echo prompt", () => {
            check(card.status === "Login:" && !card.statusError, "echo prompt shown, not red");
            check(card.answeringEcho && login.label === "answer:", "user field relabelled answer:");
            check(login.input.activeFocus, "answer field focused");
            card.cancel();
            check(!auth.busy && auth.awaiting === "", "Escape resets the attempt");
            check(login.text === auth.lastUser && login.label === "login:", "user name restored");
            check(pass.text === "" && pass.input.activeFocus, "password cleared and focused");
            check(card.status === "", "status cleared");
            submitWith(rightPassword);
            waitFor(() => auth.awaiting === "echo", "the echo prompt again", () => {
                login.text = code;
                card.submitUser();
                waitFor(() => launchCount > 0, "launch", () => {
                    expectBridgeLaunch(0);
                    finish();
                });
            });
        });
    }

    // greetd closes the connection mid-login: error shown, not busy; once
    // greetd is back a new attempt (with a fresh helper) logs in.
    function runBridgeDied() {
        submitWith(rightPassword);
        waitFor(() => !auth.busy, "the broken attempt to end", () => {
            expectBridgeFailure("greetd closed or sent an invalid reply");
            waitFor(() => greetdBack, "fake greetd to come back", () => {
                submitWith(rightPassword);
                check(auth.busy, "the new attempt starts");
                waitFor(() => launchCount > 0, "launch after greetd came back", () => {
                    expectBridgeLaunch(1);
                    finish();
                });
            });
        });
    }

    function startBridgeScenario() {
        check(auth.available, "greetd available (GREETD_SOCK set)");
        check(String(auth.backend.helperPath || "").endsWith("/vitta-greetd-bridge"),
              "backend is GreetdBridge driving vitta-greetd-bridge");
        check(auth.lastUser !== "" && login.text === auth.lastUser, "last user prefilled");
        check(pass.input.activeFocus, "password field focused at start");
        switch (bridgeScenario) {
        case "bridge-ok": runBridgeOk(); break;
        case "bridge-badpass":
        case "bridge-split": runBridgeBadpass(); break;
        case "bridge-info": runBridgeInfo(); break;
        case "bridge-multiprompt": runBridgeMultiprompt(); break;
        case "bridge-died": runBridgeDied(); break;
        default:
            check(false, "unknown bridge scenario");
            finish();
        }
    }

    Timer {
        // Let LoginScreen.onCompleted prefill and focus first.
        interval: 300
        running: true
        onTriggered: {
            if (root.bridgeScenario !== "") {
                if (auth.preview) {
                    console.warn("SELFTEST FAIL refusing to run the bridge group with VITTA_GREETER_PREVIEW=1");
                    Qt.quit();
                    return;
                }
                root.startBridgeScenario();
                return;
            }
            if (!auth.preview) {
                console.warn("SELFTEST FAIL refusing to run without VITTA_GREETER_PREVIEW=1");
                Qt.quit();
                return;
            }
            if (root.cageCheck) {
                cagePoll.deadline = Date.now() + 3000;
                cagePoll.start();
                return;
            }
            check(auth.lastUser !== "" && login.text === auth.lastUser, "last user prefilled");
            check(pass.input.activeFocus, "password field focused at start");
            check(!!keys.keyClick, "QtTest TestEvent available for key events");
            root.checkLayout();
            root.checkLayouts([[1920, 1080], [1366, 768], [2560, 1440], [1280, 1024], [3840, 2160]]);
            root.startScenario();
        }
    }
}
