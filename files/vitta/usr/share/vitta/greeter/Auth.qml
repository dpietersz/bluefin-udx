import QtQuick
import Quickshell
import Quickshell.Io

// greetd login state machine plus the other side effects the greeter has
// (last-user file, poweroff/reboot). The UI (LoginScreen.qml) only talks to this
// object. VITTA_GREETER_PREVIEW=1 swaps the greetd backend for `fake` below,
// driven by VITTA_GREETER_SCENARIO={ok,badpass,multiprompt,error}, and turns
// power actions into status messages; everything else is the same code.
Scope {
    id: auth

    readonly property bool preview: Quickshell.env("VITTA_GREETER_PREVIEW") === "1"
    readonly property string scenario: String(Quickshell.env("VITTA_GREETER_SCENARIO") || "ok")
    readonly property string stateDir: String(Quickshell.env("VITTA_GREETER_STATE_DIR") || "/var/lib/greetd")
    readonly property var backend: preview ? fake : bridge
    readonly property bool available: preview || bridge.available

    // A login attempt is in flight (createSession .. launch / failure).
    property bool busy: false
    // Which prompt is waiting for the user: "", "echo" or "secret".
    property string awaiting: ""
    property string user: ""
    // Password typed before greetd asked for it; answers the first secret prompt.
    property string secret: ""
    property bool secretSent: false

    signal notice(string text, bool isError)
    signal echoPrompt(string text)     // visible prompt: UI answers via the user field
    signal secretPrompt(string text)   // another hidden prompt: UI asks for the password again
    signal failed(string text)         // attempt over; UI clears password and refocuses
    signal starting()                  // authenticated; session is being launched

    function login(name, password) {
        if (busy) return;
        if (!available) {
            failed("greetd is not reachable (GREETD_SOCK unset)");
            return;
        }
        user = name;
        secret = password;
        secretSent = false;
        awaiting = "";
        busy = true;
        backend.createSession(name);
    }

    function answer(text) {
        if (awaiting === "") return;
        awaiting = "";
        backend.respond(text);
    }

    function cancel() {
        if (busy) backend.cancelSession();
        reset();
    }

    function reset() {
        busy = false;
        awaiting = "";
        secret = "";
        secretSent = false;
    }

    function power(verb) {
        if (preview) {
            notice("preview: would run systemctl " + verb, false);
            return;
        }
        Quickshell.execDetached(["systemctl", verb]);
    }

    readonly property string lastUser: {
        const name = lastUserFile.text().trim();
        return /^[a-z_][a-z0-9_.-]*\$?$/.test(name) ? name : "";
    }

    function rememberUser(name) {
        if (name !== lastUser) lastUserFile.setText(name + "\n");
    }

    FileView {
        id: lastUserFile
        path: auth.stateDir + "/vitta-last-user"
        blockLoading: true
        // launch(..., true) quits right after greetd acks; write synchronously.
        blockWrites: true
        printErrors: false
    }

    Connections {
        target: auth.backend

        function onAuthMessage(message, error, responseRequired, echoResponse) {
            if (!responseRequired) {
                if (message !== "") auth.notice(message.trim(), error);
                return;
            }
            if (!echoResponse) {
                if (!auth.secretSent && auth.secret !== "") {
                    const s = auth.secret;
                    auth.secret = "";
                    auth.secretSent = true;
                    auth.backend.respond(s);
                    return;
                }
                auth.awaiting = "secret";
                auth.secretPrompt(message.trim());
                return;
            }
            auth.awaiting = "echo";
            auth.echoPrompt(message.trim());
        }

        function onAuthFailure(message) {
            auth.reset();
            auth.backend.cancelSession();
            auth.failed(message !== "" ? message : "authentication failed");
        }

        function onError(error) {
            auth.reset();
            auth.backend.cancelSession();
            auth.failed(error !== "" ? error : "greetd error");
        }

        function onReadyToLaunch() {
            auth.rememberUser(auth.user);
            auth.starting();
            // gdm-equivalent session variables (R14): without them logind records
            // a tty session and Electron misses niri.desktop's DesktopNames=niri;GNOME.
            auth.backend.launch(["niri-session"], ["XDG_SESSION_TYPE=wayland", "XDG_SESSION_DESKTOP=niri", "XDG_CURRENT_DESKTOP=niri:GNOME"], true);
        }
    }

    // greetd client (GreetdBridge.qml, via /usr/libexec/vitta/vitta-greetd-bridge).
    GreetdBridge {
        id: bridge
        active: !auth.preview
    }

    // ---- preview backend: same surface as the Greetd singleton -------------
    QtObject {
        id: fake

        signal authMessage(string message, bool error, bool responseRequired, bool echoResponse)
        signal authFailure(string message)
        signal readyToLaunch()
        signal launched()
        signal error(string error)

        property var steps: []
        // Call log read by selftest.qml (vitta-greeter-preview --selftest).
        property int createCount: 0
        property int cancelCount: 0
        property var responses: []
        property var launches: []

        function createSession(name) {
            createCount++;
            console.info("preview: createSession(" + name + "), scenario " + auth.scenario);
            switch (auth.scenario) {
            case "badpass":
                steps = [["secret", "Password: "], ["fail", "Authentication failure"]];
                break;
            case "multiprompt":
                steps = [["echo", "Verification code: "], ["secret", "Password: "], ["ready"]];
                break;
            case "error":
                steps = [["error", "preview: greetd could not start the session"]];
                break;
            default:
                steps = [["secret", "Password: "], ["ready"]];
            }
            fakeTimer.restart();
        }

        function respond(response) {
            console.info("preview: respond(<" + response.length + " chars>)");
            responses = responses.concat([response]);
            fakeTimer.restart();
        }

        function cancelSession() {
            cancelCount++;
            steps = [];
            fakeTimer.stop();
        }

        function launch(command, environment, quit) {
            // Never exec anything from the preview, and keep the window open.
            console.info("preview: launch(" + JSON.stringify(command) + ", " + JSON.stringify(environment)
                         + ", quit=" + quit + ") - not executed");
            launches = launches.concat([{ command: command, environment: environment, quit: quit }]);
            launched();
        }

        function advance() {
            if (steps.length === 0) return;
            const step = steps[0];
            steps = steps.slice(1);
            switch (step[0]) {
            case "secret": authMessage(step[1], false, true, false); break;
            case "echo": authMessage(step[1], false, true, true); break;
            case "fail": steps = []; authFailure(step[1]); break;
            case "error": steps = []; error(step[1]); break;
            case "ready": readyToLaunch(); break;
            }
        }
    }

    Timer {
        id: fakeTimer
        // badpass mimics pam_faildelay so the busy state is visible.
        interval: auth.scenario === "badpass" ? 700 : 250
        onTriggered: fake.advance()
    }
}
