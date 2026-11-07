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

# --- 1. full set at the T580 size: progress 0 / 0.5 / 1.0, prompts, messages ---
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

# Password prompt, like systemd-cryptsetup asks for a LUKS passphrase. The
# client blocks until Enter, so run it in the background and type into X.
plymouth ask-for-password --prompt="Please enter passphrase for disk SAMSUNG MZVL2512 (luks-3f0c):" \
  > "$OUT/password-answer.txt" &
ASK=$!
sleep 0.6
shot "bootsplash-password-empty"
xdotool type --delay 40 "hunter2-correct"
shot "bootsplash-password"
xdotool key Return
wait "$ASK"
shot "bootsplash-password-done"

plymouth ask-question --prompt="Type yes to continue:" > "$OUT/question-answer.txt" &
ASK=$!
sleep 0.6
xdotool type --delay 40 "yes"
shot "bootsplash-question"
xdotool key Return
wait "$ASK"
stop_all

# --- 2. real boot mode: bands follow Plymouth's own time-based progress ---------
start_x "$MAIN"
start_plymouth boot "plymouthd-$MAIN-boot"
shot "bootsplash-boot-t2s" 2
shot "bootsplash-boot-t8s" 6
stop_all

# --- 3. other common sizes, progress 0.5 and a password prompt ------------------
for size in ${EXTRA_SIZES:-1366x768 1280x800 1920x1200 2560x1440 3840x2160 1024x768}; do
  W=${size%x*}; H=${size#*x}
  start_x "$size"
  start_plymouth updates "plymouthd-$size-updates"
  plymouth system-update --progress=50
  plymouth ask-for-password --prompt="Please enter passphrase for disk (luks-3f0c):" >/dev/null &
  ASK=$!
  sleep 0.5
  xdotool type --delay 20 "secret"
  shot "bootsplash-$size-progress-0.5-password"
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
