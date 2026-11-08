#!/usr/bin/env bash
# Build a recipe locally with bluebuild and run a smoke-test against the result.
# Mirrors the CI smoke-boot gate so failures surface in ~5 min on your laptop
# instead of after a GH Actions run.
#
# Usage:
#   ./scripts/local-build-test.sh                  # builds bluefin-udx
#   ./scripts/local-build-test.sh bluefin-udx-nvidia
#   ./scripts/local-build-test.sh vitta

set -euo pipefail

RECIPE="${1:-bluefin-udx}"
RECIPE_FILE="recipes/${RECIPE}.yml"

if [ ! -f "$RECIPE_FILE" ]; then
    echo "ERROR: $RECIPE_FILE not found. Available recipes:"
    ls -1 recipes/
    exit 1
fi

if ! command -v bluebuild >/dev/null 2>&1; then
    echo "ERROR: bluebuild not installed."
    echo "Install with: brew install blue-build/tap/bluebuild  (or see https://blue-build.org/learn/getting-started/)"
    exit 1
fi

echo "==> Building $RECIPE locally (no push, no sign)..."
BB_BUILD_PUSH=false bluebuild build --no-sign "$RECIPE_FILE"

# bluebuild may pick the docker driver if a docker daemon is present, so the
# image can land in either store. Look in both.
IMAGE="localhost/${RECIPE}:latest"
if podman image exists "$IMAGE" 2>/dev/null; then
    RUNNER=podman
elif command -v docker >/dev/null && docker image inspect "$IMAGE" >/dev/null 2>&1; then
    RUNNER=docker
else
    echo "ERROR: $IMAGE not found in podman or docker storage"
    podman images 2>&1 | head -5
    docker images 2>&1 | head -5
    exit 1
fi
echo "==> Build done, image $IMAGE found in $RUNNER"

echo
echo "==> Smoke-boot test against $IMAGE (via $RUNNER)"

# Notes on the checks below:
#  - PATH-resident binaries (pass, gpg, …) check via `command -v`.
#  - Bluefin redirects /opt -> /var/opt (writeable, first-boot populated from
#    /usr/lib/opt). Inside a `run` container /var/opt is empty so the
#    /usr/bin/teams-for-linux symlink chain dead-ends. Verify the rpm is
#    installed AND the wrapped binary lives at its real /usr/lib/opt path.
$RUNNER run --rm -e "RECIPE_NAME=${RECIPE}" --entrypoint /bin/bash "$IMAGE" -c '
    set -e
    FAIL=0
    check_bin() {
        if command -v "$1" >/dev/null 2>&1; then echo "  ok    $1"; else echo "  MISS  $1"; FAIL=1; fi
    }
    check_file() {
        if [ -e "$1" ]; then echo "  ok    $1"; else echo "  MISS  $1"; FAIL=1; fi
    }
    check_rpm() {
        # Judge by exit status: for a missing package rpm -q prints
        # "package X is not installed" on STDOUT, so a non-empty test passed it.
        if RPM_NEVRA=$(rpm -q --qf "%{NAME}-%{EPOCHNUM}:%{VERSION}-%{RELEASE}.%{ARCH}" "$1" 2>/dev/null); then
            echo "  ok    rpm $RPM_NEVRA"
        else
            echo "  MISS  rpm $1"; FAIL=1
        fi
    }
    check_rpm_vendor() {
        RPM_VENDOR=$(rpm -q --qf "%{VENDOR}" "$1" 2>/dev/null || true)
        if [ "$RPM_VENDOR" = "$2" ]; then echo "  ok    $1 vendor: $RPM_VENDOR"; else echo "  FAIL  $1 vendor: ${RPM_VENDOR:-missing}, expected $2"; FAIL=1; fi
    }

    # Vitta = base-main + common.yml, no Bluefin layer. Assertions that
    # only hold because bluefin-dx supplied something are gated on this.
    if [ "$RECIPE_NAME" = "vitta" ]; then
        echo "Vitta identity:"
        # Parse, do not grep a fixed spelling: the BlueBuild os-release
        # module writes every value double-quoted (ID="vitta"), which
        # os-release(5) treats as identical to ID=vitta.
        grep -E "^(ID|ID_LIKE|NAME|PRETTY_NAME|VARIANT_ID|IMAGE_ID)=" /etc/os-release | sed "s/^/  info  /"
        for OS_RELEASE_FILE in /etc/os-release /usr/lib/os-release; do
            for OS_RELEASE_PAIR in ID=vitta ID_LIKE=fedora NAME=Vitta VARIANT_ID=vitta IMAGE_ID=vitta; do
                OS_RELEASE_KEY="${OS_RELEASE_PAIR%%=*}"
                OS_RELEASE_WANT="${OS_RELEASE_PAIR#*=}"
                OS_RELEASE_GOT=$(. "$OS_RELEASE_FILE" && printf %s "${!OS_RELEASE_KEY:-}" || true)
                if [ "$OS_RELEASE_GOT" = "$OS_RELEASE_WANT" ]; then
                    echo "  ok    $OS_RELEASE_FILE $OS_RELEASE_KEY=$OS_RELEASE_GOT"
                else
                    echo "  FAIL  $OS_RELEASE_FILE $OS_RELEASE_KEY=${OS_RELEASE_GOT:-unset}, expected $OS_RELEASE_WANT"
                    FAIL=1
                fi
            done
        done
        echo "Vitta excluded packages:"
        for p in gdm gnome-shell zfs incus uupd; do
            if rpm -q "$p" >/dev/null 2>&1; then
                echo "  FAIL  $p installed - Vitta must not ship it"
                FAIL=1
            else
                echo "  ok    $p not installed"
            fi
        done
        VITTA_FORBIDDEN=$(rpm -qa --qf "%{NAME}\n" | grep -E "^(gnome-session|cockpit|setroubleshoot|sysstat$)" || true)
        if [ -n "$VITTA_FORBIDDEN" ]; then
            echo "  FAIL  forbidden package families installed: $(echo $VITTA_FORBIDDEN)"
            FAIL=1
        else
            echo "  ok    no gnome-session* / cockpit* / setroubleshoot* / sysstat"
        fi
        echo "Vitta desktop plumbing, dev tools, integrations (vitta-modules.yml):"
        # Task 1 gap-analysis ADD set (Noto as the vf names bluefin-dx shipped) plus
        # the akmods-built v4l2loopback kmod.
        for p in android-tools code containerd.io docker-buildx-plugin docker-ce docker-ce-cli \
                 docker-ce-rootless-extras docker-compose-plugin edk2-ovmf gcc gnome-keyring gnome-keyring-pam \
                 google-noto-sans-vf-fonts google-noto-serif-vf-fonts google-noto-color-emoji-fonts \
                 gvfs gvfs-gphoto2 gvfs-mtp libvirt-client libvirt-daemon-kvm make nautilus podman-compose \
                 qemu-kvm swtpm tailscale tuned tuned-ppd virt-install virt-manager virt-viewer virtiofsd \
                 xdg-desktop-portal-gnome xdg-user-dirs kmod-v4l2loopback; do check_rpm "$p"; done
        # x86 KVM only: base-main ships qemu-user-static-aarch64 (removed in
        # vitta-modules.yml) and qemu-kvm must not drag in foreign emulators.
        VITTA_QEMU_FOREIGN=$(rpm -qa --qf "%{NAME}\n" | grep -E "^qemu-(user-static|system-)" | grep -Evx "qemu-system-x86(-core)?" || true)
        if [ -n "$VITTA_QEMU_FOREIGN" ]; then
            echo "  FAIL  non-x86 qemu installed: $(echo $VITTA_QEMU_FOREIGN)"
            FAIL=1
        else
            echo "  ok    no qemu-user-static* / non-x86 qemu-system-*"
        fi
        if rpm -q power-profiles-daemon >/dev/null 2>&1; then
            echo "  FAIL  power-profiles-daemon installed - tuned-ppd must own ppd-service"
            FAIL=1
        else
            echo "  ok    power-profiles-daemon replaced by tuned-ppd"
        fi
        check_file /etc/yum.repos.d/vscode.repo
        VSCODE_KEY_SHA256=$(sha256sum /etc/pki/rpm-gpg/microsoft.asc 2>/dev/null | cut -d " " -f 1)
        if [ "$VSCODE_KEY_SHA256" = "2fa9c05d591a1582a9aba276272478c262e95ad00acf60eaee1644d93941e3c6" ]; then
            echo "  ok    Microsoft signing key checksum"
        else
            echo "  FAIL  Microsoft signing key missing or checksum mismatch"
            FAIL=1
        fi
        # Offline query of unit symlinks/presets; needs no running systemd.
        # The libvirt sockets come from Fedora presets applied in the libvirt %post;
        # the Windows work VM needs them, so assert rather than trust the preset.
        for VITTA_UNIT in vitta-groups.service vitta-libvirt-relabel.service vitta-shadow-sync.service tailscaled.service docker.socket \
                          brew-setup.service brew-update.timer brew-upgrade.timer tuned.service tuned-ppd.service \
                          virtqemud.socket virtnetworkd.socket virtstoraged.socket; do
            VITTA_UNIT_STATE=$(systemctl is-enabled "$VITTA_UNIT" 2>/dev/null || true)
            if [ "$VITTA_UNIT_STATE" = enabled ]; then
                echo "  ok    $VITTA_UNIT enabled"
            else
                echo "  FAIL  $VITTA_UNIT is ${VITTA_UNIT_STATE:-missing}, expected enabled"
                FAIL=1
            fi
        done
        if [ -x /usr/libexec/vitta/vitta-groups ]; then
            echo "  ok    /usr/libexec/vitta/vitta-groups executable"
        else
            echo "  FAIL  /usr/libexec/vitta/vitta-groups missing or not executable"
            FAIL=1
        fi
        # vitta-groups needs both groups at boot: either baked by an RPM scriptlet
        # into /usr/lib/group (nss-altfiles) or declared for systemd-sysusers.
        for VITTA_GROUP in docker libvirt; do
            if getent group "$VITTA_GROUP" >/dev/null || grep -Eqs "^g[[:space:]]+$VITTA_GROUP[[:space:]]" /usr/lib/sysusers.d/*.conf; then
                echo "  ok    group $VITTA_GROUP defined for boot"
            else
                echo "  FAIL  group $VITTA_GROUP neither in group databases nor sysusers.d"
                FAIL=1
            fi
        done
        # The brew module bakes Homebrew under /usr/share/homebrew; brew-setup copies
        # it to /var/home/linuxbrew on first boot (empty /var in this container).
        if [ -x /usr/share/homebrew/home/linuxbrew/.linuxbrew/bin/brew ]; then
            echo "  ok    Homebrew baked at /usr/share/homebrew"
        else
            echo "  FAIL  /usr/share/homebrew/home/linuxbrew/.linuxbrew/bin/brew missing"
            FAIL=1
        fi
        if grep -qx "HOMEBREW_NO_ANALYTICS=1" /etc/environment 2>/dev/null; then
            echo "  ok    Homebrew analytics disabled"
        else
            echo "  FAIL  HOMEBREW_NO_ANALYTICS=1 missing from /etc/environment"
            FAIL=1
        fi
        # uname -r is the CI host kernel; resolve against the image kernel. Lookup by
        # name also proves depmod indexed the module, which modprobe needs at boot.
        VITTA_KVER=$(rpm -q --qf "%{VERSION}-%{RELEASE}.%{ARCH}\n" kernel-core | tail -n 1)
        V4L2_SIGNER=$(modinfo -k "$VITTA_KVER" -F signer v4l2loopback 2>/dev/null || true)
        if [ -n "$V4L2_SIGNER" ]; then
            echo "  ok    v4l2loopback for $VITTA_KVER signed by: $V4L2_SIGNER"
        else
            echo "  FAIL  v4l2loopback not resolvable or unsigned for kernel $VITTA_KVER"
            FAIL=1
        fi
        echo "Vitta greeter (greetd -> cage -> Quickshell):"
        for p in greetd cage quickshell; do check_rpm "$p"; done
        # Footer source (vitta <IMAGE_VERSION>); informational.
        grep -E "^(IMAGE_VERSION|VERSION_ID)=" /etc/os-release | sed "s/^/  info  /" || true
        for VITTA_GREETD_LINE in "vt = 1" "command = \"/usr/libexec/vitta/vitta-greeter\"" "user = \"greetd\""; do
            if grep -qxF "$VITTA_GREETD_LINE" /etc/greetd/config.toml 2>/dev/null; then
                echo "  ok    greetd config: $VITTA_GREETD_LINE"
            else
                echo "  FAIL  /etc/greetd/config.toml lacks: $VITTA_GREETD_LINE"; FAIL=1
            fi
        done
        VITTA_GREETD_STATE=$(systemctl is-enabled greetd.service 2>/dev/null || true)
        if [ "$VITTA_GREETD_STATE" = enabled ]; then echo "  ok    greetd.service enabled"; else echo "  FAIL  greetd.service is ${VITTA_GREETD_STATE:-missing}, expected enabled"; FAIL=1; fi
        VITTA_DM=$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null || true)
        case "$VITTA_DM" in
            */greetd.service) echo "  ok    display-manager.service -> $VITTA_DM" ;;
            *) echo "  FAIL  display-manager.service resolves to ${VITTA_DM:-nothing}, expected greetd.service"; FAIL=1 ;;
        esac
        # graphical.target is what pulls display-manager.service in at boot.
        VITTA_TARGET=$(systemctl get-default 2>/dev/null || true)
        if [ "$VITTA_TARGET" = graphical.target ]; then echo "  ok    default target graphical.target"; else echo "  FAIL  default target ${VITTA_TARGET:-unset}, expected graphical.target"; FAIL=1; fi
        VITTA_SESSIONS=$(ls -A /usr/share/wayland-sessions/ 2>/dev/null | tr "\n" " ")
        if [ "$VITTA_SESSIONS" = "niri.desktop " ]; then echo "  ok    wayland-sessions: niri.desktop only"; else echo "  FAIL  wayland-sessions: ${VITTA_SESSIONS:-empty}, expected niri.desktop only"; FAIL=1; fi
        # Fedora ships the keyring lines as -auth/-session (skip if module absent); accept either.
        for VITTA_PAM in "auth[[:space:]]+optional[[:space:]]+pam_gnome_keyring\.so" \
                         "session[[:space:]]+optional[[:space:]]+pam_gnome_keyring\.so[[:space:]]+auto_start" \
                         "password[[:space:]]+optional[[:space:]]+pam_gnome_keyring\.so[[:space:]]+use_authtok"; do
            if grep -Eq "^-?${VITTA_PAM}[[:space:]]*$" /etc/pam.d/greetd 2>/dev/null; then
                echo "  ok    pam.d/greetd: ${VITTA_PAM%%\[*} pam_gnome_keyring"
            else
                echo "  FAIL  /etc/pam.d/greetd lacks: $VITTA_PAM"; FAIL=1
            fi
        done
        # substack, not include: an included pam_unix "sufficient" would end the stack before the keyring line.
        if grep -Eq "^password[[:space:]]+substack[[:space:]]+system-auth[[:space:]]*$" /etc/pam.d/greetd 2>/dev/null; then echo "  ok    pam.d/greetd: password substack system-auth"; else echo "  FAIL  /etc/pam.d/greetd must use password substack system-auth"; FAIL=1; fi
        if rpm -V greetd 2>/dev/null | grep -q "/etc/pam.d/greetd-greeter"; then echo "  FAIL  /etc/pam.d/greetd-greeter differs from the greetd package"; FAIL=1; else echo "  ok    /etc/pam.d/greetd-greeter as packaged"; fi
        VITTA_DAY=$(vitta-theme mode --at 2026-06-21T12:00+02:00 2>/dev/null || true)
        VITTA_NIGHT=$(vitta-theme mode --at 2026-06-21T00:30+02:00 2>/dev/null || true)
        if [ "$VITTA_DAY/$VITTA_NIGHT" = light/dark ]; then echo "  ok    vitta-theme mode: noon light, 00:30 dark"; else echo "  FAIL  vitta-theme mode noon/00:30 = ${VITTA_DAY:-?}/${VITTA_NIGHT:-?}, expected light/dark"; FAIL=1; fi
        if [ -s /usr/share/vitta/theme/logo-dark.png ] && [ -s /usr/share/vitta/theme/logo-light.png ]; then echo "  ok    greeter logos"; else echo "  FAIL  /usr/share/vitta/theme/logo-{dark,light}.png missing or empty"; FAIL=1; fi
        # ostree populates /var only on first deploy; a rebased machine needs tmpfiles.
        if grep -Eqs "^d[[:space:]]+/var/lib/greetd[[:space:]]" /usr/lib/tmpfiles.d/*.conf; then echo "  ok    /var/lib/greetd created by tmpfiles.d"; else echo "  FAIL  no tmpfiles.d d-line creates /var/lib/greetd"; FAIL=1; fi
        if [ -x /usr/libexec/vitta/vitta-greeter ]; then echo "  ok    /usr/libexec/vitta/vitta-greeter executable"; else echo "  FAIL  /usr/libexec/vitta/vitta-greeter missing or not executable"; FAIL=1; fi
        # -m last: one output only; the default -m extend centres the card across a docked layout.
        # -d: cage answers xdg-decoration server_side, else Qt frames the greeter in white edges.
        if grep -Eq "^exec cage -d -s -m last -- quickshell " /usr/libexec/vitta/vitta-greeter 2>/dev/null; then echo "  ok    vitta-greeter runs cage -d -s -m last"; else echo "  FAIL  vitta-greeter must exec cage -d -s -m last (no client decoration frame, single output when docked)"; FAIL=1; fi
        if VITTA_QS_VERSION=$(quickshell --version 2>&1); then echo "  ok    $VITTA_QS_VERSION"; else echo "  FAIL  quickshell --version: $VITTA_QS_VERSION"; FAIL=1; fi
        # Behavioural: load the production greeter QML headless. Catches QML type and
        # reference errors that would otherwise surface only as a black screen at boot.
        mkdir -p -m 700 /tmp/vitta-qs-runtime
        VITTA_QS_LOG=$(XDG_RUNTIME_DIR=/tmp/vitta-qs-runtime QT_QPA_PLATFORM=offscreen timeout 10 quickshell -p /usr/share/vitta/greeter/shell.qml 2>&1 || true)
        VITTA_QS_BAD=$(printf "%s\n" "$VITTA_QS_LOG" | grep -E "ERROR|Error:|TypeError|ReferenceError|is not a type|Cannot assign|Unable to assign|not installed|failed to load" || true)
        if printf "%s\n" "$VITTA_QS_LOG" | grep -q "Configuration Loaded" && [ -z "$VITTA_QS_BAD" ]; then
            echo "  ok    greeter QML loads headless"
        else
            echo "  FAIL  greeter QML did not load cleanly:"; printf "%s\n" "$VITTA_QS_LOG" | grep -v inotify | tail -n 20 | sed "s/^/          /"; FAIL=1
        fi
        # R14: greetd must start niri-session with the gdm-equivalent session variables,
        # or logind records a tty session and Electron loses DesktopNames=niri;GNOME.
        VITTA_LAUNCH=$(grep -F "backend.launch(" /usr/share/vitta/greeter/Auth.qml | sed "s/^[[:space:]]*//")
        if [ "$VITTA_LAUNCH" = "auth.backend.launch([\"niri-session\"], [\"XDG_SESSION_TYPE=wayland\", \"XDG_SESSION_DESKTOP=niri\", \"XDG_CURRENT_DESKTOP=niri:GNOME\"], true);" ]; then
            echo "  ok    greeter launches niri-session with XDG_SESSION_TYPE/XDG_SESSION_DESKTOP/XDG_CURRENT_DESKTOP"
        else
            echo "  FAIL  greeter launch call lacks the R14 session environment: ${VITTA_LAUNCH:-none}"; FAIL=1
        fi
        # Behavioural: drive ok/badpass/multiprompt/error through the preview backend
        # headless (red status, cancellation, cleared + refocused password, launch env), then
        # rerun under headless cage with the launcher flags: the window must cover the output.
        if VITTA_SELFTEST_LOG=$(vitta-greeter-preview --selftest 2>&1); then
            echo "  ok    greeter selftest: ok badpass multiprompt error, edge to edge in headless cage"
        else
            echo "  FAIL  greeter selftest:"; printf "%s\n" "$VITTA_SELFTEST_LOG" | grep -E "FAIL|FAILED|^    " | tail -n 30 | sed "s/^/          /"; FAIL=1
        fi
        # Rebase simulation (an existing /var never gets the greetd %post output): tmpfiles
        # alone must recreate the greetd xdg-desktop-portal mask for the greeter session.
        rm -rf /var/lib/greetd/.config
        systemd-tmpfiles --create --prefix=/var/lib/greetd >/dev/null 2>&1 || true
        VITTA_PORTAL_MASK=$(readlink /var/lib/greetd/.config/systemd/user/xdg-desktop-portal.service 2>/dev/null || true)
        if [ "$VITTA_PORTAL_MASK" = /dev/null ]; then echo "  ok    tmpfiles.d recreates the greeter xdg-desktop-portal mask"; else echo "  FAIL  greeter xdg-desktop-portal mask not recreated by tmpfiles.d (got: ${VITTA_PORTAL_MASK:-nothing})"; FAIL=1; fi
        # user@<greetd uid> runs the systemd-user PAM stack; pam_unix account returns
        # AUTHINFO_UNAVAIL for a passwd "x" account without a shadow entry. Fresh install:
        # the image /etc/shadow must cover every shadowed account. Rebase with layered packages
        # (T580): rpm-ostree moves greetd into /usr/lib/passwd while the old /etc/shadow is kept;
        # vitta-shadow-sync must add the entry. unix_chkpwd chkexpiry is the pam_unix account check.
        VITTA_NOSHADOW=$(getent passwd | while IFS=: read -r VU VP VREST; do [ "$VP" = x ] && ! getent shadow "$VU" >/dev/null && printf "%s " "$VU"; done; true)
        if [ -z "$VITTA_NOSHADOW" ]; then echo "  ok    every shadowed account has an /etc/shadow entry"; else echo "  FAIL  accounts without an /etc/shadow entry (user@ PAM fails): $VITTA_NOSHADOW"; FAIL=1; fi
        VITTA_GREETD_PW=$(grep -h -m1 "^greetd:" /etc/passwd /usr/lib/passwd 2>/dev/null | head -n 1)
        if [ -n "$VITTA_GREETD_PW" ]; then sed -i "/^greetd:/d" /etc/passwd /etc/shadow /usr/lib/passwd; printf "%s\n" "$VITTA_GREETD_PW" >> /usr/lib/passwd; fi
        VITTA_CHK_BEFORE=0; /usr/sbin/unix_chkpwd greetd chkexpiry >/dev/null 2>&1 || VITTA_CHK_BEFORE=$?
        VITTA_SYNC_RC=0; /usr/libexec/vitta/vitta-shadow-sync >/dev/null 2>&1 || VITTA_SYNC_RC=$?
        VITTA_CHK_AFTER=0; /usr/sbin/unix_chkpwd greetd chkexpiry >/dev/null 2>&1 || VITTA_CHK_AFTER=$?
        VITTA_GREETD_SHADOW=$(getent shadow greetd | cut -d: -f2 || true)
        if [ "$VITTA_CHK_BEFORE" != 0 ] && [ "$VITTA_SYNC_RC/$VITTA_CHK_AFTER/$VITTA_GREETD_SHADOW" = "0/0/!*" ]; then
            echo "  ok    rebase simulation: vitta-shadow-sync gives greetd a locked shadow entry (pam_unix account $VITTA_CHK_BEFORE -> 0)"
        else
            echo "  FAIL  greetd in /usr/lib/passwd without shadow entry: pam_unix account before=$VITTA_CHK_BEFORE sync=$VITTA_SYNC_RC after=$VITTA_CHK_AFTER shadow=${VITTA_GREETD_SHADOW:-none}"; FAIL=1
        fi
        # Boot splash (R23): Plymouth theme vitta, default via plymouthd.defaults (wins on rebased
        # machines: /usr comes from the image, /etc keeps its 3-way merge), and baked into the
        # image initramfs, which is what bootc boots. lsinitrd proves the rebuild picked it up.
        echo "Vitta boot splash (Plymouth):"
        check_rpm plymouth-plugin-script
        VITTA_PLY_PLUGINS=$(plymouth --get-splash-plugin-path 2>/dev/null || echo /usr/lib64/plymouth/)
        check_file "${VITTA_PLY_PLUGINS}script.so"
        # LUKS prompt (R25): Monaspace Neon reaches the initramfs through the vitta-plymouth-font dracut module.
        check_file /usr/lib/dracut/modules.d/99vitta-plymouth-font/module-setup.sh
        check_file /usr/lib/dracut/dracut.conf.d/90-vitta-plymouth-font.conf
        VITTA_THEME_DIR=/usr/share/plymouth/themes/vitta
        VITTA_PLY_FILES=$(find "$VITTA_THEME_DIR" -maxdepth 1 -type f -printf "%f\n" | sort)
        if [ -n "$VITTA_PLY_FILES" ]; then
            for VITTA_PLY_FILE in $VITTA_PLY_FILES; do check_file "$VITTA_THEME_DIR/$VITTA_PLY_FILE"; done
        else
            echo "  FAIL  Vitta Plymouth theme has no files"
            FAIL=1
        fi
        VITTA_PLY_THEME=$(plymouth-set-default-theme 2>/dev/null || true)
        if [ "$VITTA_PLY_THEME" = vitta ] && grep -qx "Theme=vitta" /usr/share/plymouth/plymouthd.defaults; then echo "  ok    default Plymouth theme vitta (plymouthd.defaults)"; else echo "  FAIL  default Plymouth theme is ${VITTA_PLY_THEME:-unset}, expected vitta from /usr/share/plymouth/plymouthd.defaults"; FAIL=1; fi
        if grep -Eq "^[[:space:]]*Theme[[:space:]]*=" /etc/plymouth/plymouthd.conf 2>/dev/null; then echo "  FAIL  /etc/plymouth/plymouthd.conf sets Theme=, outranking plymouthd.defaults"; FAIL=1; else echo "  ok    /etc/plymouth/plymouthd.conf leaves Theme= to the defaults"; fi
        VITTA_INITRAMFS=""
        VITTA_INITRAMFS_CANDIDATES=0
        for VITTA_KVER in $(rpm -q --qf "%{VERSION}-%{RELEASE}.%{ARCH}\n" kernel-core 2>/dev/null || true); do
            if [ -f "/usr/lib/modules/$VITTA_KVER/vmlinuz" ]; then
                VITTA_INITRAMFS_CANDIDATES=$((VITTA_INITRAMFS_CANDIDATES + 1))
                VITTA_INITRAMFS="/usr/lib/modules/$VITTA_KVER/initramfs.img"
            fi
        done
        if [ "$VITTA_INITRAMFS_CANDIDATES" -eq 1 ] && [ -f "$VITTA_INITRAMFS" ]; then
            echo "  ok    initramfs for installed kernel: $VITTA_INITRAMFS"
            VITTA_LSINITRD=$(lsinitrd "$VITTA_INITRAMFS" 2>/dev/null || true)
        else
            echo "  FAIL  expected one installed kernel with vmlinuz and initramfs, found $VITTA_INITRAMFS_CANDIDATES"
            FAIL=1
            VITTA_LSINITRD=""
        fi
        for VITTA_PLY_FILE in $VITTA_PLY_FILES; do
            VITTA_INITRD_FILE="usr/share/plymouth/themes/vitta/$VITTA_PLY_FILE"
            if printf "%s\n" "$VITTA_LSINITRD" | grep -qF " $VITTA_INITRD_FILE"; then echo "  ok    initramfs has $VITTA_INITRD_FILE"; else echo "  FAIL  initramfs ${VITTA_INITRAMFS:-?} lacks $VITTA_INITRD_FILE"; FAIL=1; fi
        done
        for VITTA_INITRD_FILE in usr/lib64/plymouth/script.so usr/lib64/plymouth/label-freetype.so usr/share/fonts/Plymouth.ttf usr/share/fonts/monaspace-neon/MonaspaceNeon-Regular.otf usr/share/fonts/monaspace-neon/MonaspaceNeon-Bold.otf; do
            if printf "%s\n" "$VITTA_LSINITRD" | grep -qF " $VITTA_INITRD_FILE"; then echo "  ok    initramfs has $VITTA_INITRD_FILE"; else echo "  FAIL  initramfs ${VITTA_INITRAMFS:-?} lacks $VITTA_INITRD_FILE"; FAIL=1; fi
        done
        if [ -n "$VITTA_LSINITRD" ] && lsinitrd -f usr/share/plymouth/plymouthd.defaults "$VITTA_INITRAMFS" 2>/dev/null | grep -qx "Theme=vitta"; then echo "  ok    initramfs plymouthd.defaults: Theme=vitta"; else echo "  FAIL  initramfs plymouthd.defaults does not select vitta"; FAIL=1; fi
        # label-freetype loads only these two paths: Plymouth-monospace.ttf for the prompt text, Plymouth.ttf otherwise.
        for VITTA_FONT_LINK in "Plymouth-monospace.ttf -> /usr/share/fonts/monaspace-neon/MonaspaceNeon-Regular.otf" "Plymouth.ttf -> /usr/share/fonts/monaspace-neon/MonaspaceNeon-Bold.otf"; do
            if printf "%s\n" "$VITTA_LSINITRD" | grep -qF " usr/share/fonts/$VITTA_FONT_LINK"; then echo "  ok    initramfs font link $VITTA_FONT_LINK"; else echo "  FAIL  initramfs ${VITTA_INITRAMFS:-?} lacks font link $VITTA_FONT_LINK"; FAIL=1; fi
        done
        # The rebuild must keep what makes the initramfs boot an ostree deployment at all.
        for VITTA_DRACUT_MOD in ostree systemd plymouth vitta-plymouth-font; do
            if printf "%s\n" "$VITTA_LSINITRD" | sed -n "/^dracut modules:/,/^=====/p" | grep -qx "$VITTA_DRACUT_MOD"; then echo "  ok    initramfs dracut module $VITTA_DRACUT_MOD"; else echo "  FAIL  initramfs lacks dracut module $VITTA_DRACUT_MOD"; FAIL=1; fi
        done
        # The splash only shows with rhgb/splash on the command line; those come from the install
        # (rebases keep theirs). Nothing in the image may switch Plymouth off.
        if grep -rhsE "plymouth[.]enable=0|rd[.]plymouth=0|nosplash" /usr/lib/bootc/kargs.d; then echo "  FAIL  a bootc kargs.d entry disables Plymouth"; FAIL=1; else echo "  ok    no bootc kargs.d entry disables Plymouth"; fi
    fi
    echo "Phase 0 bootstrap binaries:"
    for bin in pass gpg pinentry-curses age ssh git jq curl; do check_bin "$bin"; done
    check_rpm pinentry
    # Presence/ownership only: never invoke pinentry in an unattended smoke test.
    if [ "$(rpm -qf --qf "%{NAME}" /usr/bin/pinentry-curses)" != pinentry ]; then
        echo "  FAIL  pinentry-curses must come from the Fedora pinentry package"
        FAIL=1
    fi

    echo "Phase 0 Teams (in /opt, first-boot reflected — check rpm + real path):"
    check_rpm teams-for-linux
    check_file /usr/lib/opt/teams-for-linux/teams-for-linux
    check_file /usr/lib/opt/teams-for-linux/teams-for-linux.real   # wrapper proof
    check_file /etc/teams-for-linux/config.json.default

    echo "Phase 2 system packages:"
    for p in kitty tmux kanshi mate-polkit syncthing swayidle \
             niri waybar pavucontrol NetworkManager-tui blueman SwayNotificationCenter \
             espanso-wayland hyprlock noctalia; do check_rpm "$p"; done
    check_bin noctalia
    check_rpm_vendor niri "Fedora Project"
    check_rpm_vendor noctalia "Fedora Project"
    check_file /etc/yum.repos.d/hyprlock.repo
    check_bin nu
    echo "  info  nushell $(nu --version)"
    if rpm -q noctalia-shell-v5 >/dev/null 2>&1; then
        echo "  FAIL  obsolete noctalia-shell-v5 package still installed"
        FAIL=1
    else
        echo "  ok    obsolete noctalia-shell-v5 absent"
    fi
    # nwg-displays — installed from upstream tarball (not RPM-backed).
    # Verify the binary exists AND the installed source has niri detection
    # (NIRI_SOCKET env-var check) so a regression back to a pre-0.4 build fails fast.
    check_bin nwg-displays
    if ! grep -q NIRI_SOCKET /usr/lib/python3.*/site-packages/nwg_displays/main.py 2>/dev/null; then
        echo "  FAIL: nwg-displays installed but missing NIRI_SOCKET detection (pre-0.4)"
        exit 1
    fi
    echo "  ok    nwg-displays (niri-aware)"
    echo "Phase 3a GUI apps:"
    for p in chromium browserpass browserpass-chromium zen-browser helium-browser-bin; do
        check_rpm "$p"
    done
    echo "Phase 3g Telegram Desktop:"
    check_rpm telegram-desktop
    check_rpm_vendor telegram-desktop "RPM Fusion"
    check_bin Telegram
    check_file /usr/share/applications/org.telegram.desktop.desktop
    check_file /usr/share/dbus-1/services/org.telegram.desktop.service
    check_file /etc/yum.repos.d/rpmfusion-free-telegram.repo
    check_file /etc/pki/rpm-gpg/RPM-GPG-KEY-rpmfusion-free-fedora-2020
    TELEGRAM_REPOS_OK=1
    for TELEGRAM_REPO_SECTION in rpmfusion-free-telegram rpmfusion-free-telegram-updates; do
        if [ "$(grep -Fxc "[$TELEGRAM_REPO_SECTION]" /etc/yum.repos.d/rpmfusion-free-telegram.repo || true)" -ne 1 ]; then
            echo "  FAIL  Telegram repo section $TELEGRAM_REPO_SECTION missing or duplicated"
            FAIL=1
            TELEGRAM_REPOS_OK=0
            continue
        fi
        TELEGRAM_REPO_BLOCK=$(sed -n "/^\\[$TELEGRAM_REPO_SECTION\\]$/,/^\\[/p" /etc/yum.repos.d/rpmfusion-free-telegram.repo)
        for TELEGRAM_REPO_SETTING in \
            "includepkgs=telegram-desktop*" \
            "gpgcheck=1" \
            "gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-rpmfusion-free-fedora-2020"; do
            if ! printf "%s\n" "$TELEGRAM_REPO_BLOCK" | grep -Fxq "$TELEGRAM_REPO_SETTING"; then
                echo "  FAIL  $TELEGRAM_REPO_SECTION missing $TELEGRAM_REPO_SETTING"
                FAIL=1
                TELEGRAM_REPOS_OK=0
            fi
        done
    done
    if [ "$TELEGRAM_REPOS_OK" -eq 1 ]; then
        echo "  ok    RPM Fusion Telegram repos individually scoped and signature-checked"
    fi
    TELEGRAM_KEY_SHA256=$(sha256sum /etc/pki/rpm-gpg/RPM-GPG-KEY-rpmfusion-free-fedora-2020 | cut -d " " -f 1)
    if [ "$TELEGRAM_KEY_SHA256" = "10fc0a3e1a0307e8088357a31a9c5e4e3d9f9e0b01db2b03b5790d949a47f3b3" ]; then
        echo "  ok    RPM Fusion signing key checksum"
    else
        echo "  FAIL  RPM Fusion signing key checksum mismatch"
        FAIL=1
    fi
    if ldd /usr/bin/Telegram 2>&1 | grep -q "not found"; then
        echo "  FAIL  Telegram has unresolved shared libraries"
        ldd /usr/bin/Telegram 2>&1 | grep "not found" || true
        FAIL=1
    else
        echo "  ok    Telegram shared libraries resolved"
    fi
    echo "Phase 3b GUI apps:"
    check_rpm beekeeper-studio
    echo "Proton Authenticator:"
    check_rpm proton-authenticator
    check_bin proton-authenticator
    check_file "/usr/share/applications/Proton Authenticator.desktop"
    if grep -Eq "^Exec=env WEBKIT_DISABLE_DMABUF_RENDERER=1 proton-authenticator([[:space:]].*)?$" "/usr/share/applications/Proton Authenticator.desktop"; then
        echo "  ok    app-scoped NVIDIA WebKit workaround"
    else
        echo "  FAIL  app-scoped NVIDIA WebKit workaround missing"
        FAIL=1
    fi
    if ldd /usr/bin/proton-authenticator 2>&1 | grep -q "not found"; then
        echo "  FAIL: proton-authenticator has unresolved shared libraries"
        ldd /usr/bin/proton-authenticator 2>&1 | grep "not found" || true
        FAIL=1
    else
        echo "  ok    proton-authenticator shared libraries resolved"
    fi
    echo "Proton Mail desktop:"
    check_rpm proton-mail
    check_bin proton-mail
    check_file /usr/share/applications/proton-mail.desktop
    check_file "/usr/lib/proton-mail/Proton Mail Beta"
    check_file /usr/lib/proton-mail/chrome-sandbox
    if ! grep -q "^MimeType=.*x-scheme-handler/mailto" /usr/share/applications/proton-mail.desktop; then
        echo "  FAIL: proton-mail desktop entry lost mailto handling"
        FAIL=1
    else
        echo "  ok    proton-mail mailto handler"
    fi
    if ldd "/usr/lib/proton-mail/Proton Mail Beta" 2>&1 | grep -q "not found"; then
        echo "  FAIL: proton-mail has unresolved shared libraries"
        ldd "/usr/lib/proton-mail/Proton Mail Beta" 2>&1 | grep "not found" || true
        FAIL=1
    else
        echo "  ok    proton-mail shared libraries resolved"
    fi

    echo "Baked GPG keys (insulate build from upstream key-host outages):"
    # Terra signs each Fedora release with its own key; terra.repo uses
    # $releasever, so the key for the booted release must be baked.
    check_file /etc/pki/rpm-gpg/RPM-GPG-KEY-terra-$(rpm -E %fedora)
    check_file /etc/pki/rpm-gpg/RPM-GPG-KEY-beekeeper-studio
    check_file /etc/yum.repos.d/terra.repo
    check_file /etc/yum.repos.d/beekeeper-studio.repo
    echo "Phase 3c additions:"
    check_rpm zed
    # Terra zed is zfs-collision-aware: editor binary is zeditor and
    # /usr/bin/zed must stay owned by the zfs package. A monolithic che/zed
    # style zed would fail the build at the rpm-ostree conflict; this catches
    # a silent regression too. This block runs inside a single-quoted run -c
    # wrapper, so use only DOUBLE quotes here. A single quote or backtick in
    # this region breaks out of the wrapper.
    # Upstream installs zfs ONLY on bluefin-dx :stable (ublue-os/bluefin
    # build_files/base/03-install-kernel-akmods.sh, "ZFS for stable"); the
    # :latest canary has none. Terra zed then installs plain zed-cli and there
    # is no zeditor. Dotfiles launch "zeditor", so losing zfs upstream (e.g. a
    # base without ublue akmods) changes the editor command - see MAINTENANCE.md.
    # Vitta has no zfs by design, so Terra resolves plain zed-cli; the
    # zeditor name dotfiles launch is the files/vitta symlink zeditor -> zed.
    if [ "$RECIPE_NAME" = "vitta" ]; then
        if rpm -qf /usr/bin/zed 2>/dev/null | grep -q "^zed-cli-"; then
            echo "  ok    /usr/bin/zed owned by Terra zed-cli (no zfs on Vitta)"
        else
            echo "  FAIL  Vitta /usr/bin/zed not owned by Terra zed-cli"
            FAIL=1
        fi
        if [ "$(readlink /usr/bin/zeditor)" = zed ] && [ -x /usr/bin/zeditor ]; then
            echo "  ok    /usr/bin/zeditor -> zed (Vitta overlay link)"
        else
            echo "  FAIL  /usr/bin/zeditor is not a working link to zed"
            FAIL=1
        fi
    elif rpm -q zfs >/dev/null 2>&1; then
        check_bin zeditor
        if rpm -qf /usr/bin/zed 2>/dev/null | grep -q "^zfs-"; then
            echo "  ok    /usr/bin/zed owned by zfs (editor is zeditor)"
        else
            echo "  FAIL: /usr/bin/zed not owned by zfs - monolithic zed reintroduced the collision"
            exit 1
        fi
    elif rpm -qf /usr/bin/zed 2>/dev/null | grep -q "^zed-cli-"; then
        echo "  WARN  base ships no zfs: editor is zed (zed-cli), zeditor absent - dotfiles expect zeditor"
    else
        echo "  FAIL: no zfs and /usr/bin/zed not owned by Terra zed-cli"
        exit 1
    fi
    check_rpm postgresql
    check_bin psql
    check_rpm wtype
    check_bin wtype
    check_rpm grim
    check_bin grim
    check_rpm slurp
    check_bin slurp
    check_rpm wl-mirror
    check_bin wl-mirror

    echo "Phase 3f Noctalia Screen Toolkit host dependencies:"
    check_rpm tesseract
    check_bin tesseract
    check_rpm tesseract-langpack-eng
    check_rpm tesseract-langpack-nld
    TESS_LANGS=$(tesseract --list-langs 2>/dev/null || true)
    for lang in eng nld; do
        if grep -qx "$lang" <<< "$TESS_LANGS"; then
            echo "  ok    tesseract language $lang"
        else
            echo "  MISS  tesseract language $lang"
            FAIL=1
        fi
    done
    if rpm -q pass-otp >/dev/null 2>&1; then
        echo "  FAIL  pass-otp installed despite Proton Authenticator owning OTP"
        FAIL=1
    else
        echo "  ok    pass-otp deliberately absent"
    fi
    if command -v wl-screenrec >/dev/null 2>&1; then
        echo "  FAIL  wl-screenrec present despite no approved Fedora package source"
        FAIL=1
    else
        echo "  ok    unmaintainable wl-screenrec absent"
    fi
    check_rpm wf-recorder
    check_bin wf-recorder
    check_rpm gpu-screen-recorder
    check_bin gpu-screen-recorder
    check_bin gsr-kms-server
    check_file /etc/yum.repos.d/gpu-screen-recorder.repo
    check_rpm_vendor gpu-screen-recorder "Fedora Copr - user lionheartp"
    if grep -qx "excludepkgs=gpu-screen-recorder" /etc/yum.repos.d/terra.repo; then
        echo "  ok    gpu-screen-recorder excluded from competing Terra repo"
    else
        echo "  FAIL  Terra can override the approved gpu-screen-recorder source"
        FAIL=1
    fi
    if grep -qx "includepkgs=gpu-screen-recorder" /etc/yum.repos.d/gpu-screen-recorder.repo; then
        echo "  ok    gpu-screen-recorder COPR is exact-package scoped"
    else
        echo "  FAIL  gpu-screen-recorder COPR scope widened or missing"
        FAIL=1
    fi
    GSR_VERSION=$(rpm -q --qf "%{VERSION}" gpu-screen-recorder 2>/dev/null || true)
    if [ "$(printf "%s\n" "6.0.2" "$GSR_VERSION" | sort -V | head -n1)" != "6.0.2" ]; then
        echo "  FAIL  gpu-screen-recorder ${GSR_VERSION:-missing} is older than required 6.0.2"
        FAIL=1
    else
        echo "  ok    gpu-screen-recorder $GSR_VERSION (>= 6.0.2)"
    fi
    GSR_CAP=$(/usr/sbin/getcap /usr/bin/gsr-kms-server 2>/dev/null || true)
    if [ "$GSR_CAP" = "/usr/bin/gsr-kms-server cap_sys_admin=ep" ]; then
        echo "  ok    gsr-kms-server capability: cap_sys_admin=ep"
    else
        echo "  FAIL  gsr-kms-server capability missing or broader than cap_sys_admin=ep: ${GSR_CAP:-none}"
        FAIL=1
    fi
    if ldd /usr/bin/gpu-screen-recorder 2>&1 | grep -q "not found"; then
        echo "  FAIL  gpu-screen-recorder has unresolved shared libraries"
        ldd /usr/bin/gpu-screen-recorder 2>&1 | grep "not found" || true
        FAIL=1
    else
        echo "  ok    gpu-screen-recorder shared libraries resolved"
    fi
    if zgrep -Fq "default_output|default_input" /usr/share/man/man1/gpu-screen-recorder.1.gz; then
        echo "  ok    gpu-screen-recorder documents combined system and microphone audio"
    else
        echo "  FAIL  gpu-screen-recorder combined-audio CLI contract missing"
        FAIL=1
    fi
    for encoder in h264_vaapi h264_nvenc; do
        if ffmpeg -hide_banner -encoders 2>/dev/null | grep -qw "$encoder"; then
            echo "  ok    ffmpeg encoder $encoder"
        else
            echo "  MISS  ffmpeg encoder $encoder"
            FAIL=1
        fi
    done

    echo "Phase 3d OBS Studio + v4l2loopback:"
    check_rpm obs-studio
    check_bin obs
    check_rpm obs-studio-plugin-vaapi
    check_rpm v4l-utils
    check_bin v4l2-ctl
    check_rpm mediainfo
    check_bin mediainfo
    # ublue-signed kmod (from ghcr.io/ublue-os/akmods main flavor).
    # Package name is `kmod-v4l2loopback` (meta) — backed by a versioned
    # `kmod-v4l2loopback-<kernel>` sub-package. Check the meta.
    # bluefin-dx ships the ublue-signed kmod; Vitta builds the same one
    # with the akmods module in vitta-modules.yml.
    check_rpm kmod-v4l2loopback
    check_file /etc/modules-load.d/v4l2loopback.conf
    check_file /etc/modprobe.d/v4l2loopback.conf
    # Pin sentinel: v4l2loopback should be pinned to /dev/video10 — keeps
    # real cameras at the low /dev/videoN slots they would otherwise grab.
    if ! grep -q "video_nr=10" /etc/modprobe.d/v4l2loopback.conf; then
        echo "  FAIL: /etc/modprobe.d/v4l2loopback.conf missing video_nr=10 pin"
        exit 1
    fi
    echo "  ok    video_nr=10 pin"

    echo "Phase 3e showmethekey:"
    check_rpm showmethekey
    check_bin showmethekey-gtk
    check_file /etc/yum.repos.d/showmethekey.repo
    SHOWMETHEKEY_VERSION=$(rpm -q --qf "%{VERSION}" showmethekey 2>/dev/null || true)
    if [ "$(printf "%s\n" "1.21.0" "$SHOWMETHEKEY_VERSION" | sort -V | head -n1)" != "1.21.0" ]; then
        echo "  FAIL: showmethekey ${SHOWMETHEKEY_VERSION:-missing} is older than required 1.21.0"
        FAIL=1
    else
        echo "  ok    showmethekey $SHOWMETHEKEY_VERSION (>= 1.21.0)"
    fi
    # Polkit rule ships in the RPM — confirm at least one polkit-1 file from
    # the package landed under /usr/share/. Filename varies by version
    # (me.alynx.* in 1.17.x; renamed later); glob instead of hardcoding.
    if ! rpm -ql showmethekey 2>/dev/null | grep -q "/usr/share/polkit-1/"; then
        echo "  FAIL: showmethekey RPM ships no /usr/share/polkit-1/ rule — input access would prompt for sudo"
        exit 1
    fi
    echo "  ok    polkit rule shipped"

    # Fontconfig. ALWAYS use /usr/bin/fc-* explicitly: on a dev host, Homebrew
    # fontconfig 2.18 sits first on PATH, reads its OWN fonts.conf and cache
    # format, and can report HEALTHY while the image system fontconfig sees zero
    # fonts. Helium can map more than one cache format, so never infer runtime
    # health from a single cache suffix. A bare fc-list here would be a green
    # light on a broken image.
    #
    # NOTE: this block runs inside a single-quoted run -c wrapper. Use ONLY
    # double quotes. No apostrophes in comments either - they break the wrapper.
    echo "Fontconfig - fonts actually resolvable:"
    if /usr/bin/fc-list | grep -qi "Noto Color Emoji"; then echo "  ok    fc-list Noto Color Emoji"; else echo "  MISS  fc-list Noto Color Emoji"; FAIL=1; fi
    if /usr/bin/fc-match emoji | grep -q "Noto Color Emoji"; then echo "  ok    fc-match emoji"; else echo "  MISS  fc-match emoji"; FAIL=1; fi
    # BEHAVIOURAL checks, not presence checks. The old gate asserted only emoji and
    # would have passed green with every serif font on the machine invisible -
    # precisely the failure that shipped. "Noto Serif" is the canary that both
    # fc-cache-boot.sh and rebuild-font-cache.sh depend on, so assert it here or
    # those guards silently self-disable if the base image ever drops it.
    if /usr/bin/fc-list | grep -qi "Noto Serif"; then echo "  ok    fc-list Noto Serif (canary present)"; else echo "  MISS  fc-list Noto Serif - fc-cache-boot canary would wipe the cache every boot"; FAIL=1; fi
    if /usr/bin/fc-list | grep -q "^/usr/share/fonts"; then echo "  ok    /usr/share/fonts contributes fonts"; else echo "  MISS  /usr/share/fonts contributes ZERO fonts"; FAIL=1; fi
    # The user-visible symptom: with system fonts invisible, generic serif loses to
    # a Nerd Font by glyph coverage and Chromium renders a monospace for serif.
    if /usr/bin/fc-match serif | grep -qi "nerd font"; then
        echo "  MISS  fc-match serif resolves to a Nerd Font (monospace) - system fonts are hidden"; FAIL=1
    else
        echo "  ok    fc-match serif is not a Nerd Font"
    fi
    if [ "$RECIPE_NAME" = "vitta" ]; then
        MONASPACE_NEON_COUNT=$(ls /usr/share/fonts/monaspace-neon/*.otf | wc -l)
        if [ "$MONASPACE_NEON_COUNT" -eq 42 ]; then
            echo "  ok    Monaspace Neon has 42 OTF files"
        else
            echo "  MISS  Monaspace Neon has ${MONASPACE_NEON_COUNT} OTF files, expected 42"; FAIL=1
        fi
        MONASPACE_NEON_FILE=$(/usr/bin/fc-match -f "%{file}" "Monaspace Neon")
        case "$MONASPACE_NEON_FILE" in
            /usr/share/fonts/monaspace-neon/*) echo "  ok    fc-match Monaspace Neon resolves to monaspace-neon" ;;
            *) echo "  MISS  fc-match Monaspace Neon resolves to ${MONASPACE_NEON_FILE:-missing}"; FAIL=1 ;;
        esac
    fi

    # Container-collision hardening. distrobox shares $HOME, but its system font
    # tree differs from the host. 06-bluefin-host-font-dir-salt.conf gives every
    # host system font directory a distinct cache key at every cache version.
    # The epoch stamp remains composefs cache hygiene, not the collision boundary.
    echo "Fontconfig - container-collision hardening:"
    check_file /etc/fonts/conf.d/05-bluefin-writable-cache.conf
    check_file /etc/fonts/conf.d/06-bluefin-host-font-dir-salt.conf
    check_file /usr/lib/tmpfiles.d/fontconfig-var-cache.conf
    check_file /usr/lib/systemd/system/fc-cache-boot.service
    check_file /usr/libexec/bluefin-udx/fc-cache-boot.sh
    if [ -x /usr/libexec/bluefin-udx/fc-cache-boot.sh ]; then
        echo "  ok    fc-cache-boot.sh is executable"
    else
        echo "  MISS  fc-cache-boot.sh not executable - unit would fail at boot"; FAIL=1
    fi
    # Assert the actual cachedir ELEMENT, not just the string: the file header
    # comment mentions the path a dozen times, so a substring grep passed even
    # when the element itself was absent.
    if grep -q "<cachedir>/var/cache/fontconfig</cachedir>" /etc/fonts/conf.d/05-bluefin-writable-cache.conf; then
        echo "  ok    /var/cache/fontconfig cachedir element present"
    else
        echo "  MISS  /var/cache/fontconfig cachedir element missing"; FAIL=1
    fi
    if grep -Eq "^[[:space:]]*<reset-dirs" /etc/fonts/conf.d/06-bluefin-host-font-dir-salt.conf; then
        echo "  MISS  host font salt resets configured directories"; FAIL=1
    fi
    for FONT_DIR in /usr/share/fonts /usr/local/share/fonts /usr/share/X11/fonts/Type1 /usr/share/X11/fonts/TTF; do
        if grep -Fxq "  <dir salt=\"bluefin-udx-host\">$FONT_DIR</dir>" /etc/fonts/conf.d/06-bluefin-host-font-dir-salt.conf; then
            echo "  ok    salted host font directory $FONT_DIR"
        else
            echo "  MISS  salted host font directory $FONT_DIR"; FAIL=1
        fi
    done
    if grep -q "touch -d @0" /usr/libexec/bluefin-udx/fc-cache-boot.sh; then
        echo "  ok    boot script retains the epoch stamp"
    else
        echo "  MISS  boot script no longer epoch-stamps the cache"; FAIL=1
    fi
    # The baked cache must survive into the image. It used to land in /var and be
    # deleted by post_build.sh, making the build-time bake a silent no-op.
    ROOT_KEY=$(printf %s /usr/share/fontsbluefin-udx-host | md5sum | cut -d " " -f1)
    if compgen -G "/usr/lib/fontconfig/cache/${ROOT_KEY}-*.cache-*" >/dev/null; then
        echo "  ok    salted root cache baked in /usr/lib/fontconfig/cache"
    else
        echo "  MISS  salted root cache missing from /usr/lib/fontconfig/cache"; FAIL=1
    fi
    # The host directory salt is version-neutral; retain a warning for the
    # secondary epoch-stamp selection behavior when fontconfig changes.
    FC_VER=$(/usr/bin/fc-cache --version 2>&1 | grep -oE "[0-9]+[.][0-9]+" | head -1)
    case "$FC_VER" in
        2.17|2.16|2.15) echo "  ok    fontconfig $FC_VER (epoch-stamp behavior verified)" ;;
        *) echo "  WARN  fontconfig $FC_VER - re-verify secondary epoch-stamp behavior; directory salt remains required" ;;
    esac

    # NVIDIA variant adds nvtop. CUDA toolkit intentionally not baked —
    # incompatible with atomic /usr/local redirect; use nvidia/cuda containers
    # per project instead. See bluefin-udx-nvidia.yml for full rationale.
    if [ "$RECIPE_NAME" = "bluefin-udx-nvidia" ]; then
        echo "Phase 4 NVIDIA additions:"
        check_rpm nvtop
        check_bin nvtop
        # Base bluefin-dx-nvidia-open already provides:
        check_bin nvidia-smi
        check_bin nvidia-ctk
    fi

    exit $FAIL
'

echo
echo "==> Smoke-boot PASSED for $RECIPE"
