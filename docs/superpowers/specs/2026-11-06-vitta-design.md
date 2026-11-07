# Vitta — design

Status: awaiting owner approval · 2026-11-06 · owner: Dimitri Pietersz

## 1. Intent

`bluefin-udx` is built `FROM ghcr.io/ublue-os/bluefin-dx`. Upstream has
rebranded that image *Bluefin Classic*, handed it to new maintainers, and moved
its core team to Dakota/Utah/Server. The dependency audit
(`docs/research/2026-11-06-bluefin-dependency-audit.md`) showed:

- What we actually depend on sits in **Universal Blue's base layer**
  (signed NVIDIA/akmods, codecs) — healthy, shared with Bazzite/Aurora, already
  on F45 — plus a handful of Bluefin/DX items we can re-home ourselves.
- Most of what Bluefin/DX adds is unused here (GNOME, ZFS, 43 Flatpaks,
  incus, cockpit, all-arch qemu, sysstat, setroubleshoot) and costs download
  size, update failures and hidden couplings.

**Vitta** (Latin *vitta*: ribbon, coloured stripe) is a new image built on
Universal Blue's desktop-less base, carrying only what this setup uses, with
its own identity and a retro Gruvbox boot → login → lock experience.

Why now: get off a base that is no longer upstream's flagship *before* it
changes shape (planned "pull directly from Fedora" swap, F45), while still
evolving — not freezing in old patterns.

## 2. Goals

1. A bootable, signed `ghcr.io/dpietersz/vitta` image (Intel/AMD) that runs the
   full current niri desktop + dotfiles on the **ThinkPad T580**.
2. Every capability the audit showed in use keeps working (see §6 checklist).
3. Retro Gruvbox **login screen and lock screen** sharing one
   visual language: four flat full-width bands (aqua · blue · yellow · red),
   Monaspace Neon, a grungy Fedora-style personal logo.
4. Login + lock screens switch **light by day / dark by night** using one rule.
5. Own identity (`ID=vitta`) so dotfiles stop keying on "Bluefin".
6. `bluefin-udx` keeps building and remains the rollback until Vitta is proven.

## 3. Non-goals (this phase)

- NVIDIA variant and migrating the P14s (next phase; fingerprint packages come
  with it).
- Whole-desktop day/night switching (Noctalia, kitty, wallpaper stay as they
  are). **Only login + lock screens follow day/night.**
- **Boot splash (Plymouth) and the LUKS passphrase prompt** — deferred by the
  owner to a follow-up. The theme assets in §6 must make it easy to add later
  (dark-only, since the initramfs cannot apply the day/night rule).
- Renaming the GitHub repo (happens when `bluefin-udx` retires).
- Plain-image size optimisation such as rechunking (desirable, separate change).

## 4. Anti-goals (failure even if it "works")

- Teams screen sharing, Electron keyring, OBS virtual camera or the Windows
  work VM break on Vitta.
- Any GNOME session/shell sneaks back in (e.g. by installing `gdm`).
- Login and lock screens drift visually because they have separate palettes.
- Dotfiles silently disable features on Vitta (the `isBluefin` trap).
- Unsigned kernel modules that fail under Secure Boot.
- Flatpak or AppImage used as a delivery mechanism.

## 5. Decisions (made with the owner)

### 5.1 Base — Approach B
| | Approach | Verdict |
|---|---|---|
| A | Stay on `bluefin-dx`, trim it | Rejected: keeps GNOME/DX/Flatpak weight on a non-flagship upstream |
| **B** | **`ghcr.io/ublue-os/base-main:44` (desktop-less Universal Blue)** | **Chosen**: keeps the healthy ublue layer (akmods, codecs, signing), drops Bluefin |
| C | Pure `fedora-bootc` | Rejected: own NVIDIA/kmod signing + codecs for no gain |
| D | Dakota / Utah | Rejected: Flatpak-first / pre-alpha; watch only |

### 5.2 Login screen — Approach B
| | Login | Lock | Verdict |
|---|---|---|---|
| A | Quickshell | Quickshell | Rejected for now: rebuilds proven hyprlock + fingerprint |
| **B** | **Quickshell greeter in `cage`, via greetd** | **hyprlock restyled** | **Chosen** |
| C | ReGreet (GTK4/CSS) | hyprlock | Rejected: not packaged in Fedora |
| — | tuigreet (± kmscon) | — | Rejected: cannot draw pixel stripes, rounded corners, images |
| — | gdm | — | Rejected: pulls gnome-shell/session/settings-daemon |

### 5.3 Name
`vitta`: image `ghcr.io/dpietersz/vitta`, os-release `ID=vitta`,
`NAME="Vitta"`, `VARIANT_ID=vitta`. (`remora` rejected: collides with
`tuna-os/remora` in the bootc ecosystem.)

### 5.4 Visual language
- **Bands** (layout A, owner ruling R20, mockup
  `assets/vitta-login-layout-a.png`): no card, no frame. Four touching, flat
  (no strokes, shadows or gradients) horizontal bands span the whole screen
  edge to edge, top to bottom `stripe1`..`stripe4`, each round(0.022 × screen
  height) thick (16 px at 720p, 24 px at 1080p), the block centred at 40 % of
  the height.
  - dark: aqua `#689d6a` · blue `#458588` · yellow `#d79921` · red `#cc241d`
  - light: aqua `#8ec07c` · blue `#83a598` · yellow `#fabd2f` · red `#fb4934`
- **Logo on the bands**: centred horizontally and on the band block, size
  round(0.24 × height), in a bg-coloured circle of radius 0.54 × logo size, so
  the bands end in a clean round gap around it.
- **Background**: dark `#282828`, light `#fbf1c7`. Plain, like the reference.
- **Font**: Monaspace Neon (larger than terminal default; clock much larger),
  installed **system-wide** because the greeter and initramfs run without user
  fonts.
- **Logo**: the owner's personal grungy brush-stroke remix of the Fedora logo
  (style reference: grunge Debian swirl, without the thin red lines), Gruvbox
  palette. Two variants: cream-dominant on `#282828`, dark-brown-dominant on
  `#fbf1c7`, each rendered on its exact background colour. Generated with the
  image tool; **owner approves drafts before they ship**.
- **Screen layout** (login & lock, everything horizontally centred): clock
  `HH:mm` (bold, ~0.09 × height) and date `dddd d MMMM yyyy` (muted, ~0.03 ×
  height) above the bands; user + password fields (lock: password only),
  status line and `host · vitta <version>` line (muted) below. Nothing overlaps
  the bands or the logo gap. Shutdown/reboot bottom-right on the login screen.
  The lock screen's bands and positions are % of the monitor; its logo and
  text sizes are px computed for 1080p (hyprlock has no % for those).

### 5.5 Day/night rule
`vitta-theme mode` → `light` between local sunrise and sunset at coordinates in
`/etc/vitta/theme.conf` (default: Amsterdam, 52.37 N 4.90 E), else `dark`.
`vitta-theme mode --at <time>` for testing. Used by the greeter (re-evaluated
every minute, flips live) and the lock screen (evaluated each lock). Not used
by anything else.

## 6. What the image contains

**From the base** (`base-main:44`): Fedora kernel, ublue akmods/signing, codecs,
pipewire/wireplumber, bluez, NetworkManager, cups, fwupd, Intel VA-API,
wireguard, plymouth, `rpm-ostreed-automatic`, ublue `just` recipes.

**Shared with bluefin-udx**: `recipes/common.yml` unchanged (niri stack, apps,
vendor repos, Proton, nushell, fontconfig hardening, cosign policy).

**Re-homed from Bluefin/DX** (each justified by the audit):
| Capability | How |
|---|---|
| Keyring for Electron/Teams | `gnome-keyring` + `gnome-keyring-pam`; keep the matched `niri.desktop` / `50-electron-keyring.conf` pair |
| Screen share / portals | `xdg-desktop-portal-gnome` (dotfiles `portals.conf`: `gnome;gtk`) |
| Files / previews / devices | `nautilus`, `gvfs` (+mtp, gphoto2) |
| Fonts | Noto (smoke gate needs Noto Serif + Noto Color Emoji), Monaspace Neon |
| Power profiles | `tuned` + `tuned-ppd` (dotfiles `power-profile-auto.sh` uses the net.hadess D-Bus API) |
| User dirs | `xdg-user-dirs` |
| Homebrew (login shell is brew bash) | BlueBuild `brew` module / `ghcr.io/ublue-os/brew` layer |
| OBS virtual camera | `kmod-v4l2loopback` via BlueBuild `akmods` module (ublue-signed); keep existing modprobe/modules-load files |
| Containers | docker-ce (+buildx, compose), podman-compose |
| Windows work VM | libvirt + `qemu-kvm` (x86 only) + swtpm + edk2-ovmf + virtiofsd + virt-manager; preserve whatever `libvirt-workaround.service` fixes in Bluefin |
| VS Code | Microsoft repo |
| Tailscale | Tailscale repo |
| Groups | `vitta-groups.service` adds wheel users to `docker`, `libvirt` (replaces `bluefin-dx-groups`) |
| Editor name | `/usr/bin/zeditor` → `zed` (no ZFS, so Terra installs `zed-cli`) |

**Developer build deps** *[builder call]*: `gcc`, `make` (Homebrew source
builds) and `android-tools` (dotfiles `07-install-android-sdk`) were supplied
by Bluefin/DX; include them. The plan starts with a **gap-analysis step**:
diff `bluefin-dx` vs `base-main` package lists and triage every remaining
difference against dotfiles scripts/configs, so nothing the dotfiles assume
is silently lost (T580-specific: battery thresholds are kernel `thinkpad_acpi`,
already present).

**Updates** *[builder call]*: `rpm-ostreed-automatic` in its default stage
mode for the OS. Homebrew keeps its own `brew-update`/`brew-upgrade` timers
from the ublue brew layer (they were never `uupd`-only). Distrobox images stay
refreshed by the dotfiles toolbox script on `chezmoi apply`. Flatpak updates
are not needed.

**Explicitly absent**: gdm and every GNOME session/shell package, ZFS, Flatpak
preinstalls, incus/lxc, cockpit, `uupd`, sysstat, setroubleshoot, non-x86 qemu.

**Login stack**: `greetd` (greeter user) → `cage -s` → `quickshell` config under
`/usr/share/vitta/greeter/`, authenticating through Quickshell's greetd
service. The T580's login keyring password equals the account password, so
PAM for greetd includes `pam_gnome_keyring` (`auth optional` + `session
optional auto_start`, plus `password optional use_authtok` to keep it in
sync), unlocking the keyring at login exactly as gdm does today. Fingerprint
machines (P14s, empty-password keyring) are a later phase. Only the niri session is offered. Remembers last user.

**Theme assets**: `/usr/share/vitta/theme/` — one palette source (dark +
light), logos, and generated per-consumer files (greeter, hyprlock; plymouth later)
derived from that single palette at build time.

**Identity**: BlueBuild `os-release` module (or equivalent) sets `ID=vitta`,
`NAME="Vitta"`, `VARIANT_ID=vitta`, `IMAGE_ID=vitta`.

## 7. Dotfiles changes (repo `~/dotfiles`)

- `.chezmoi.toml.tmpl`: add `isVitta` (os-release `ID=vitta`); introduce a
  "my image" predicate (`isBluefin or isVitta`) and switch the existing 15
  `isBluefin` gates to it unless a gate is genuinely Bluefin-specific.
- hyprlock: on Vitta, render the layout A lock screen from `/usr/share/vitta/theme/`
  in the mode returned by `vitta-theme mode` at lock time (lock script picks
  the config); keep the fingerprint block; non-Vitta machines keep today's
  config unchanged.
- `isBluefinUdx` (booted image contains `ghcr.io/dpietersz/bluefin-udx`)
  gates ~10 install scripts that skip `rpm-ostree` layering because the image
  already ships the package. *[builder call]* Generalise it to a "my image"
  flag matching `ghcr.io/dpietersz/(bluefin-udx|vitta)` so Vitta never falls
  back to layering. `00a-verify-image` / `expectedImage` derive the expected
  image family from the booted image instead of hard-coding `bluefin-udx`, so
  the P14s keeps expecting `bluefin-udx-nvidia` and the T580 accepts `vitta`.
- No change needed for `zeditor` (image provides the link).

## 8. Repo, CI, release

- Same repo; new `recipes/vitta.yml` (`base-image: ghcr.io/ublue-os/base-main`,
  `image-version: 44`) + `files` + `common.yml` + Vitta modules.
- CI matrix gains a `vitta` leg using the existing podman pin, smoke gate
  pattern, signing and N+1 resolution check (extend `check-fedora-next.sh` to
  include the Vitta recipe, base `base-main:<N+1>`).
- CI pushes **`vitta:testing`** (+ dated/sha tags) on every green `main`
  build. `vitta:stable` is promoted manually after the T580 checklist passes.
- Smoke gate for Vitta asserts at least: os-release identity; greetd config
  points at cage+quickshell; no `gdm`/`gnome-shell`/`gnome-session`/`zfs`;
  niri is the only wayland session; keyring PAM lines present; Monaspace Neon
  resolvable by fontconfig; theme assets present for both modes;
  `vitta-theme mode --at` returns light at noon and dark at midnight;
  `kmod-v4l2loopback` present and signed; docker/libvirt/brew/tailscale/code
  present; `zeditor` resolves.

## 9. T580 acceptance checklist

Switch: `sudo bootc switch ghcr.io/dpietersz/vitta:testing`, reboot,
`chezmoi apply`, reboot. Pass when all hold:

1. LUKS passphrase at boot still works (stock prompt).
2. Greeter appears in the correct mode for the time of day; login works; keyring unlocked (no keyring prompt from Teams/Storage Explorer).
3. niri + Noctalia session identical to `bluefin-udx`; `chezmoi apply` deploys hyprlock/idle stack (no `isBluefin` loss).
4. Lock screen matches the greeter's layout A look (full-width bands, logo in a round gap, clock/date above, password + host line below, no overlaps) and mode; unlock by password.
5. Teams: screen share a window and a full screen.
6. OBS virtual camera visible in Teams/Chromium.
7. `docker run hello-world`; distrobox toolboxes start and exported apps launch.
8. Windows work VM boots with all VirtioFS drives.
9. brew bash login shell, `zeditor`, VS Code, tailscale up.
10. `bootc rollback` returns to `bluefin-udx` cleanly.

## 10. Left to the builder

- Exact QML structure of the greeter; exact hyprlock shape stack.
- Sunrise/sunset implementation (small, unit-tested; no network).
- How the palette is turned into per-consumer files (build-time script).
- Whether to use BlueBuild `brew`/`os-release`/`initramfs`/`kargs` modules or
  scripts, as long as smoke-tested.
- Whether greetd's greeter user needs extra groups (video/input) for cage.
- Logo generation prompts and post-processing (owner approves output).
  *[builder call]* Build the greeter/hyprlock plumbing against a
  placeholder logo; swap in the approved logo late.
- Stripe geometry *[superseded by R20, layout A]*: originally four concentric
  rounded-rectangle borders around a card; the owner replaced this with four
  full-width background bands and no card (§5.4). References:
  `assets/vitta-ref-bands-dark.png`, `assets/vitta-ref-bands-light.png`,
  approved mockup `assets/vitta-login-layout-a.png`.

## 11. CI shape *[builder call]*

Vitta gets one matrix leg built on `base-main:44` that pushes `vitta:testing`
(+ dated/sha tags) on every green `main`/nightly build. No separate full
canary against `base-main:45`: the N+1 resolution job covers it until Vitta is
promoted to `:stable`; revisit then.
