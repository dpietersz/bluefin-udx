# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

`bluefin-udx` is a personal [bootc](https://containers.github.io/bootc/) image repository. It builds two stable images on `ghcr.io/ublue-os/bluefin-dx[-nvidia-open]` plus Vitta, a testing niri desktop on desktop-less `ghcr.io/ublue-os/base-main:44`:

- `bluefin-udx` — Intel/AMD (ThinkPad T580)
- `bluefin-udx-nvidia` — NVIDIA open kernel (ThinkPad P14s Gen5)
- `vitta` — T580-first replacement, published only as `ghcr.io/dpietersz/vitta:testing` until owner-approved acceptance and promotion

Built nightly (04:20 UTC) and on push to `recipes/`, `scripts/`, `files/`, `cosign.pub`, or the workflow itself. The images are cosign-signed and use the baked trust policy; Vitta CI pushes only `:testing`, date, and SHA tags—never `:stable`. Its Vitta-only modules and overlay live in `recipes/vitta-modules.yml` and `files/vitta/`.

It is **NOT** a community distro. The package list is Dimitri's; forks are welcome but unsupported.

## The three-repo ecosystem (READ THIS FIRST)

This repo is one of three tightly-coupled personal repos. Changes here often imply changes in the others. Always think holistically.

```
┌─────────────────────┐     ┌──────────────────────┐     ┌──────────────────────┐
│   bluefin-udx       │     │     dotfiles         │     │      boxkit          │
│  (THIS REPO)        │     │   (~/dotfiles)       │     │ (~/dev/Projects/     │
│                     │     │                      │     │   boxkit)            │
│ Bootc image         │ ──> │ chezmoi user config  │ ──> │ distrobox toolbox    │
│ System packages     │     │ Per-machine layer    │     │ GUI apps with no     │
│ rpm-ostree layer    │     │ mise / brew / pass   │     │  Fedora packaging    │
└─────────────────────┘     └──────────────────────┘     └──────────────────────┘
       ▲                              │                              ▲
       │                              │                              │
       │     baked into image         │  chezmoi pulls + creates     │
       └──────────────────────────────┴──────────────────────────────┘
                  (auto-export of toolbox apps to host with icons)
```

### Division of responsibility

| Layer | Owns | Examples |
|---|---|---|
| **bluefin-udx (this repo)** | System packages requiring `sudo`/reboot, screen-share/portal/PAM/polkit integration, bootstrap tools required before chezmoi can run | `kitty`, `niri`, `waybar`, `mate-polkit`, `teams-for-linux`, `pass`, `gnupg2`, `age`, `git`, `chromium`, `zen-browser`, `zed`, `beekeeper-studio` |
| **dotfiles (chezmoi)** | User-scope config (`~/.config/`), `mise`-managed CLI tools, secrets via `pass`, per-machine variants via templates, toolbox creation + auto-export | Neovim, starship, ripgrep, bat, eza, all language runtimes, distrobox `.ini` files |
| **boxkit** | GUI apps with no Fedora source (Obsidian, Polypane, Bruno, LocalSend, Storage Explorer, Anytype). Produces `udx-toolbox` (Arch) and `playwright-toolbox` (Ubuntu) images. | `ghcr.io/dpietersz/udx-toolbox`, `ghcr.io/dpietersz/playwright-toolbox` |

**Hard rules** (Dimitri's preferences, baked into the architecture):
- **No Flatpak. No AppImage as primary delivery.** Anything that can't be a Fedora RPM goes into a boxkit toolbox.
- **Atomic OS = no `rpm-ostree install` from chezmoi.** If a package needs `sudo`, bake it here. If it can live as `mise` / brew / toolbox, push it down.
- **One image, two laptops, zero drift.** Anything per-machine belongs in chezmoi templates (gated on `.isBluefin`, `.hardwareModel`, `.hasFingerprintReader`), not in this repo.

### The integration handshake

1. **bluefin-udx** boots → provides `pass`, `gpg`, `age`, `ssh`, `git`, `jq`, `curl` so chezmoi's first apply works.
2. **chezmoi apply** in `~/dotfiles` → decrypts keys (`08-decrypt-keys`), clones password-store, installs mise tools, installs brew packages, **creates distrobox toolboxes via `run_after_11-create-toolboxes.sh.tmpl`**.
3. The toolbox script `~/dotfiles/.chezmoiscripts/run_after_11-create-toolboxes.sh.tmpl`:
   - Reads `.ini` files from `~/.config/distrobox/`
   - Uses `skopeo inspect` to detect when ghcr toolbox images have a newer digest → rebuilds the box
   - Runs `~/.local/bin/scripts/distrobox-auto-export.sh` inside each box → exports apps + `.desktop` files + icons to the host
4. Result: a GUI app baked into a **boxkit** toolbox appears on the host (niri/wofi menu) with the right icon, with zero manual `distrobox-export` calls.

So a change of the form "I want app X" routes as:
- Fedora RPM exists + integration-sensitive → **this repo**, add to `recipes/common.yml`, document in `RECIPE.md`
- Fedora RPM exists + not integration-sensitive → likely brew/mise in **dotfiles**
- No Fedora RPM, no Flatpak/AppImage allowed → **boxkit**, add to `udx-toolbox`, then the dotfiles auto-export handles host integration

## Authoritative docs to consult before changing anything

- **`README.md`** — what this is, fork policy, cosign rebase commands
- **`RECIPE.md`** — **the package manifest**. Every baked package has a row. Adding a package without a row is a recipe-review red flag. Has the explicit bake/keep criteria (stable >6mo + integration-sensitive + maintainable Fedora source) and the bake-reason taxonomy (`bootstrap`, `screen-share`, `system-integration`, `system-tool`, `dev-system-deps`, `nvidia`).
- **`MAINTENANCE.md`** — quarterly review checklist (COPR liveness, vendor RPM repo 200s, CUDA workflow sanity, bake-pruning). Run before adding anything new — it's where stale packages get dropped.

If a request is ambiguous about *where* a package belongs, walk the bake-criteria in `RECIPE.md` and the division-of-responsibility table above before opening a recipe.

## Repository layout

```
recipes/
  common.yml              # Shared module set — every image pulls from this
  bluefin-udx.yml         # Intel/AMD entry point (base: bluefin-dx)
  bluefin-udx-nvidia.yml  # NVIDIA entry point (base: bluefin-dx-nvidia-open)
  vitta.yml               # Vitta entry point (base: base-main:44)
  vitta-modules.yml       # Vitta-only desktop plumbing and module order
files/
  scripts/                # Inline bluebuild scripts (teams-wayland-patch, install-cosign-policy)
  system/                 # Overlay copied to image root via the `files` module
    etc/containers/registries.d/dpietersz.yaml   # cosign sigstore mapping
    etc/yum.repos.d/beekeeper-studio.repo        # corrected vendor .repo (upstream points gpgkey at a signature file)
    usr/lib/environment.d/50-electron-keyring.conf  # Forces :GNOME into XDG_CURRENT_DESKTOP for Electron keyring detection
    usr/lib/pki/containers/{bluefin-udx,bluefin-udx-nvidia}.pub  # cosign pubkeys baked into image
    usr/share/wayland-sessions/niri.desktop      # Override DesktopNames=niri → niri;GNOME for Electron password-store detection
  vitta/                  # Vitta-only overlay (greeter, theme, repos, services)
scripts/
  local-build-test.sh     # Local mirror of the CI smoke-boot gate (Phase checks live in here)
  check-fedora-next.sh    # Resolves bluefin and Vitta recipe sets via RECIPES/BASE_IMAGE env
  vitta-gap-report.sh     # Compares Bluefin DX and base-main package/integration-file gaps
tests/                    # Regression tests, including Vitta theme and group reconciliation
cosign.pub                # Public key matching cosign.key (cosign.key is the signing secret, gitignored in spirit)
.github/workflows/build.yml   # Nightly + on-push build/sign/push pipeline
```

## Commands

```bash
# Local build + smoke-boot of a recipe (mirrors CI gate exactly)
./scripts/local-build-test.sh bluefin-udx
./scripts/local-build-test.sh bluefin-udx-nvidia
./scripts/local-build-test.sh vitta

# Bootstrap bluebuild CLI without brew (matches README/CI installer pattern)
CID=$(podman create ghcr.io/blue-build/cli:latest-installer /bin/true)
podman cp "$CID:/out/bluebuild" ~/.local/bin/bluebuild
podman rm "$CID"

# Will every recipe package still resolve on the next Fedora major?
# (auto-detects N+1 from bluefin-dx:stable; also runs nightly in CI)
./scripts/check-fedora-next.sh
./scripts/check-fedora-next.sh 45
RECIPES="recipes/common.yml recipes/vitta.yml recipes/vitta-modules.yml" \
  BASE_IMAGE=ghcr.io/ublue-os/base-main ./scripts/check-fedora-next.sh

# Verify a signed image manually (cosign.pub is the same key baked at /usr/lib/pki/containers/)
cosign verify --key cosign.pub ghcr.io/dpietersz/bluefin-udx-nvidia:stable

# Host-side: check what's currently booted and roll back if needed
rpm-ostree status
sudo rpm-ostree rollback
```

Validation is the regression tests plus the build gate and smoke-boot. Run focused tests in `tests/` when changing their owner; `tests/test_vitta_groups.sh` covers the every-wheel-user reconciliation. The `local-build-test.sh` checks must stay in sync with `recipes/common.yml` and `recipes/vitta-modules.yml` — when you add a package, add the corresponding `check_rpm` / `check_bin` line in the applicable smoke gate.

## When making changes

1. **Adding a package**: Decide it actually belongs here (see division of responsibility + `RECIPE.md` bake criteria). Shared packages go in `recipes/common.yml` under the correct Phase and are built into `bluefin-udx`, `bluefin-udx-nvidia`, and `vitta`. Vitta-only packages and files go in `recipes/vitta-modules.yml` and `files/vitta/`, never `files/system/`. Add a row to `RECIPE.md` with source, bake reason, and fallback. Add matching `check_rpm` / `check_bin` coverage to both smoke gates: the inline gate in `.github/workflows/build.yml` and `scripts/local-build-test.sh`; put Vitta-only checks in each gate's Vitta branch. For shared changes, run `./scripts/local-build-test.sh bluefin-udx`, `./scripts/local-build-test.sh bluefin-udx-nvidia`, and `./scripts/local-build-test.sh vitta` before pushing; for Vitta-only changes, run the Vitta recipe.
2. **Adding a vendor repo**: If upstream's `.repo` file is broken (e.g. `gpgkey=` pointing at a signature file like Beekeeper Studio did), ship a corrected shared repo at `files/system/etc/yum.repos.d/` rather than fighting upstream. Put Vitta-only repos in `files/vitta/etc/yum.repos.d/`. Note it explicitly in the owning recipe so the next reader doesn't re-add the broken URL.
3. **Adding a COPR**: Verify it's had a build in the last 90 days and supports `%OS_VERSION%` substitution. Document the fallback in `RECIPE.md`. Add it to the quarterly check in `MAINTENANCE.md`.
4. **Anything CUDA**: Do not bake `cuda-toolkit`. The atomic FS strips `/usr/local` at commit and the RPM installs there. Use `nvcr.io/nvidia/cuda:*-devel-fedora41` containers per-project (rationale is documented inline in `bluefin-udx-nvidia.yml`).
5. **Anything that needs the toolbox**: Do not add it here. Push to `~/dev/Projects/boxkit` (`udx-toolbox`), and the `~/dotfiles` auto-export wiring will handle host integration.
6. **Anything that's user-scope config**: Do not add it here. Push to `~/dotfiles` (chezmoi). Shared system config that *must* exist at boot before chezmoi runs goes in `files/system/`; Vitta-only system config goes in `files/vitta/`.

## Niri / Electron keyring trap (don't break this)

Two files in `files/system/` exist for one specific, hard-won reason: Electron apps detect the secret-storage backend via `XDG_CURRENT_DESKTOP`, and niri's default tag doesn't include `GNOME`. Without these, Storage Explorer / Vibe Typer / Teams fall back to a plaintext backend and refuse to start despite `org.freedesktop.secrets` working fine.

- `usr/share/wayland-sessions/niri.desktop` — `DesktopNames=niri;GNOME` for display-manager-launched sessions
- `usr/lib/environment.d/50-electron-keyring.conf` — appends `:GNOME` for systemd user manager (TTY/nested sessions)

If anyone "cleans up" by removing one, both must go. They are a matched pair.
