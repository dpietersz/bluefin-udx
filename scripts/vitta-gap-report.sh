#!/bin/bash
# Compare the packages and selected non-RPM integration files supplied by
# bluefin-dx-nvidia-open with the desktop-less base-main image. BLUEFIN_IMAGE
# and BASE_IMAGE are overridable so the same comparison can target an NVIDIA
# base without changing the script's Intel-Vitta defaults.
#
# Usage:
#   scripts/vitta-gap-report.sh
#   OUTPUT_DIR=/tmp/vitta-gap ENGINE=podman scripts/vitta-gap-report.sh
#   BLUEFIN_IMAGE=ghcr.io/ublue-os/bluefin-dx-nvidia-open:stable \
#     BASE_IMAGE=ghcr.io/ublue-os/base-nvidia:44 OUTPUT_DIR=/tmp/vitta-nvidia-gap \
#     scripts/vitta-gap-report.sh
#
# Writes sorted lists to OUTPUT_DIR and prints the Bluefin-only package and
# integration-file differences. The report is intentionally NVIDIA-source based:
# its package delta is triaged for the Intel Vitta phase in the companion doc.

set -euo pipefail

export LC_ALL=C

BLUEFIN_IMAGE="${BLUEFIN_IMAGE:-ghcr.io/ublue-os/bluefin-dx-nvidia-open:stable}"
BASE_IMAGE="${BASE_IMAGE:-ghcr.io/ublue-os/base-main:44}"
OUTPUT_DIR="${OUTPUT_DIR:-/tmp/vitta-gap-report}"
ENGINE="${ENGINE:-podman}"

if ! command -v "$ENGINE" >/dev/null 2>&1; then
  echo "ERROR: container engine not found: $ENGINE" >&2
  exit 2
fi

mkdir -p "$OUTPUT_DIR"

image_list_name() {
  local image=$1 output=$2
  "$ENGINE" run --rm --entrypoint /bin/bash "$image" -c \
    'rpm -qa --qf "%{NAME}\n"' | sort -u > "$output"
}

image_list_files() {
  local image=$1 output=$2
  "$ENGINE" run --rm --entrypoint /bin/bash "$image" -c '
    find \
      /etc/profile.d \
      /etc/systemd/system \
      /usr/lib/systemd/system \
      /usr/lib/sysusers.d \
      /etc/udev/rules.d \
      /usr/lib/udev/rules.d \
      -type f -print 2>/dev/null
  ' | sort -u > "$output"
}

bluefin_names="$OUTPUT_DIR/bluefin-dx-nvidia-open.names"
base_names="$OUTPUT_DIR/base-main.names"
bluefin_files="$OUTPUT_DIR/bluefin-dx-nvidia-open.integration-files"
base_files="$OUTPUT_DIR/base-main.integration-files"
bluefin_only_names="$OUTPUT_DIR/bluefin-only.names"
bluefin_only_files="$OUTPUT_DIR/bluefin-only.integration-files"

echo "==> Pulling $BLUEFIN_IMAGE"
"$ENGINE" pull "$BLUEFIN_IMAGE" >/dev/null
echo "==> Pulling $BASE_IMAGE"
"$ENGINE" pull "$BASE_IMAGE" >/dev/null

echo "==> Writing sorted package lists to $OUTPUT_DIR"
image_list_name "$BLUEFIN_IMAGE" "$bluefin_names"
image_list_name "$BASE_IMAGE" "$base_names"

echo "==> Writing sorted integration-file lists to $OUTPUT_DIR"
image_list_files "$BLUEFIN_IMAGE" "$bluefin_files"
image_list_files "$BASE_IMAGE" "$base_files"

comm -13 "$base_names" "$bluefin_names" > "$bluefin_only_names"
comm -13 "$base_files" "$bluefin_files" > "$bluefin_only_files"

echo "==> Bluefin-only packages ($(wc -l < "$bluefin_only_names"))"
cat "$bluefin_only_names"
echo "==> Bluefin-only systemd/profile.d/sysusers/udev files ($(wc -l < "$bluefin_only_files"))"
cat "$bluefin_only_files"
