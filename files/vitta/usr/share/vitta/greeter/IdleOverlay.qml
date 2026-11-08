import QtQuick
import Quickshell

// Cage 0.3.1 has no output-power-management-v1 global. This is therefore a
// full-screen black window rather than a DPMS request; swayidle removes it on
// the first resumed key or pointer activity.
ShellRoot {
    FloatingWindow {
        title: "vitta-greeter-idle"
        implicitWidth: 1280
        implicitHeight: 800
        color: "black"

        Rectangle {
            anchors.fill: parent
            color: "black"
        }
    }
}
