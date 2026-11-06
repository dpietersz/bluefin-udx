import QtQuick
import Quickshell
import Quickshell.Io

// The login card: four nested Gruvbox stripes (outer -> inner stripe1..4,
// 5 px each, radii max(0, 14 - 5*i) = 14/9/4/0) around logo, clock, date,
// login/password fields, status line and footer. Stripe geometry is fixed;
// everything inside scales with the card width (design width 560 px).
Item {
    id: card

    required property var theme
    required property var auth

    readonly property real u: width / 560
    readonly property int stripeWidth: 5
    readonly property int inset: 4 * stripeWidth
    readonly property real pad: Math.round(28 * u)
    readonly property string fontFamily: "Monaspace Neon"
    readonly property real baseSize: Math.round(22 * u)

    property string status: ""
    property bool statusError: false
    // While greetd waits on a visible (echoed) prompt the user field is the
    // answer box; the typed user name is parked here and restored afterwards.
    property bool answeringEcho: false
    property string parkedUser: ""
    property date now: new Date()

    implicitHeight: content.implicitHeight + 2 * (inset + pad)
    height: implicitHeight

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

    // ---- stripes -----------------------------------------------------------
    Repeater {
        model: 4
        Rectangle {
            required property int index
            anchors.fill: parent
            anchors.margins: index * card.stripeWidth
            radius: Math.max(0, 14 - card.stripeWidth * index)
            color: index === 3 ? card.theme.bg : "transparent"
            border.width: card.stripeWidth
            border.color: [card.theme.stripe1, card.theme.stripe2, card.theme.stripe3, card.theme.stripe4][index]
        }
    }

    // ---- content -----------------------------------------------------------
    TextMetrics {
        id: labelMetrics
        font.family: card.fontFamily
        font.pixelSize: card.baseSize
        text: "password:"
    }

    Column {
        id: content
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: card.inset + card.pad
        spacing: Math.round(10 * card.u)

        Image {
            anchors.horizontalCenter: parent.horizontalCenter
            width: Math.round(160 * card.u)
            height: width
            sourceSize.width: width
            sourceSize.height: height
            fillMode: Image.PreserveAspectFit
            smooth: true
            mipmap: true
            source: "file://" + Quickshell.shellPath("../theme/logo-" + card.theme.mode + ".png")
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: Qt.formatDateTime(card.now, "HH:mm")
            color: card.theme.fg
            font.family: card.fontFamily
            font.pixelSize: Math.round(72 * card.u)
            font.weight: Font.Bold
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: Qt.formatDateTime(card.now, "dddd d MMMM yyyy")
            color: card.theme.muted
            font.family: card.fontFamily
            font.pixelSize: Math.round(24 * card.u)
        }

        Item { width: 1; height: Math.round(8 * card.u) }

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
        }

        Text {
            width: parent.width
            // Reserve one line so the card does not jump when a message appears.
            height: Math.max(implicitHeight, Math.round(card.baseSize * 1.4))
            text: card.status
            color: card.statusError ? card.theme.error : card.theme.muted
            font.family: card.fontFamily
            font.pixelSize: card.baseSize
            wrapMode: Text.Wrap
            horizontalAlignment: Text.AlignHCenter
        }

        Text {
            width: parent.width
            text: hostnameOut.text.trim() + " · vitta" + (card.imageVersion !== "" ? " " + card.imageVersion : "")
            color: card.theme.muted
            font.family: card.fontFamily
            font.pixelSize: Math.round(16 * card.u)
            elide: Text.ElideMiddle
            horizontalAlignment: Text.AlignHCenter
        }
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

        implicitHeight: Math.round(48 * u)
        color: theme.bg
        border.width: 2
        border.color: input.activeFocus ? theme.stripe1 : theme.muted

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
            selectionColor: field.theme.stripe1
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
}
