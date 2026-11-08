#!/bin/bash
# vitta-plymouth-font: Monaspace Neon for the Vitta LUKS prompt (ruling R25).
#
# In the initramfs Plymouth draws Image.Text with label-freetype, which loads
# exactly two faces: /usr/share/fonts/Plymouth-monospace.ttf for a family
# string containing "mono", /usr/share/fonts/Plymouth.ttf for anything else.
# plymouth-populate-initrd (dracut module 45plymouth) symlinks those to the
# build host's fc-match defaults (Noto Sans / Noto Sans Mono). This module runs
# after it (99 > 45), installs Monaspace Neon Regular and Bold and repoints the
# two symlinks: monospace -> Regular (vitta.script's prompt text), the other
# -> Bold. Requested by /usr/lib/dracut/dracut.conf.d/90-vitta-plymouth-font.conf;
# a failed check() then fails the dracut run, so the image build stops instead
# of shipping a splash without its font.

VITTA_FONT_DIR=/usr/share/fonts/monaspace-neon

# called by dracut
check() {
    [[ -f ${dracutsysrootdir-}$VITTA_FONT_DIR/MonaspaceNeon-Regular.otf ]] || return 1
    [[ -f ${dracutsysrootdir-}$VITTA_FONT_DIR/MonaspaceNeon-Bold.otf ]] || return 1
    # Only when asked for (dracut.conf.d), never picked up on its own.
    return 255
}

# called by dracut
depends() {
    echo plymouth
}

# called by dracut; $initdir is dracut's staging root.
# shellcheck disable=SC2154
install() {
    inst_simple "$VITTA_FONT_DIR/MonaspaceNeon-Regular.otf" || return 1
    inst_simple "$VITTA_FONT_DIR/MonaspaceNeon-Bold.otf" || return 1
    mkdir -p "${initdir}/usr/share/fonts"
    ln -sfn "$VITTA_FONT_DIR/MonaspaceNeon-Regular.otf" "${initdir}/usr/share/fonts/Plymouth-monospace.ttf"
    ln -sfn "$VITTA_FONT_DIR/MonaspaceNeon-Bold.otf" "${initdir}/usr/share/fonts/Plymouth.ttf"
}
