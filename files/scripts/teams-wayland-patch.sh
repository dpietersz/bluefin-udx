#!/usr/bin/env bash
# Teams Wayland integration patch — run at image build time.
# Ported from boxkit/scripts/browser-toolbox.sh (Arch/AUR version) to Fedora paths.
#
# Two things this does:
#  1. Rewrites the upstream teams-for-linux .desktop Exec line so screen sharing
#     works on Wayland via the xdg-desktop-portal + PipeWire pipeline.
#     --ozone-platform-hint=auto must be a CLI flag — the upstream config does
#     not honor it via electronCLIFlags.
#  2. Wraps the binary so /etc/teams-for-linux/config.json.default is seeded into
#     the user's $XDG_CONFIG_HOME on first launch. The default config keeps
#     hardware accel on (Teams auto-disables it on Wayland, which makes screen
#     sharing blurry) and uses WakeLockSentinel to keep the screen awake during
#     calls without the legacy Electron API that breaks under Wayland.

set -euo pipefail

# ---------- 1. .desktop patch ---------------------------------------------
TEAMS_EXEC='Exec=/usr/bin/teams-for-linux --ozone-platform-hint=auto --enable-features=WebRTCPipeWireCapturer,WaylandWindowDecorations --enable-webrtc-pipewire-capturer %U'

for TEAMS_DESKTOP in \
    /usr/share/applications/teams-for-linux.desktop \
    /usr/share/applications/com.github.IsmaelMartinez.teams_for_linux.desktop; do
    [ -f "$TEAMS_DESKTOP" ] || continue
    sed -i -E "s|^Exec=.*teams-for-linux.*$|$TEAMS_EXEC|" "$TEAMS_DESKTOP"
    echo "[teams-patch] rewrote Exec line in $TEAMS_DESKTOP"
done

# ---------- 2. Default config ---------------------------------------------
mkdir -p /etc/teams-for-linux
# followSystemTheme MUST be false on teams-for-linux 2.11.x. 2.11.0 flipped the
# default to true (upstream PR #2566), which makes the client write
# followOsTheme=true into Teams' clientPreferences; because this client can't
# supply a HostTheme value, Teams' GraphQL mutation rejects it and the Dark theme
# toggle silently stops working (upstream issue #2662). 2.12.0 (PR #2673) fixes
# the root cause but keeps the true default, so this explicit opt-out is correct
# on both. Mirrored in dotfiles dot_config/teams-for-linux/config.json.
cat > /etc/teams-for-linux/config.json.default <<'EOF'
{
  "followSystemTheme": false,
  "disableGpu": false,
  "screenSharing": {
    "lockInhibitionMethod": "WakeLockSentinel"
  },
  "wayland": {
    "xwaylandOptimizations": false
  }
}
EOF

# ---------- 3. Binary wrapper (seeds config on first run) ------------------
# Locate the actual binary. Fedora RPM from teamsforlinux.de installs at
# /usr/bin/teams-for-linux (symlink or binary). Probe known locations.
TEAMS_BIN=""
for candidate in \
    /usr/bin/teams-for-linux \
    /usr/local/bin/teams-for-linux \
    /opt/teams-for-linux/teams-for-linux \
    /usr/lib/teams-for-linux/teams-for-linux \
    /usr/share/teams-for-linux/teams-for-linux; do
    if [ -x "$candidate" ] && [ ! -d "$candidate" ]; then
        TEAMS_BIN="$candidate"
        break
    fi
done

if [ -z "$TEAMS_BIN" ]; then
    # Fall back to rpm's file list — equivalent to the boxkit pacman -Ql probe.
    TEAMS_BIN=$(rpm -ql teams-for-linux 2>/dev/null \
        | awk '/\/teams-for-linux$/ {print}' \
        | while read -r p; do
            if [ -x "$p" ] && [ ! -d "$p" ]; then echo "$p"; break; fi
          done)
fi

if [ -z "$TEAMS_BIN" ]; then
    echo "WARN: teams-for-linux binary not found in known paths or rpm file list;"
    echo "      skipping wrapper. Teams still launches, but the default config"
    echo "      won't be auto-seeded. Inspect with: rpm -ql teams-for-linux"
    exit 0
fi

# If TEAMS_BIN is a symlink (common on Fedora), resolve to the real file before
# wrapping — moving a symlink and writing a wrapper at its path can break.
TEAMS_BIN="$(readlink -f "$TEAMS_BIN")"
TEAMS_REAL="${TEAMS_BIN}.real"

# Idempotent: if we've already wrapped on a previous build layer, skip.
if [ -f "$TEAMS_REAL" ]; then
    echo "[teams-patch] wrapper already present at $TEAMS_BIN, skipping"
    exit 0
fi

mv "$TEAMS_BIN" "$TEAMS_REAL"
cat > "$TEAMS_BIN" <<EOF
#!/bin/sh
CFG_DIR="\${XDG_CONFIG_HOME:-\$HOME/.config}/teams-for-linux"
if [ ! -f "\$CFG_DIR/config.json" ] && [ -f /etc/teams-for-linux/config.json.default ]; then
  mkdir -p "\$CFG_DIR"
  cp /etc/teams-for-linux/config.json.default "\$CFG_DIR/config.json"
fi
exec $TEAMS_REAL "\$@"
EOF
chmod +x "$TEAMS_BIN"
echo "[teams-patch] installed wrapper at $TEAMS_BIN -> $TEAMS_REAL"
