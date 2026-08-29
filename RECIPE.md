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
| `nushell` | upstream GitHub release via `install-nushell-latest.sh` | system-tool (shell) — replaced `atim/nushell` COPR after Fedora 44 builds stalled at 0.112.2; CI resolves the newest tag and requires GitHub's asset digest to match upstream `SHA256SUMS` before each build (integrity check, not an independent signature) |
| `mate-polkit` | Fedora repo | system-integration (polkit agent for niri) |
| `syncthing` | Fedora repo | system-tool |
| `niri`, `waybar` | Fedora repo | system-tool (compositor) — Fedora 44 updates currently carries upstream `niri` 26.04, so the former `yalter/niri` COPR added supply-chain risk without a version benefit |
| `hyprlock`, `swayidle` | package-scoped `lionheartp/Hyprland` COPR + Fedora | system-integration (fingerprint lockscreen) — COPR repo is constrained to hyprlock and ABI-matched Hypr libraries; nightly audit compares package version with upstream release |
| `espanso-wayland` | Terra | system-tool (CAP_DAC_OVERRIDE via post-install) |
| `noctalia` | Fedora repo | system-tool (Wayland shell) — official Fedora 44+ package follows tagged v5 beta releases; replaced abandoned `noctalia-shell-v5` COPR snapshot (`cce1141`, 2026-05-18) |
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
| Zed editor | **Terra** (`zed`) — *not* a dedicated COPR | system-tool (code editor). Terra's `zed` is zfs-collision-aware: `Requires: (zed-cli-compat-zfs if zfs else zed-cli)`, so on the zfs-shipping base the editor binary is `/usr/bin/zeditor` and `/usr/bin/zed` stays the ZFS Event Daemon. **Do not re-add the `che/zed` COPR** — it ships a monolithic `zed` that claims `/usr/bin/zed` + `dev.zed.Zed.desktop`/`metainfo`; with both repos enabled dnf picks the higher version and a che/zed win = 3-way file conflict that kills the build (root cause of the 2026-06-14 nightly failure). Fallback if Terra ever drops `zed`: pin a che/zed build *and* exclude Terra's `zed*`, or build from source. |
| Terra repo (espanso-wayland, helium-browser-bin, zed) | metalink `tetsudou.fyralabs.com` + baked GPG key | unattended-build immunity to `repos.fyralabs.com` outages |
| Bruno | vendor RPM (`usebruno.com`) | stable + integration |
| LocalSend | GH releases RPM | system-integration (host firewall already wired) |
| Polypane | AppImage extract → `/opt/polypane` | stable + integration |
| Zen Browser | COPR `sneexy/zen-browser` (fallback: `firminunderscore/zen-browser`) | daily driver browser |
| Helium | Terra `helium-browser-bin` (pin version) | secondary browser — ships without Widevine; Spotify DRM fixed in dotfiles via the Chromium donor (see Chromium row) |

### Phase 3d (current — OBS Studio + virtual camera)

| Package | Source | Maintained by | Why baked | Fallback if source dies | Last reviewed |
|---|---|---|---|---|---|
| `obs-studio` | RPM Fusion free | RPM Fusion | screen-share — GUI app with Wayland PipeWire portal integration; cannot live in distrobox without portal/PipeWire socket gymnastics, cannot live in dotfiles (atomic OS forbids `rpm-ostree` from chezmoi). NVENC compiled in. | switch to Flatpak (last resort, breaks the no-Flatpak rule) | 2026-05-30 |
| `obs-studio-plugin-vaapi` | Fedora repo | Fedora | screen-share — VAAPI is a split package on modern obs-studio; required for the T580 (Intel iGPU) hardware encoder. Bake on both variants so one image serves both laptops. | n/a (Fedora repo) | 2026-05-30 |
| `v4l-utils` | Fedora repo | Fedora | system-integration — `v4l2-ctl` CLI for inspecting/debugging the OBS virtual camera (and any future v4l2 work). Referenced by the dotfiles OBS runbook (`~/.config/obs-studio/README.md`). ~50 KB. | n/a (Fedora repo) | 2026-05-30 |
| `mediainfo` | Fedora repo | Fedora | system-integration — readable codec / container / color-range / frame-rate-mode / audio-track inspection of recorded video. Referenced by the dotfiles OBS runbook for verifying CFR, 48 kHz, BT.709 limited on test recordings; without it the runbook step has to fall back to `ffprobe`. ~500 KB. | n/a (Fedora repo) | 2026-05-30 |
| `showmethekey` | package-scoped `barsnick/non-fed` COPR | Alynx Zhou (upstream) / barsnick (COPR) | screen-share — modern Wayland keystroke visualizer for OBS demo recordings. Switched from abandoned `pesader/showmethekey` v1.17.0 to v1.21.0, restoring upstream's post-v1.19 local-active-session polkit hardening. Broad COPR is constrained by baked `showmethekey.repo` with `includepkgs=showmethekey*`, preventing unrelated package overrides. CI enforces version >=1.21.0 and presence of the polkit rule. | build tagged upstream source with Meson if this COPR falls behind | 2026-08-29 |
| `kmod-v4l2loopback` | **base image** (`bluefin-dx` / `bluefin-dx-nvidia-open` already ship it, signed with the `ublue kernel` MOK key enrolled on host) | Universal Blue | system-integration — kernel module for the OBS virtual camera (`/dev/video*` device exposed to Teams/Zoom/Slack). **Not layered** in this recipe — verified 2026-05-30 that a `type: akmods` block fails with "cannot install both ... from @commandline and ... from @System" because base already provides it. **Do NOT swap for RPM Fusion's `akmod-v4l2loopback`** — that is source-akmod, unsigned, build-at-boot, silently fails to load under Secure Boot (unlike the signed uBlue `kmod-nvidia-open` shipped on `-nvidia-open` base, which is NOT the RPM Fusion source-akmod). | if base ever drops it, re-add via bluebuild `akmods` module pulling from `ghcr.io/ublue-os/akmods` (main flavor) | 2026-05-30 |

User-layer config (`xdg-desktop-portal` config, OBS profile templated per machine via `.hasNvidia`, mic filter-chain scene collection, OBS plugin pack) lives in dotfiles at `dot_config/obs-studio/` and `.chezmoiscripts/run_onchange_after_18-install-obs-plugins.sh.tmpl`. Module autoload (`/etc/modules-load.d/v4l2loopback.conf`) and module options (`/etc/modprobe.d/v4l2loopback.conf`, `exclusive_caps=1` for Chromium-family camera pickers) are baked here as `files/system/` overlays because they're `/etc/` system scope, not `$HOME`.

### Phase 3f (current — Noctalia Screen Toolkit host dependencies)

| Package | Source | Maintained by | Why baked | Fallback if source dies | Last reviewed |
|---|---|---|---|---|---|
| `tesseract` | Fedora repo | Fedora | system-integration — OCR engine invoked directly by Noctalia's host-side `alexander/screen-toolkit` plugin. The language-data packages do not depend on the engine, so listing only a langpack can leave `/usr/bin/tesseract` absent. | n/a (Fedora repo) | 2026-08-29 |
| `tesseract-langpack-eng` | Fedora repo | Fedora | system-integration — explicit English OCR data guarantee for the plugin's configured `eng+nld`; do not rely on incidental base-image contents. | n/a (Fedora repo) | 2026-08-29 |
| `tesseract-langpack-nld` | Fedora repo | Fedora | system-integration — Dutch OCR data for the plugin's configured `eng+nld`. | n/a (Fedora repo) | 2026-08-29 |
| `gpu-screen-recorder` | package-scoped `lionheartp/Hyprland` COPR | dec05eba (upstream) / lionheartp (COPR) | screen-share — preferred fullscreen backend for Noctalia; supports Wayland H.264 through NVENC or VAAPI and combines `default_output\|default_input` into one audio track. Shared package serves both laptops. Broad COPR is exposed through `gpu-screen-recorder.repo` with exact `includepkgs=gpu-screen-recorder`. Package `%post` grants only `/usr/bin/gsr-kms-server` `cap_sys_admin=ep`, required for KMS monitor/region capture; smoke tests assert the capability survives image composition. | use `wf-recorder` with one audio source, or OBS for dual-audio recording; never replace this with Flatpak/AppImage or an unpinned source build | 2026-08-29 |
| `wf-recorder` | Fedora repo | Fedora | screen-share — maintainable region-recording fallback. No Fedora RPM exists for plugin-preferred `wl-screenrec`. Current plugin can capture only one default audio source on this path; simultaneous system+microphone audio is **not supported for region recording**. | OBS region/source capture, or adopt `wl-screenrec` only after Fedora or a durable scoped COPR packages it | 2026-08-29 |

Build/smoke checks prove package identity, OCR language discovery, GSR CLI contract, linked libraries, and the privileged helper capability. They cannot prove hardware encoding or live PipeWire routing inside a container with no compositor, GPU, microphone, or active audio graph. After deployment, test one fullscreen recording on each laptop and verify H.264 plus audible system/microphone content; quarterly instructions live in `MAINTENANCE.md`.

### Current standalone Proton GUI packages

| Package | Source | Maintained by | Why baked | Fallback if source dies | Last reviewed |
|---|---|---|---|---|---|
| `proton-authenticator` | Proton standalone Fedora/RHEL x86_64 RPM, resolved from official `version.json`; RPM is unsigned, so URL + SHA-512 are resolved together and verified before install | Proton AG | system-integration — replacement daily-driver authenticator; needs native GTK/WebKitGTK plus host Secret Service (`libsecret`/D-Bus). Owner-approved exception to the >6 months personal-use gate because it replaces an already heavily used authenticator rather than introducing an experimental workflow. Shared `common.yml` module keeps T580 and P14s aligned. | build the GPLv3 application from `ProtonMail/WebClients`, or revert to the previous iOS/macOS authenticator while retaining exported recovery data | 2026-08-25 |
| `proton-mail` | Proton standalone Fedora/RHEL x86_64 RPM, newest active `Stable` entry from official Mail `version.json`; Linux client remains beta-labeled, RPM is unsigned, SHA-512 + package identity are verified | Proton AG | system-integration — daily Mail + Calendar client with native notifications, `mailto:` MIME handling, and host desktop/keyring integration. Owner-approved for direct promotion; stable channel only, never Alpha/EarlyAccess. Shared `common.yml` module keeps T580 and P14s aligned. | use `mail.proton.me` as an installed browser app, or Proton Mail Bridge with a native mail client | 2026-08-26 |

Updates are automatic through the nightly image build: CI resolves each product's newest active stable RPM from its official Proton `version.json`, writes the versioned URL and SHA-512 into `build-pins.env`, and thereby invalidates the cached installer layer when Proton publishes a release. Local builds resolve the same manifests directly. Proton publishes no DNF repository and neither RPM is signed; never remove checksum and RPM identity validation from the installers. Proton Mail deliberately excludes Alpha and EarlyAccess entries even when they have a higher version number.

`install-proton-authenticator-latest.sh` also patches only Proton Authenticator's desktop entry with `WEBKIT_DISABLE_DMABUF_RENDERER=1`, Proton's documented workaround for WebKit white screens on NVIDIA; this keeps the P14s reliable without changing global rendering behavior and is harmless on the T580. Proton Mail keeps its vendor launcher unchanged unless a GPU issue is reproduced.

### Phase 3.5 (planned — Playwright system deps)

System libraries the official Playwright Fedora deps list requires. Bake the libs, let `npm`/`npx playwright install` handle the playwright package + browsers per project. See https://playwright.dev/docs/intro

### Phase 4 (planned — NVIDIA variant only)

| Package | Source | Why baked |
|---|---|---|
| `cuda-toolkit` | NVIDIA CUDA container images | nvidia — explicitly not baked: RPM payload lands under `/usr/local`, which bootc strips; use per-project `nvcr.io/nvidia/cuda:*-devel-fedora41` containers |
| `nvtop` | Fedora repo | nvidia (GPU monitoring) |

## System-wide config files (non-package bakes)

| Path in image | Purpose | Why baked |
|---|---|---|
| `/usr/share/wayland-sessions/niri.desktop` | Override `DesktopNames=niri` → `niri;GNOME` so display managers export an XDG_CURRENT_DESKTOP value Chromium recognises | Electron password-store detection — without `GNOME` in the tag, Storage Explorer / Vibe Typer fall back to plaintext backend and refuse to start despite a fully functional `org.freedesktop.secrets` |
| `/usr/lib/environment.d/50-electron-keyring.conf` | Appends `:GNOME` to XDG_CURRENT_DESKTOP for the systemd user manager and everything it spawns | Belt-and-braces for sessions launched outside the DM (TTY, nested compositors) — same root cause as the niri.desktop override |
| `/etc/fonts/conf.d/05-bluefin-writable-cache.conf` | Registers `/var/cache/fontconfig` as a writable, shared fontconfig cachedir | Provides the writable cachedir that `fc-cache-boot.sh` populates (`/var` is runtime state on bootc, so it cannot be baked). **Keep it for that reason, NOT for its position** — being the first cachedir does not win font lookups; it loses. See the corrected rationale in the file header. |
| `/usr/lib/tmpfiles.d/fontconfig-var-cache.conf` | Creates `/var/cache/fontconfig` (0755 root) at boot | `/var` is runtime state on bootc and can't be baked; the cachedir above must be recreated each boot before `fc-cache-boot.service` populates it |
| `/usr/lib/systemd/system/fc-cache-boot.service` (enabled) | Runs `/usr/libexec/bluefin-udx/fc-cache-boot.sh` before `display-manager.service` | Rebuilds the system font cache, verifies the `Noto Serif` canary, then **stamps every cache file to the UNIX epoch**. The epoch stamp is the actual fix for the distrobox cache collision — under composefs `FcCacheTimeValid` short-circuits on `st_mtime == 0`, so an epoch-stamped cache wins from any cachedir position. `TimeoutStartSec=120` so a hung `fc-cache` cannot stall boot. Enabled via the `systemd` module in `common.yml`. |
| `/usr/libexec/bluefin-udx/fc-cache-boot.sh` | The boot-time rebuild + epoch-stamp logic | Moved out of an inline `bash -c` (three levels of nested quoting, one edit from silent breakage). Carries the full root-cause writeup, the measured evidence table, upstream links, and the fontconfig 2.18 caveat. **Read it before changing any font behaviour in this repo.** |

## Build-time maintenance steps

| Step | Purpose | Why baked |
|---|---|---|
| `files/scripts/rebuild-font-cache.sh` | Bakes an epoch-stamped font cache into `/usr/lib/fontconfig/cache` at build time | First-boot coverage before `fc-cache-boot.service` has ever run (`/var` is empty on a new machine). **Corrected 2026-08-03:** previously wrote into `/var/cache/fontconfig` — which bluebuild `post_build.sh` (`rm -rf /var/*`) then deleted, making the bake a silent no-op — and used `--system-only`, which exits non-zero on this image. Now pins the cachedir with a throwaway `FONTCONFIG_FILE`, asserts the canary, and epoch-stamps. |

## Explicitly NOT baked (with reasoning)

| App | Why not | Lives where |
|---|---|---|
| Qutebrowser | Dropped per user — no longer used | n/a |
| Anytype | Official path is Snap/Flatpak/AppImage; only `poesty/anytype` community COPR. Not worth the supply-chain risk. | dropped |
| Obsidian | No Fedora package; historical `alxhr0/Obsidian` COPR died. A documented `cosmicfusion/Obsidian` fallback never existed. | `udx-toolbox` via boxkit |
| SwayOSD | Removed: package source was abandoned at v0.1.0, no service or process used it, and every volume/brightness/media OSD keybind already targets Noctalia. | Noctalia |
| Microsoft Storage Explorer | MS ships AppImage only; rarely launched | `common-toolbox` (distrobox) |
| All language tooling (node, go, python, bun, …) | Per-project pinning matters more than system-wide latest | mise (`dotfiles/dot_config/mise/config.toml.tmpl`) |
| All CLI dev tools (bat, eza, fzf, ripgrep, neovim, starship, …) | Same as above | mise |
| GUI macOS-only apps (Aerospace, Raycast, Granola, Arq, Polypane Mac build, …) | Wrong OS | Homebrew (`dotfiles/.chezmoiscripts/run_once_before_01b-install-homebrew-packages.sh.tmpl`) |
| AppImage-only desktop apps with per-user updaters (VibeTyper, Terax) | Vendor-driven update cadence faster than image rebuild | chezmoi user-scope scripts |
| Flatpak runtimes | Explicit user preference: no Flatpak | n/a |
| `pass-otp` | Password-store OTP is not used; Proton Authenticator owns TOTP. The Noctalia `emrtnn/pass` plugin is password-only in this setup. | n/a |
| `wl-screenrec` | No Fedora/RPM Fusion package or durable scoped COPR. A direct Cargo build would create a permanent Rust dependency layer and fail the maintainable-source criterion. `wf-recorder` supplies region capture with the documented one-audio-source limitation. | n/a |
| Screen Toolkit optional tools (`hyprpicker`, `zbar`, `translate-shell`, `swappy`, `gimp`) | Selected workflow does not use color picking, QR, translation, or these annotation fallbacks; `satty` already provides the chosen user-scope annotation path. | existing base/user tooling only; nothing newly baked |
| `mpv` for Screen Toolkit | Only used by the legacy panel recording-preview action; configured panel mode is `standard`. A Linuxbrew binary on one host is not treated as image evidence. | launch saved recordings with the normal desktop handler |
