import QtQuick
import Quickshell
import Quickshell.Io

// The login screen, layout A (R20): no card, no frame. Four touching flat
// Gruvbox bands (stripe1..4) run edge to edge across the whole screen, with
// the logo centred on them in a round bg-coloured gap. Clock and date sit
// above the bands; login/password fields, status line and the
// `host · vitta <version>` line below. Every size follows the screen height.
Item {
    id: card

    required property var theme
    required property var auth

    // UI scale for the fields and small text: 1 at the 800 px preview window.
    readonly property real u: height / 800
    readonly property string fontFamily: "Monaspace Neon"
    readonly property real baseSize: Math.round(22 * u)

    // ---- layout A geometry (R20) ----
    readonly property int bandWidth: Math.max(1, Math.round(0.022 * height))
    readonly property int bandCentre: Math.round(0.4 * height)
    readonly property int bandTop: bandCentre - 2 * bandWidth
    readonly property int logoSize: Math.round(0.24 * height)
    readonly property int gapRadius: Math.round(0.54 * logoSize)
    readonly property int gapMargin: Math.round(0.03 * height)

    property string status: ""
    property bool statusError: false
    // While greetd waits on a visible (echoed) prompt the user field is the
    // answer box; the typed user name is parked here and restored afterwards.
    property bool answeringEcho: false
    property string parkedUser: ""
    property date now: new Date()
    // For selftest.qml: the scripted test drives and inspects these.
    readonly property alias loginField: userField
    readonly property alias passwordField: passField
    readonly property alias statusLabel: statusLine
    readonly property alias clockLabel: clock
    readonly property alias dateLabel: dateLine
    readonly property alias bandBlock: bands
    readonly property alias logoGap: gap
    readonly property alias logo: logoImage
    readonly property alias footerLabel: footer
    readonly property alias form: content
    readonly property alias powerButtons: powerRow

    function setStatus(text, isError) {
        status = text;
        statusError = isError;
    }

    function restoreUser() {
        if (!answeringEcho) return;
        answeringEcho = false;
        userField.placeholder = "";
        userField.text = parkedUser;
    }

    function focusStart() {
        if (userField.text === "") userField.input.forceActiveFocus();
        else passField.input.forceActiveFocus();
    }

    function submitUser() {
        if (answeringEcho) {
            const response = userField.text;
            restoreUser();
            setStatus("", false);
            passField.input.forceActiveFocus();
            auth.answer(response);
            return;
        }
        if (!auth.busy) passField.input.forceActiveFocus();
    }

    function submitPassword() {
        if (auth.awaiting === "secret") {
            setStatus("", false);
            auth.answer(passField.text);
            return;
        }
        if (auth.busy) return;
        const name = userField.text.trim();
        if (name === "") {
            setStatus("enter a user name", true);
            userField.input.forceActiveFocus();
            return;
        }
        setStatus("", false);
        auth.login(name, passField.text);
    }

    function cancel() {
        restoreUser();
        auth.cancel();
        passField.text = "";
        setStatus("", false);
        focusStart();
    }

    Component.onCompleted: {
        userField.text = auth.lastUser;
        focusStart();
    }

    Connections {
        target: card.auth
        function onNotice(text, isError) { card.setStatus(text, isError); }
        function onEchoPrompt(text) {
            card.parkedUser = userField.text;
            card.answeringEcho = true;
            userField.text = "";
            userField.placeholder = text;
            card.setStatus(text, false);
            userField.input.forceActiveFocus();
        }
        function onSecretPrompt(text) {
            passField.text = "";
            card.setStatus(text, false);
            passField.input.forceActiveFocus();
        }
        function onFailed(text) {
            card.restoreUser();
            passField.text = "";
            card.setStatus(text, true);
            passField.input.forceActiveFocus();
        }
        function onStarting() { card.setStatus("starting niri-session…", false); }
    }

    Timer {
        interval: 1000
        repeat: true
        running: true
        onTriggered: card.now = new Date()
    }

    // ---- bands, gap and logo (R20) ------------------------------------------
    // Four flat bands, each bandWidth thick, touching, full width, the block
    // centred at 40 % of the height. Integer, axis-aligned rectangles: no
    // borders, gradients, layers or effects, so nothing anti-aliases between
    // two bands. A bg-filled circle over their middle ends them in a clean
    // round gap around the logo, which is drawn last.
    Column {
        id: bands
        x: 0
        y: card.bandTop
        width: card.width

        Repeater {
            model: 4
            Rectangle {
                required property int index
                width: bands.width
                height: card.bandWidth
                color: [card.theme.stripe1, card.theme.stripe2, card.theme.stripe3, card.theme.stripe4][index]
            }
        }
    }

    Rectangle {
        id: gap
        width: 2 * card.gapRadius
        height: width
        radius: card.gapRadius
        x: Math.round((card.width - width) / 2)
        y: card.bandCentre - card.gapRadius
        color: card.theme.bg
    }

    Image {
        id: logoImage
        width: card.logoSize
        height: width
        x: Math.round((card.width - width) / 2)
        y: card.bandCentre - Math.round(height / 2)
        sourceSize.width: width
        sourceSize.height: height
        fillMode: Image.PreserveAspectFit
        smooth: true
        mipmap: true
        source: "file://" + Quickshell.shellPath("../theme/logo-" + card.theme.mode + ".png")
    }

    // ---- clock and date, above the bands ------------------------------------
    Text {
        id: dateLine
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: gap.top
        anchors.bottomMargin: card.gapMargin
        text: Qt.formatDateTime(card.now, "dddd d MMMM yyyy")
        color: card.theme.muted
        font.family: card.fontFamily
        font.pixelSize: Math.round(0.03 * card.height)
    }

    Text {
        id: clock
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: dateLine.top
        anchors.bottomMargin: Math.round(0.01 * card.height)
        text: Qt.formatDateTime(card.now, "HH:mm")
        color: card.theme.fg
        font.family: card.fontFamily
        font.pixelSize: Math.round(0.09 * card.height)
        font.weight: Font.Bold
    }

    // ---- login form, below the bands ----------------------------------------
    TextMetrics {
        id: labelMetrics
        font.family: card.fontFamily
        font.pixelSize: card.baseSize
        text: "password:"
    }

    Column {
        id: content
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: gap.bottom
        anchors.topMargin: Math.round(0.05 * card.height)
        width: Math.min(Math.round(380 * card.u), card.width - 2 * card.gapMargin)
        spacing: Math.round(10 * card.u)

        Field {
            id: userField
            width: parent.width
            u: card.u
            theme: card.theme
            fontFamily: card.fontFamily
            labelWidth: labelMetrics.advanceWidth
            label: card.answeringEcho ? "answer:" : "login:"
            readOnly: card.auth.busy && !card.answeringEcho
            onAccepted: card.submitUser()
            onCancelled: card.cancel()
            onTabbed: passField.input.forceActiveFocus()
            onBacktabbed: passField.input.forceActiveFocus()
        }

        Field {
            id: passField
            width: parent.width
            u: card.u
            theme: card.theme
            fontFamily: card.fontFamily
            labelWidth: labelMetrics.advanceWidth
            label: "password:"
            secret: true
            readOnly: card.auth.busy && card.auth.awaiting !== "secret"
            onAccepted: card.submitPassword()
            onCancelled: card.cancel()
            onTabbed: userField.input.forceActiveFocus()
            onBacktabbed: userField.input.forceActiveFocus()
        }

        Text {
            id: statusLine
            width: parent.width
            // Reserve one line so the form does not jump when a message appears.
            height: Math.max(implicitHeight, Math.round(card.baseSize * 1.4))
            text: card.status
            color: card.statusError ? card.theme.error : card.theme.muted
            font.family: card.fontFamily
            font.pixelSize: card.baseSize
            wrapMode: Text.Wrap
            horizontalAlignment: Text.AlignHCenter
        }

        Text {
            id: footer
            width: parent.width
            text: hostnameOut.text.trim() + " · vitta" + (card.imageVersion !== "" ? " " + card.imageVersion : "")
            color: card.theme.muted
            font.family: card.fontFamily
            font.pixelSize: Math.round(16 * card.u)
            elide: Text.ElideMiddle
            horizontalAlignment: Text.AlignHCenter
        }
    }

    // ---- reboot / shutdown, bottom-right ------------------------------------
    Row {
        id: powerRow
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: Math.round(32 * card.u)
        spacing: Math.round(24 * card.u)

        PowerButton { label: "reboot"; verb: "reboot" }
        PowerButton { label: "shutdown"; verb: "poweroff" }
    }

    // ---- footer sources ----------------------------------------------------
    Process {
        running: true
        command: ["uname", "-n"]
        stdout: StdioCollector { id: hostnameOut }
    }

    FileView {
        id: osRelease
        path: "/etc/os-release"
        blockLoading: true
        printErrors: false
    }

    readonly property string imageVersion: {
        const text = osRelease.text();
        const pick = key => {
            const m = text.match(new RegExp("^" + key + "=\"?([^\"\\n]*)\"?$", "m"));
            return m ? m[1] : "";
        };
        return pick("IMAGE_VERSION") || pick("VERSION_ID");
    }

    // ---- input field -------------------------------------------------------
    component Field: Rectangle {
        id: field

        required property real u
        required property var theme
        required property string fontFamily
        required property real labelWidth
        property string label: ""
        property string placeholder: ""
        property bool secret: false
        property alias text: input.text
        property alias input: input
        property alias readOnly: input.readOnly

        signal accepted()
        signal cancelled()
        // Tab / Shift+Tab. A bare TextInput is not in any focus chain and
        // ignores Tab, so the card moves focus itself; the key is always
        // consumed (never submits, never types a tab).
        signal tabbed()
        signal backtabbed()

        implicitHeight: Math.round(48 * u)
        color: theme.bg
        border.width: Math.max(2, Math.round(2 * u))
        border.color: input.activeFocus ? theme.focus : theme.muted

        Text {
            id: labelText
            anchors.left: parent.left
            anchors.leftMargin: Math.round(12 * field.u)
            anchors.verticalCenter: parent.verticalCenter
            width: field.labelWidth
            text: field.label
            color: field.theme.muted
            font.family: field.fontFamily
            font.pixelSize: Math.round(22 * field.u)
        }

        TextInput {
            id: input
            anchors.left: labelText.right
            anchors.leftMargin: Math.round(10 * field.u)
            anchors.right: parent.right
            anchors.rightMargin: Math.round(12 * field.u)
            anchors.verticalCenter: parent.verticalCenter
            color: field.theme.fg
            selectionColor: field.theme.focus
            selectedTextColor: field.theme.bg
            font.family: field.fontFamily
            font.pixelSize: Math.round(22 * field.u)
            echoMode: field.secret ? TextInput.Password : TextInput.Normal
            passwordCharacter: "•"
            passwordMaskDelay: 0
            clip: true
            selectByMouse: true
            onAccepted: field.accepted()
            Keys.onEscapePressed: field.cancelled()
            // xkb delivers Shift+Tab as Key_Backtab; accept Tab+Shift as well.
            Keys.onPressed: event => {
                if (event.key === Qt.Key_Backtab
                        || (event.key === Qt.Key_Tab && (event.modifiers & Qt.ShiftModifier))) {
                    event.accepted = true;
                    field.backtabbed();
                } else if (event.key === Qt.Key_Tab) {
                    event.accepted = true;
                    field.tabbed();
                }
            }
        }

        Text {
            anchors.fill: input
            verticalAlignment: Text.AlignVCenter
            visible: input.text === "" && field.placeholder !== ""
            text: field.placeholder
            color: field.theme.muted
            font.family: field.fontFamily
            font.pixelSize: Math.round(22 * field.u)
            font.italic: true
            elide: Text.ElideRight
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.IBeamCursor
            onPressed: mouse => { input.forceActiveFocus(); mouse.accepted = false; }
        }
    }

    component PowerButton: Text {
        id: button

        required property string label
        required property string verb

        text: "[ " + label + " ]"
        color: hover.hovered ? card.theme.fg : card.theme.muted
        font.family: card.fontFamily
        font.pixelSize: Math.round(20 * card.u)

        HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
        TapHandler { onTapped: card.auth.power(button.verb) }
    }
}
