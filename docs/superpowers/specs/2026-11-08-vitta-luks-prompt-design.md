# Vitta LUKS prompt — design

Status: approved by owner 2026-11-08 (option B). Amends
`2026-11-07-vitta-bootsplash-design.md`, whose non-goal "no styling of the
LUKS prompt" is withdrawn by the owner.

## Problem
On the T580 the plain prompt is drawn over the running splash animation; the
owner sees both "mixed together".

## Design (ruling R25)
Reference: `assets/luks-drafts/luks-b-bands-edge.png` (owner's pick),
inspired by `assets/luks-drafts/ref-ubuntu-luks.png`.
- When Plymouth asks for a password or answer, the splash layout (moving bands,
  badge, Lenovo wordmark) is hidden and a dedicated prompt screen is shown on
  `#282828`:
  - Fedora grungy logo, top centre (≈21 % of screen height, top edge at ≈16 %).
  - Passphrase field centred at ≈52 % height, ≈31 % of screen width, fill
    `#32302f`, 3 px border `#689d6a` (focus), small lock glyph at the left,
    square bullets in `#ebdbb2`.
  - Prompt text (from Plymouth/cryptsetup) centred under the field, `#d5c4a1`.
  - Keyboard-layout indicator (keyboard glyph + layout name) under that, ONLY if
    Plymouth's script API exposes the layout reliably; otherwise omitted.
  - Four full-width flat bands `#689d6a #458588 #d79921 #cc241d`, each 2.2 % of
    screen height, flush with the bottom screen edge.
- Wrong passphrase / retry: field border turns `#fb4934`; bullets cleared; the
  prompt stays usable. Caps Lock hint kept (plain, under the prompt text).
- When Plymouth returns to normal mode (disk unlocked), the prompt screen is
  removed and the animated splash continues where progress is.
- Fonts: Monaspace Neon in the initramfs for prompt text and layout label.
- Safety: Esc/details fallback must still work; a script error must never leave
  the passphrase un-enterable.
