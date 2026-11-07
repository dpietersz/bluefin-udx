# Vitta boot splash — design

Status: approved by owner 2026-11-07 (draft 2 + animation). Follow-up to
`2026-11-06-vitta-design.md` §3 (boot splash was deferred).

## Intent
Replace Fedora's default Plymouth splash on Vitta with a retro Gruvbox splash in
the same visual language as the login screen, combining the owner's grungy
Fedora logo and a grungy Lenovo wordmark (same brush style). Dark only.

## What it looks like
Reference frames/animation: `assets/bootsplash-drafts/splash-2.png`,
`splash-2-anim.gif`, `splash-2-anim-steps.png`.
- Background `#282828`. Bands: four touching flat bands
  `#689d6a #458588 #d79921 #cc241d`, each 2.2 % of screen height, block centred
  vertically at 40 % of screen height (identical to the login screen).
- Badge on the right: Fedora logo (`logo-final/vitta-logo-dark.png`, 24 % of
  screen height... scaled so the badge fits, as in the draft) centred at ~81 %
  of screen width on the band block, inside a `#282828` round gap; Lenovo
  wordmark (`logo-final/lenovo-wordmark-dark.png`, cream, transparent) centred
  under the logo.
- Animation: the bands run in from the left screen edge and grow to the badge
  gap following Plymouth boot progress (ease-out). Fully grown = boot done.

## Non-goals
- No styling of the LUKS passphrase prompt (owner). The prompt must still
  appear and work, in a plain functional look.
- No light variant. No changes to the login or lock screen.

## Constraints
- Theme ships in the image and is inside the image's initramfs; it is the
  default theme on fresh installs and on machines rebased onto Vitta.
- Everything Vitta-only (files/vitta, recipes/vitta-modules.yml).
- Must not break boot: if the theme fails, Plymouth falls back to text/details,
  never a hang.
