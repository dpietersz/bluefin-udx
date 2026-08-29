#!/usr/bin/env bash
# Build a recipe locally with bluebuild and run a smoke-test against the result.
# Mirrors the CI smoke-boot gate so failures surface in ~5 min on your laptop
# instead of after a GH Actions run.
#
# Usage:
#   ./scripts/local-build-test.sh                  # builds bluefin-udx
#   ./scripts/local-build-test.sh bluefin-udx-nvidia

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
        RPM_NEVRA=$(rpm -q --qf "%{NAME}-%{EPOCHNUM}:%{VERSION}-%{RELEASE}.%{ARCH}" "$1" 2>/dev/null || true)
        if [ -n "$RPM_NEVRA" ]; then echo "  ok    rpm $RPM_NEVRA"; else echo "  MISS  rpm $1"; FAIL=1; fi
    }
    check_rpm_vendor() {
        RPM_VENDOR=$(rpm -q --qf "%{VENDOR}" "$1" 2>/dev/null || true)
        if [ "$RPM_VENDOR" = "$2" ]; then echo "  ok    $1 vendor: $RPM_VENDOR"; else echo "  FAIL  $1 vendor: ${RPM_VENDOR:-missing}, expected $2"; FAIL=1; fi
    }

    echo "Phase 0 bootstrap binaries:"
    for bin in pass gpg age ssh git jq curl; do check_bin "$bin"; done

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
    check_file /etc/pki/rpm-gpg/RPM-GPG-KEY-terra-44
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
    check_bin zeditor
    if rpm -qf /usr/bin/zed 2>/dev/null | grep -q "^zfs-"; then
        echo "  ok    /usr/bin/zed owned by zfs (editor is zeditor)"
    else
        echo "  FAIL: /usr/bin/zed not owned by zfs - monolithic zed reintroduced the collision"
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
    # fontconfig 2.18 sits first on PATH, reads its OWN fonts.conf, cannot read
    # the system cache-9 files, and reports HEALTHY while the system fontconfig
    # (the one Helium/Electron link) sees zero fonts. A bare fc-list here would
    # be a green light on a broken image.
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

    # Container-collision fix. distrobox shares $HOME, so ~/.cache/fontconfig is
    # shared with every toolbox; fontconfig keys caches on md5(dir path) and
    # /usr/share/fonts means something different inside an Ubuntu box. Cachedir
    # ORDER cannot save us (conf.d is included before the cachedir block, so
    # /var/cache/fontconfig can only be FIRST, and first loses). The fix is the
    # epoch stamp, which triggers the fontconfig OSTree branch in FcCacheTimeValid
    # and wins from any position. See fc-cache-boot.sh for the evidence table.
    echo "Fontconfig - container-collision hardening:"
    check_file /etc/fonts/conf.d/05-bluefin-writable-cache.conf
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
    # The epoch stamp IS the fix - assert it is actually still in the script.
    if grep -q "touch -d @0" /usr/libexec/bluefin-udx/fc-cache-boot.sh; then
        echo "  ok    boot script epoch-stamps the cache"
    else
        echo "  MISS  boot script no longer epoch-stamps - container-collision fix is GONE"; FAIL=1
    fi
    # The baked cache must survive into the image. It used to land in /var and be
    # deleted by post_build.sh, making the build-time bake a silent no-op.
    if ls /usr/lib/fontconfig/cache/*.cache-* >/dev/null 2>&1; then
        echo "  ok    baked cache present in /usr/lib/fontconfig/cache"
    else
        echo "  MISS  /usr/lib/fontconfig/cache has no cache files - build-time bake was a no-op"; FAIL=1
    fi
    # Version coupling: the epoch trick is verified on fontconfig 2.17. On 2.18 the
    # selection rule changes to newest-mtime-wins. Warn loudly on a major bump.
    FC_VER=$(/usr/bin/fc-cache --version 2>&1 | grep -oE "[0-9]+[.][0-9]+" | head -1)
    case "$FC_VER" in
        2.17|2.16|2.15) echo "  ok    fontconfig $FC_VER (epoch-stamp behaviour verified)" ;;
        *) echo "  WARN  fontconfig $FC_VER - epoch-stamp fix verified on 2.17 only; RE-VERIFY (see fc-cache-boot.sh caveat)" ;;
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
