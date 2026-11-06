import QtQuick
import Quickshell

// Vitta login screen. greetd runs /usr/libexec/vitta/vitta-greeter, which
// starts this shell fullscreen inside cage; vitta-greeter-preview runs the
// same file in a normal window with VITTA_GREETER_PREVIEW=1 (fake greetd).
ShellRoot {
    id: root

    Theme { id: theme }
    Auth { id: auth }

    FloatingWindow {
        id: window

        title: auth.preview ? "vitta-greeter-preview" : "vitta-greeter"
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

        Row {
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.margins: Math.round(32 * card.u)
            spacing: Math.round(24 * card.u)

            PowerButton { label: "reboot"; verb: "reboot" }
            PowerButton { label: "shutdown"; verb: "poweroff" }
        }
    }

    component PowerButton: Text {
        id: button

        required property string label
        required property string verb

        text: "[ " + label + " ]"
        color: hover.hovered ? theme.fg : theme.muted
        font.family: "Monaspace Neon"
        font.pixelSize: Math.round(20 * card.u)

        HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
        TapHandler { onTapped: auth.power(button.verb) }
    }
}
