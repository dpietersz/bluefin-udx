#!/usr/bin/env bash
# Bake Monaspace Neon for the Vitta greeter, which starts before user fonts load.

set -euo pipefail

URL="https://github.com/githubnext/monaspace/releases/download/v1.400/monaspace-static-v1.400.zip"
SHA256="ab66d71be751495f679727332a3345597943bd4d7beebca03f5cde04bf994de7"
FONT_DIR="/usr/share/fonts/monaspace-neon"
FONT_PREFIX="Static Fonts/Monaspace Neon/"
FONT_COUNT=42
WORKDIR=$(mktemp -d)
ARCHIVE="${WORKDIR}/monaspace-static-v1.400.zip"
trap 'rm -rf "${WORKDIR}"' EXIT

curl -fsSL --retry 5 --retry-all-errors -o "${ARCHIVE}" "${URL}"
printf '%s  %s\n' "${SHA256}" "${ARCHIVE}" | sha256sum -c -

rm -rf "${FONT_DIR}"
install -d -m 0755 "${FONT_DIR}"

if command -v unzip >/dev/null 2>&1; then
  unzip -t "${ARCHIVE}" >/dev/null
  mapfile -t FONT_FILES < <(unzip -Z1 "${ARCHIVE}" | awk -v prefix="${FONT_PREFIX}" '$0 ~ "^" prefix "[^/]+[.]otf$"')

  if [ "${#FONT_FILES[@]}" -ne "${FONT_COUNT}" ]; then
    echo "[monaspace-neon] expected ${FONT_COUNT} static OTF files, found ${#FONT_FILES[@]}" >&2
    exit 1
  fi

  for FONT_FILE in "${FONT_FILES[@]}"; do
    FONT_NAME="${FONT_FILE#"${FONT_PREFIX}"}"
    unzip -p "${ARCHIVE}" "${FONT_FILE}" > "${WORKDIR}/${FONT_NAME}"
    install -m 0644 "${WORKDIR}/${FONT_NAME}" "${FONT_DIR}/${FONT_NAME}"
  done
else
  python3 - "${ARCHIVE}" "${FONT_DIR}" "${FONT_PREFIX}" "${FONT_COUNT}" <<'PY'
import shutil
import sys
import zipfile
from pathlib import Path

archive, font_dir, prefix, expected_count = sys.argv[1:]
expected_count = int(expected_count)

with zipfile.ZipFile(archive) as source:
    fonts = [
        member.filename
        for member in source.infolist()
        if member.filename.startswith(prefix)
        and member.filename[len(prefix):].count("/") == 0
        and member.filename.endswith(".otf")
    ]
    names = [Path(font).name for font in fonts]
    if len(fonts) != expected_count or len(set(names)) != expected_count:
        raise SystemExit(
            f"[monaspace-neon] expected {expected_count} unique static OTF files, found {len(fonts)}"
        )

    for font, name in zip(fonts, names, strict=True):
        destination = Path(font_dir, name)
        with source.open(font) as input_file, destination.open("wb") as output_file:
            shutil.copyfileobj(input_file, output_file)
        destination.chmod(0o644)
PY
fi

INSTALLED_COUNT=$(find "${FONT_DIR}" -maxdepth 1 -type f -name "*.otf" | wc -l)
if [ "${INSTALLED_COUNT}" -ne "${FONT_COUNT}" ]; then
  echo "[monaspace-neon] expected ${FONT_COUNT} installed OTF files, found ${INSTALLED_COUNT}" >&2
  exit 1
fi

fc-cache -f "${FONT_DIR}"
MATCHED_FILE=$(/usr/bin/fc-match -f "%{file}" "Monaspace Neon")
case "${MATCHED_FILE}" in
  "${FONT_DIR}"/*) ;;
  *)
    echo "[monaspace-neon] fc-match resolved to ${MATCHED_FILE:-missing}" >&2
    exit 1
    ;;
esac

echo "[monaspace-neon] installed ${INSTALLED_COUNT} OTF files"
