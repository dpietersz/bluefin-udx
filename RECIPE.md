# RECIPE manifest

> Every baked package needs a row here. Adding a package without updating this file is a recipe-review red flag. Forces honesty about "do I really need this baked?"

## Bake/keep decision criteria

A package belongs in the image if it satisfies **all three**:
1. **Stable** — used > 6 months without churn
2. **Integration-sensitive** — needs PipeWire portal, MIME, theme, fingerprint, polkit, or screen-share
3. **Has a maintainable Fedora source** — vendor RPM, Fedora repo, Terra, or a long-lived COPR

If a package is AUR-only / experimental / rarely launched, it stays in distrobox (`common-toolbox`, out of this repo's scope).

## Bake reasons taxonomy

- `bootstrap` — required by the chezmoi crypto/password-store chain on first apply
- `screen-share` — needs Wayland + PipeWire portal access from the host
- `system-integration` — MIME handler, fingerprint, polkit, native theming
- `system-tool` — compositor, terminal, shell, window-management
- `dev-system-deps` — system libraries an SDK/tool requires (browsers, drivers, etc.)
- `nvidia` — GPU compute, NVIDIA variant only

## Package manifest

### Phase 0 (current)

| Package | Source | Maintained by | Why baked | Fallback if source dies | Last reviewed |
|---|---|---|---|---|---|
| `pass` | Fedora repo | Fedora | bootstrap | n/a (Fedora repo) | 2026-05-22 |
| `gnupg2` | Fedora repo | Fedora | bootstrap | n/a | 2026-05-22 |
| `age` | Fedora repo | Fedora | bootstrap (decrypts keys in chezmoi `08-decrypt-keys`) | switch to vendor binary release | 2026-05-22 |
| `openssh-clients` | Fedora repo | Fedora | bootstrap | n/a | 2026-05-22 |
| `git` | Fedora repo | Fedora | bootstrap | n/a | 2026-05-22 |
| `jq` | Fedora repo | Fedora | bootstrap (used by chezmoi templates + verify-image script) | n/a | 2026-05-22 |
| `curl` | Fedora repo | Fedora | bootstrap | n/a | 2026-05-22 |
| `teams-for-linux` | `repo.teamsforlinux.de` (vendor RPM) | IsmaelMartinez (upstream) | screen-share — distrobox path was unreliable on Wayland | switch to AppImage extract from GH releases | 2026-05-22 |

### Phase 2 (planned — system tools)

| Package | Source | Why baked |
|---|---|---|
| `kitty` | Fedora repo | system-tool (terminal) |
| `tmux` | Fedora repo | system-tool |
| `nushell` | Fedora repo | system-tool (shell) |
| `mate-polkit` | Fedora repo | system-integration (polkit agent for niri) |
| `syncthing` | Fedora repo | system-tool |
| `niri`, `waybar` | COPR (niri upstream) | system-tool (compositor) |
| `hyprlock`, `swayidle` | Terra + Fedora | system-integration (fingerprint lockscreen) |
| `espanso-wayland` | Terra | system-tool (CAP_DAC_OVERRIDE via post-install) |
| `noctalia-shell-v5` | COPR `lionheartp/Hyprland` | system-tool (Wayland shell) |
| `nwg-displays` | upstream tarball via `install-nwg-displays-latest.sh` | system-integration (GTK3+python-gi GUI for niri output config; sibling to baked `kanshi`/`niri`. Writes `~/.config/niri/monitor.kdl`, niri hot-reloads. **Not COPR**: `tofik/nwg-shell` is stuck on v0.3.28 (pre-niri); upstream 0.4.x added `NIRI_SOCKET` detection. Fallback: switch back to `tofik/nwg-shell` COPR once they ship ≥ 0.4.0.) |
| `grim` | Fedora repo | system-integration (Wayland screenshot capture — needed by niri+satty pipeline; satty itself lives user-scope in dotfiles via upstream GH release tarball, not baked, because the only COPR `mineiro/satty` is single-maintainer / 3-commits-young) |
| `slurp` | Fedora repo | system-integration (Wayland region selector — paired with grim) |
| `wl-mirror` | Fedora repo | system-integration (Wayland output mirror client — `wlr-screencopy`/`ext-image-copy-capture`, same screencopy family as `grim`/`slurp`. niri has no native output mirroring, so dotfiles `niri-mirror-toggle` (Ctrl+Alt+M) drives `wl-mirror` to clone the internal panel onto an external output. Host-native so mirroring no longer requires the Arch `udx-toolbox` being up; the toggle script prefers the host binary and falls back to the toolbox. Fedora base `0.18.5-1.fc44`, no new repo — fallback if it ever leaves Fedora base: `Ferdi265/wl-mirror` COPR or upstream source build.) |

### Phase 3 (planned — GUI apps)

| Package | Source | Why baked |
|---|---|---|
| Chromium | Fedora repo | system-integration; also the **Widevine CDM donor for Helium** — dotfiles `run_after_15-sync-helium-widevine` mirrors Chromium's self-updated CDM into Helium so Spotify's web player works. Don't drop Chromium without adding another Widevine source. |
| Browserpass + browserpass-chromium | Fedora repo | system-integration (native messaging w/ pass) |
| Beekeeper Studio | vendor RPM (`beekeeperstudio.io`) — corrected `.repo` + baked GPG key | stable + integration |
| Terra repo (espanso-wayland, hyprlock, helium-browser-bin) | metalink `tetsudou.fyralabs.com` + baked GPG key | unattended-build immunity to `repos.fyralabs.com` outages |
| Bruno | vendor RPM (`usebruno.com`) | stable + integration |
| LocalSend | GH releases RPM | system-integration (host firewall already wired) |
| Polypane | AppImage extract → `/opt/polypane` | stable + integration |
| Obsidian | COPR `cosmicfusion/Obsidian` (fallback: AppImage extract) | stable |
| Zen Browser | COPR `sneexy/zen-browser` (fallback: `firminunderscore/zen-browser`) | daily driver browser |
| Helium | Terra `helium-browser-bin` (pin version) | secondary browser — ships without Widevine; Spotify DRM fixed in dotfiles via the Chromium donor (see Chromium row) |

### Phase 3d (current — OBS Studio + virtual camera)

| Package | Source | Maintained by | Why baked | Fallback if source dies | Last reviewed |
|---|---|---|---|---|---|
| `obs-studio` | RPM Fusion free | RPM Fusion | screen-share — GUI app with Wayland PipeWire portal integration; cannot live in distrobox without portal/PipeWire socket gymnastics, cannot live in dotfiles (atomic OS forbids `rpm-ostree` from chezmoi). NVENC compiled in. | switch to Flatpak (last resort, breaks the no-Flatpak rule) | 2026-05-30 |
| `obs-studio-plugin-vaapi` | Fedora repo | Fedora | screen-share — VAAPI is a split package on modern obs-studio; required for the T580 (Intel iGPU) hardware encoder. Bake on both variants so one image serves both laptops. | n/a (Fedora repo) | 2026-05-30 |
| `v4l-utils` | Fedora repo | Fedora | system-integration — `v4l2-ctl` CLI for inspecting/debugging the OBS virtual camera (and any future v4l2 work). Referenced by the dotfiles OBS runbook (`~/.config/obs-studio/README.md`). ~50 KB. | n/a (Fedora repo) | 2026-05-30 |
| `mediainfo` | Fedora repo | Fedora | system-integration — readable codec / container / color-range / frame-rate-mode / audio-track inspection of recorded video. Referenced by the dotfiles OBS runbook for verifying CFR, 48 kHz, BT.709 limited on test recordings; without it the runbook step has to fall back to `ffprobe`. ~500 KB. | n/a (Fedora repo) | 2026-05-30 |
| `showmethekey` | COPR `pesader/showmethekey` | Alynx Zhou (upstream) / pesader (COPR) | screen-share — modern Wayland keystroke visualizer for OBS demo recordings (replaces unmaintained `wshowkeys` forks; `screenkey` is X11-only and doesn't work on niri). GTK4 overlay, libinput-direct (compositor-agnostic, runs on niri via `showmethekey-gtk -kAC`). Polkit rule shipped in the RPM gates `/dev/input/event*` access — no input-group hack needed, system-scope, cannot live in dotfiles. **Version-as-of-bake: `1.17.0-2` (fedora-44)**, predates the v1.19.0 polkit hardening that narrowed the allow rule to local-active-session only. Acceptable on single-user laptops; revisit when pesader rebuilds against newer upstream. | switch to upstream tarball build (overkill) or wait for COPR refresh | 2026-05-30 |
| `kmod-v4l2loopback` | **base image** (`bluefin-dx` / `bluefin-dx-nvidia-open` already ship it, signed with the `ublue kernel` MOK key enrolled on host) | Universal Blue | system-integration — kernel module for the OBS virtual camera (`/dev/video*` device exposed to Teams/Zoom/Slack). **Not layered** in this recipe — verified 2026-05-30 that a `type: akmods` block fails with "cannot install both ... from @commandline and ... from @System" because base already provides it. **Do NOT swap for RPM Fusion's `akmod-v4l2loopback`** — that is source-akmod, unsigned, build-at-boot, silently fails to load under Secure Boot (unlike the signed uBlue `kmod-nvidia-open` shipped on `-nvidia-open` base, which is NOT the RPM Fusion source-akmod). | if base ever drops it, re-add via bluebuild `akmods` module pulling from `ghcr.io/ublue-os/akmods` (main flavor) | 2026-05-30 |

User-layer config (`xdg-desktop-portal` config, OBS profile templated per machine via `.hasNvidia`, mic filter-chain scene collection, OBS plugin pack) lives in dotfiles at `dot_config/obs-studio/` and `.chezmoiscripts/run_onchange_after_18-install-obs-plugins.sh.tmpl`. Module autoload (`/etc/modules-load.d/v4l2loopback.conf`) and module options (`/etc/modprobe.d/v4l2loopback.conf`, `exclusive_caps=1` for Chromium-family camera pickers) are baked here as `files/system/` overlays because they're `/etc/` system scope, not `$HOME`.

### Phase 3.5 (planned — Playwright system deps)

System libraries the official Playwright Fedora deps list requires. Bake the libs, let `npm`/`npx playwright install` handle the playwright package + browsers per project. See https://playwright.dev/docs/intro

### Phase 4 (planned — NVIDIA variant only)

| Package | Source | Why baked |
|---|---|---|
| `cuda-toolkit` | NVIDIA CUDA Fedora repo | nvidia — conda is hard to install on atomic, so bake the toolkit |
| `nvtop` | Fedora repo | nvidia (GPU monitoring) |

## System-wide config files (non-package bakes)

| Path in image | Purpose | Why baked |
|---|---|---|
| `/usr/share/wayland-sessions/niri.desktop` | Override `DesktopNames=niri` → `niri;GNOME` so display managers export an XDG_CURRENT_DESKTOP value Chromium recognises | Electron password-store detection — without `GNOME` in the tag, Storage Explorer / Vibe Typer fall back to plaintext backend and refuse to start despite a fully functional `org.freedesktop.secrets` |
| `/usr/lib/environment.d/50-electron-keyring.conf` | Appends `:GNOME` to XDG_CURRENT_DESKTOP for the systemd user manager and everything it spawns | Belt-and-braces for sessions launched outside the DM (TTY, nested compositors) — same root cause as the niri.desktop override |

## Build-time maintenance steps

| Step | Purpose | Why baked |
|---|---|---|
| `files/scripts/rebuild-font-cache.sh` | Rebuild system fontconfig cache after font-bearing RPMs/apps are layered | Fixes COLRv1 emoji tofu caused by stale baked cache plus ostree epoch-normalized font-dir mtimes |

## Explicitly NOT baked (with reasoning)

| App | Why not | Lives where |
|---|---|---|
| Qutebrowser | Dropped per user — no longer used | n/a |
| Anytype | Official path is Snap/Flatpak/AppImage; only `poesty/anytype` community COPR. Not worth the supply-chain risk. | dropped |
| Microsoft Storage Explorer | MS ships AppImage only; rarely launched | `common-toolbox` (distrobox) |
| All language tooling (node, go, python, bun, …) | Per-project pinning matters more than system-wide latest | mise (`dotfiles/dot_config/mise/config.toml.tmpl`) |
| All CLI dev tools (bat, eza, fzf, ripgrep, neovim, starship, …) | Same as above | mise |
| GUI macOS-only apps (Aerospace, Raycast, Granola, Arq, Polypane Mac build, …) | Wrong OS | Homebrew (`dotfiles/.chezmoiscripts/run_once_before_01b-install-homebrew-packages.sh.tmpl`) |
| AppImage-only desktop apps with per-user updaters (VibeTyper, Terax) | Vendor-driven update cadence faster than image rebuild | chezmoi user-scope scripts |
| Flatpak runtimes | Explicit user preference: no Flatpak | n/a |
