#!/bin/bash
# Runs INSIDE the vitta-bootsplash-preview container (see
# scripts/vitta-bootsplash-preview.sh). Starts the stock Fedora plymouthd with
# the x11 renderer on an Xvfb screen, drives it with the stock `plymouth`
# client and captures the screen. /theme = the theme dir, /out = output dir.
set -euo pipefail

# Hard stop if any real display or console is visible: plymouthd must never
# get near the host's screen.
for dev in /dev/dri /dev/fb0 /dev/tty0 /dev/tty1 /dev/console; do
  if [ -e "$dev" ]; then
    echo "render.sh: refusing to run, $dev is visible in the container" >&2
    exit 1
  fi
done

OUT=/out
mkdir -p "$OUT" /var/lib/plymouth /run/plymouth /var/spool/plymouth
rm -rf /usr/share/plymouth/themes/vitta
cp -r /theme /usr/share/plymouth/themes/vitta
sed -i "s/^Theme=.*/Theme=vitta/" /usr/share/plymouth/plymouthd.defaults

# Text exactly as in the initramfs: plymouthd prefers label-pango, but only
# label-freetype is in the initramfs, and there is no fc-match there, so it
# loads /usr/share/fonts/Plymouth{,-monospace}.ttf, which the
# vitta-plymouth-font dracut module links to Monaspace Neon Bold / Regular.
# FONTLESS=1 links them to a missing file instead (fail-safe check: no text,
# but the prompt must still take a passphrase).
PLUGIN_DIR=$(plymouth --get-splash-plugin-path)
rm -f "${PLUGIN_DIR}label-pango.so"
test -f "${PLUGIN_DIR}label-freetype.so"
if [ -e /usr/bin/fc-match ]; then mv /usr/bin/fc-match /usr/bin/fc-match.off; fi
FONT_DIR=/usr/share/fonts/monaspace-neon
if [ "${FONTLESS:-0}" = 1 ]; then FONT_DIR=/nonexistent; fi
ln -sfn "$FONT_DIR/MonaspaceNeon-Regular.otf" /usr/share/fonts/Plymouth-monospace.ttf
ln -sfn "$FONT_DIR/MonaspaceNeon-Bold.otf" /usr/share/fonts/Plymouth.ttf
# plymouthd picks the x11 renderer only when DISPLAY is set and x11.so exists.
test -f "$(plymouth --get-splash-plugin-path)renderers/x11.so"
rpm -q plymouth plymouth-plugin-script plymouth-plugin-label plymouth-devel > "$OUT/versions.txt"

XPID=""
PPID_PLY=""
cleanup() {
  if [ -n "$PPID_PLY" ]; then kill "$PPID_PLY" 2>/dev/null || true; fi
  if [ -n "$XPID" ]; then kill "$XPID" 2>/dev/null || true; fi
  wait 2>/dev/null || true
}
trap cleanup EXIT

start_x() {
  Xvfb :9 -screen 0 "${1}x24" -dpi 96 -nolisten tcp >/dev/null 2>&1 &
  XPID=$!
  export DISPLAY=:9
  for _ in $(seq 50); do
    xdotool getdisplaygeometry >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  echo "Xvfb did not come up" >&2
  return 1
}

start_plymouth() { # $1 = mode, $2 = log name
  plymouthd --no-daemon --debug --debug-file="$OUT/$2.log" --mode="$1" \
    --kernel-command-line="rhgb quiet splash plymouth.ignore-udev" &
  PPID_PLY=$!
  for _ in $(seq 50); do
    plymouth --ping 2>/dev/null && break
    sleep 0.1
  done
  plymouth show-splash
  # Point the (WM-less) X focus at the splash window for typed input. No
  # --sync: Xvfb starts with the pointer at the centre already, and --sync
  # would then wait for a motion event that never comes.
  xdotool mousemove $(( W / 2 )) $(( H / 2 + 1 ))
}

stop_all() {
  plymouth quit 2>/dev/null || true
  sleep 0.5
  kill "$PPID_PLY" 2>/dev/null || true
  wait "$PPID_PLY" 2>/dev/null || true
  PPID_PLY=""
  kill "$XPID" 2>/dev/null || true
  wait "$XPID" 2>/dev/null || true
  XPID=""
}

shot() { # $1 = file stem
  sleep "${2:-0.6}"
  xwd -root -silent | magick xwd:- "PNG24:$OUT/$1.png"
  echo "captured $1.png"
}

# --- 1. splash at the T580 size: progress 0 / 0.5 / 1.0 and a message ---------
# "updates" mode: the theme then ignores Plymouth's time-based boot progress
# and follows `plymouth system-update --progress=N`, so the frames show exact
# progress values through the same set_target -> place_bands path a boot uses.
MAIN=${MAIN_SIZE:-1920x1080}
W=${MAIN%x*}; H=${MAIN#*x}
start_x "$MAIN"
start_plymouth updates "plymouthd-$MAIN-updates"
plymouth system-update --progress=0
shot "bootsplash-progress-0" 1
plymouth system-update --progress=50
shot "bootsplash-progress-0.5"
plymouth display-message --text="Started vitta-groups.service - Vitta group reconciliation"
shot "bootsplash-message"
plymouth hide-message --text="Started vitta-groups.service - Vitta group reconciliation"
plymouth system-update --progress=100
shot "bootsplash-progress-1.0"

stop_all

# --- 1b. LUKS prompt screen (R25) at the main size, splash at progress 0.6 ----
# Like systemd-cryptsetup: ask, the passphrase is wrong, cryptsetup asks again
# with the same text (red border, bullets cleared), then the right one. The
# client blocks until Enter, so it runs in the background while X gets keys.
start_x "$MAIN"
start_plymouth updates "plymouthd-$MAIN-luks"
plymouth system-update --progress=60
shot "luks-splash-0.6" 1
LUKS_PROMPT="Please enter passphrase for disk SAMSUNG MZVL2512HCJQ-00BL7 (luks-7997c48e):"
plymouth ask-for-password --prompt="$LUKS_PROMPT" > "$OUT/luks-answer-1.txt" &
ASK=$!
shot "luks-password-empty"
xdotool type --delay 40 "wrongpw1"
shot "luks-password-8"
xdotool key Return
wait "$ASK"
plymouth ask-for-password --prompt="$LUKS_PROMPT" > "$OUT/luks-answer-2.txt" &
ASK=$!
shot "luks-password-wrong"
xdotool type --delay 40 "hunter2!"
shot "luks-password-retry-typing"
xdotool key Return
wait "$ASK"
shot "luks-normal-0.6" 1

plymouth ask-question --prompt="Type yes to continue:" > "$OUT/luks-question-answer.txt" &
ASK=$!
sleep 0.6
xdotool type --delay 40 "yes"
shot "luks-question"
xdotool key Return
wait "$ASK"

# A boot message stays hidden behind the prompt screen and comes back after.
plymouth display-message --text="Started systemd-cryptsetup@luks.service"
# A long prompt wraps onto several centred lines. The boot protocol caps a
# prompt at 255 bytes (ply-boot-client.c asserts it), so this is about the
# longest cryptsetup can send.
LONG_PROMPT="Please enter passphrase for disk WDC WD40EFRX-68N32N0 Western Digital Red Plus NAS internal hard drive (luks-2b6f9a4e-8c1d-4f3a-9e7b-5d2c1a0f8e6b) attached via the USB 3.2 Gen 2 enclosure on port 4 of the Thunderbolt dock, second bay:"
test "${#LONG_PROMPT}" -le 255
plymouth ask-for-password --prompt="$LONG_PROMPT" > "$OUT/luks-answer-long.txt" &
ASK=$!
sleep 0.6
xdotool type --delay 30 "abc"
shot "luks-password-long"
xdotool key Return
wait "$ASK"
shot "luks-normal-message" 1
stop_all

# --- 2. real boot mode: bands follow Plymouth's own time-based progress ---------
start_x "$MAIN"
start_plymouth boot "plymouthd-$MAIN-boot"
shot "bootsplash-boot-t2s" 2
shot "bootsplash-boot-t8s" 6
stop_all

# --- 3. other common sizes: LUKS prompt screen with 8 typed characters ---------
for size in ${EXTRA_SIZES:-1366x768 1280x800 1920x1200 2560x1440 2560x1600 3840x2160 1024x768}; do
  W=${size%x*}; H=${size#*x}
  start_x "$size"
  start_plymouth updates "plymouthd-$size-updates"
  plymouth system-update --progress=50
  plymouth ask-for-password --prompt="Please enter passphrase for disk SAMSUNG MZVL2512HCJQ-00BL7 (luks-7997c48e):" >/dev/null &
  ASK=$!
  sleep 0.5
  xdotool type --delay 20 "secret12"
  shot "luks-$size-password"
  xdotool key Return
  wait "$ASK"
  stop_all
done

# --- 4. HiDPI: device scale 2 (Plymouth's choice on ~4K laptop panels) --------
# The script then sees a 1920x1080 logical window; images are drawn 2x.
W=3840; H=2160
start_x 3840x2160
export PLYMOUTH_FORCE_SCALE=2
start_plymouth updates "plymouthd-3840x2160-scale2-updates"
unset PLYMOUTH_FORCE_SCALE
plymouth system-update --progress=50
shot "bootsplash-3840x2160-scale2-progress-0.5" 1
stop_all
