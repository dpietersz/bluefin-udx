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
| `grim` | Fedora repo | system-integration (Wayland screenshot capture — needed by niri+satty pipeline; satty itself lives user-scope in dotfiles via upstream GH release tarball, not baked, because the only COPR `mineiro/satty` is single-maintainer / 3-commits-young) |
| `slurp` | Fedora repo | system-integration (Wayland region selector — paired with grim) |

### Phase 3 (planned — GUI apps)

| Package | Source | Why baked |
|---|---|---|
| Chromium | Fedora repo | system-integration |
| Browserpass + browserpass-chromium | Fedora repo | system-integration (native messaging w/ pass) |
| Beekeeper Studio | vendor RPM (`beekeeperstudio.io`) | stable + integration |
| Bruno | vendor RPM (`usebruno.com`) | stable + integration |
| LocalSend | GH releases RPM | system-integration (host firewall already wired) |
| Polypane | AppImage extract → `/opt/polypane` | stable + integration |
| Obsidian | COPR `cosmicfusion/Obsidian` (fallback: AppImage extract) | stable |
| Zen Browser | COPR `sneexy/zen-browser` (fallback: `firminunderscore/zen-browser`) | daily driver browser |
| Helium | Terra `helium-browser-bin` (pin version) | secondary browser |

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
