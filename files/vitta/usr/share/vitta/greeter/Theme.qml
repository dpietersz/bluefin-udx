import QtQuick
import Quickshell
import Quickshell.Io

// Day/night palette for the greeter. `vitta-theme` (files/vitta/usr/bin) is
// the single source of truth for both the mode and the colours; this file only
// asks it, every 60 s. Anything that goes wrong (binary missing from PATH,
// non-zero exit, empty or unexpected output, bad JSON) falls back to dark and
// to the built-in copy of palette.toml below, so a broken theme tool can never
// leave the login screen unreadable.
Scope {
    id: theme

    readonly property bool preview: Quickshell.env("VITTA_GREETER_PREVIEW") === "1"
    // vitta-greeter-preview --mode pins the mode; ignored outside the preview.
    readonly property string forcedMode: {
        const m = String(Quickshell.env("VITTA_GREETER_MODE") || "");
        return preview && (m === "light" || m === "dark") ? m : "";
    }

    property string mode: forcedMode !== "" ? forcedMode : "dark"
    property var palette: fallback[mode]

    readonly property color bg: palette.bg
    readonly property color fg: palette.fg
    readonly property color stripe1: palette.stripe1
    readonly property color stripe2: palette.stripe2
    readonly property color stripe3: palette.stripe3
    readonly property color stripe4: palette.stripe4
    readonly property color muted: palette.muted
    readonly property color focus: palette.focus   // focused field border (R22)
    readonly property color error: palette.error

    // Mirror of files/vitta/usr/share/vitta/theme/palette.toml.
    readonly property var fallback: ({
        dark: {
            bg: "#282828", fg: "#ebdbb2",
            stripe1: "#689d6a", stripe2: "#458588", stripe3: "#d79921", stripe4: "#cc241d",
            muted: "#a89984", focus: "#689d6a", error: "#fb4934"
        },
        light: {
            bg: "#fbf1c7", fg: "#3c3836",
            stripe1: "#8ec07c", stripe2: "#83a598", stripe3: "#fabd2f", stripe4: "#fb4934",
            muted: "#7c6f64", focus: "#427b58", error: "#9d0006"
        }
    })
    readonly property var paletteKeys: ["bg", "fg", "stripe1", "stripe2", "stripe3", "stripe4", "muted", "focus", "error"]

    function validPalette(value) {
        if (value === null || typeof value !== "object") return false;
        return paletteKeys.every(k => typeof value[k] === "string" && /^#[0-9a-fA-F]{6}$/.test(value[k]));
    }

    onModeChanged: loadPalette()
    Component.onCompleted: loadPalette()

    function loadPalette() {
        palette = fallback[mode];
        paletteProc.running = false;
        paletteProc.command = ["vitta-theme", "palette", "--mode", mode, "--json"];
        paletteProc.running = true;
    }

    Timer {
        interval: 60000
        repeat: true
        running: theme.forcedMode === ""
        triggeredOnStart: true
        onTriggered: {
            modeProc.sawExit = false;
            modeProc.running = true;
        }
    }

    Process {
        id: modeProc
        // Set by onExited. A binary missing from PATH never exits: Quickshell
        // only drops `running`, so the else-branch below catches that case.
        property bool sawExit: false
        command: ["vitta-theme", "mode"]
        stdout: StdioCollector { id: modeOut }
        onExited: (code, status) => {
            sawExit = true;
            const m = modeOut.text.trim();
            theme.mode = code === 0 && (m === "light" || m === "dark") ? m : "dark";
        }
        onRunningChanged: {
            if (!running && !sawExit) theme.mode = "dark";
        }
    }

    Process {
        id: paletteProc
        stdout: StdioCollector { id: paletteOut }
        onExited: (code, status) => {
            // Drop answers for a mode we have since left.
            if (code !== 0 || command[3] !== theme.mode) return;
            try {
                const parsed = JSON.parse(paletteOut.text);
                if (theme.validPalette(parsed)) theme.palette = parsed;
            } catch (e) {
                // keep the fallback palette
            }
        }
    }
}
