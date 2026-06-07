#!/bin/bash
# 50-fprintd-resume — re-initialise the fingerprint stack on resume.
#
# Why: hyprlock's fingerprint auth (libfprint via fprintd) goes flaky for the
# first ~1-2s after resume from suspend — the USB sensor needs to be re-claimed.
# Symptom on the ThinkPad P14s (Synaptics 06cb:00f9): fingerprint unlocks
# hyprlock, then the desktop "re-locks within a second" / you fall back to
# typing the password. fprintd is D-Bus-activated and caches a stale device
# handle across suspend, so we restart it on resume to force a fresh claim.
#
# systemd-sleep invokes this with: $1 = pre|post, $2 = suspend|hibernate|...
# We only act on `post` (i.e. after waking).
#
# Lives in the image (not dotfiles) because /usr/lib/systemd/system-sleep/ is
# immutable on atomic Bluefin — it can only be written at build time.
set -euo pipefail

case "$1" in
  post)
    # try-restart is a no-op if fprintd isn't running (D-Bus will re-activate
    # it fresh on the next call), and forces a clean device re-claim if it is.
    systemctl try-restart fprintd.service || true
    ;;
esac
