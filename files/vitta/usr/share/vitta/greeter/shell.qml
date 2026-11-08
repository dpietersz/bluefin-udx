import QtQuick
import Quickshell

// Vitta login screen. greetd runs /usr/libexec/vitta/vitta-greeter, which
// starts this shell fullscreen inside cage; vitta-greeter-preview runs the
// same file in a normal window with VITTA_GREETER_PREVIEW=1 (fake greetd).
ShellRoot {
    id: root

    Theme { id: theme }
    Auth { id: auth }

    // Quickshell 0.2.1 has no IdleMonitor despite Cage exposing
    // ext-idle-notify-v1, so hand idle timing to swayidle after this client
    // has connected to Cage. The helper independently rejects preview mode.
    Component.onCompleted: {
        if (!auth.preview) Quickshell.execDetached(["/usr/libexec/vitta/vitta-greeter-idle"])
    }

    FloatingWindow {
        id: window

        title: auth.preview ? "vitta-greeter-preview" : "vitta-greeter"
        implicitWidth: 1280
        implicitHeight: 800
        color: theme.bg

        LoginScreen {
            id: card
            anchors.fill: parent
            theme: theme
            auth: auth
        }
    }
}
