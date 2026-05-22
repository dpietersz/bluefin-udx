# bluefin-udx

> **U**ltra **D**eveloper e**X**perience — a highly opinionated personal layer on top of [Bluefin DX](https://projectbluefin.io/) by Dimitri Pietersz.
>
> *DX = Developer Experience.  UDX = Ultra Developer Experience.*

---

## What this is (and isn't)

This is the [bootc](https://containers.github.io/bootc/) image I run as my **daily driver** on two Lenovo ThinkPads:

- **T580** (Intel iGPU only) — runs `ghcr.io/dpietersz/bluefin-udx:stable`
- **P14s Gen5 i7** (Intel + NVIDIA RTX) — runs `ghcr.io/dpietersz/bluefin-udx-nvidia:stable`

It is **not** a community distro. It is **not** seeking users or contributors. It exists because:

1. I love [Bluefin DX](https://docs.projectbluefin.io/) as a base.
2. I have specific tools I want pre-installed and configured at the OS layer rather than layered per-machine via `rpm-ostree install`.
3. I want a single source of truth for "what software belongs on the OS" so my two laptops stay identical with zero manual intervention.

If you find ideas here useful for your own custom Bluefin image, **fork freely**. Don't expect support, stable APIs, or any commitment to your use case. The package list reflects *my* daily work, not a thoughtful curation for anyone else.

## Why split this out from dotfiles

`chezmoi` is excellent for user-scope config (`.config/`, `.local/`, `~/Applications/` AppImages, brew, mise). It's a poor fit for system packages on an atomic OS:

- `rpm-ostree install` requires `sudo` + a reboot to take effect — exactly what `chezmoi apply` shouldn't trigger.
- Layered packages slow down every `rpm-ostree upgrade`.
- Per-machine drift is invisible until something breaks differently on two laptops with "the same" dotfiles.

Baking system packages into a custom bootc image fixes all three:

- One nightly CI build → both laptops auto-pull → reboot when convenient.
- Zero per-machine `rpm-ostree install` calls during `chezmoi apply`.
- Atomic rollback (`sudo rpm-ostree rollback`) if a release breaks something.

## What's baked

See [`RECIPE.md`](./RECIPE.md) for the full package manifest with rationale per package and fallback plan if any upstream source dies. High level:

- **Bootstrap** (so the dotfiles SSH/GPG/password-store chain works on first boot): `pass`, `gnupg2`, `age`, `openssh-clients`, `git`, `jq`, `curl`
- **Niri Wayland WM stack**: `niri`, `waybar`, `swayosd`, `kanshi`, `swayidle`, `hyprlock` (fingerprint lockscreen), `mate-polkit`, `SwayNotificationCenter`, `pavucontrol`, `noctalia-shell-v5`
- **Terminals + shell**: `kitty`, `tmux`, `nushell`
- **GUI apps**: Microsoft Teams (with Wayland screen-share patch), Chromium + Browserpass, Zen Browser, Helium, Beekeeper Studio, Zed editor
- **CLI essentials**: `postgresql` (client-only — `psql`, `pg_dump` etc.), `syncthing`, `blueman`, `espanso-wayland`
- **NVIDIA variant only**: full CUDA toolkit + `nvtop`

What's **not** baked (lives in [chezmoi dotfiles](https://github.com/dpietersz/dotfiles) or distrobox toolboxes):

- All language tooling (node, go, python, bun, ...) — managed by `mise`
- All CLI dev tools (bat, eza, fzf, ripgrep, neovim, starship, lazygit, ...) — managed by `mise`
- macOS apps (Aerospace, Raycast, Granola, ...) — managed by Homebrew
- `Obsidian`, `Polypane`, `Bruno`, `LocalSend`, `Microsoft Storage Explorer` — distrobox toolbox (companion repo: `udx-orbit`)

## Using it on your own machine

> **Warning**: You almost certainly don't want this. The package list is mine. Fork the repo and edit `recipes/common.yml` to your own taste before rebasing anything.

If you've forked and edited:

```bash
# 1. Install vanilla Bluefin DX from a USB stick
# 2. First boot, open a terminal, rebase:
sudo rpm-ostree rebase ostree-unverified-registry:ghcr.io/<you>/<your-image>:stable
sudo systemctl reboot

# 3. After reboot, verify:
rpm-ostree status     # booted image should be your fork
```

On Bluefin with `bootc` CLI present:

```bash
sudo bootc switch ghcr.io/<you>/<your-image>:stable
```

## Daily updates

Images are rebuilt nightly by [GitHub Actions](.github/workflows/build.yml) at 04:20 UTC. Bluefin's `rpm-ostreed-automatic.timer` checks every 6 hours and stages updates; they apply on next reboot. Toggle the timer with `ujust toggle-updates`.

So in practice: you reboot when you feel like it; you're always within 24 hours of the latest CI build.

## Cosign verification

Images are signed with `cosign`. Public key: [`cosign.pub`](./cosign.pub).

The pubkey, a `containers/registries.d` snippet, and the matching `policy.json`
entry are all baked into the image itself (see `files/system/usr/lib/pki/containers/`,
`files/system/etc/containers/registries.d/dpietersz.yaml`, and
`files/scripts/install-cosign-policy.sh`). After the first `ostree-unverified-registry:`
rebase to bootstrap the trust files, switch over to the signed URL so every
subsequent pull verifies the cosign signature before deploying:

```bash
sudo rpm-ostree rebase ostree-image-signed:docker://ghcr.io/dpietersz/bluefin-udx-nvidia:stable
sudo systemctl reboot
```

(Use the `bluefin-udx` image without the `-nvidia` suffix on Intel/AMD machines.)

To verify manually from userspace:

```bash
cosign verify --key cosign.pub ghcr.io/dpietersz/bluefin-udx-nvidia:stable
```

After the reboot, `rpm-ostree status` should show `ostree-image-signed:docker://…`
instead of `ostree-unverified-registry:…`.

## Local iteration (for fork maintainers)

Build + smoke-test a recipe locally without pushing to CI:

```bash
# Install bluebuild CLI from the official installer container
mkdir -p ~/.local/bin
CID=$(podman create ghcr.io/blue-build/cli:latest-installer /bin/true)
podman cp "$CID:/out/bluebuild" ~/.local/bin/bluebuild
podman rm "$CID"

# Build + smoke-test
./scripts/local-build-test.sh bluefin-udx
./scripts/local-build-test.sh bluefin-udx-nvidia
```

CI runs the same smoke-boot gate after building; the image is only pushed to ghcr if all expected binaries and config files are present.

## Maintenance

See [`MAINTENANCE.md`](./MAINTENANCE.md) for the quarterly review checklist. Renovate watches the base image, GitHub Actions versions, and the third-party repos for drift; PRs land weekly on Monday morning.

## Related repos

- **[dpietersz/dotfiles](https://github.com/dpietersz/dotfiles)** — user-scope config (chezmoi-managed), runs on udx + macOS
- **`udx-orbit`** — distrobox toolbox companion holding apps with no Fedora packaging (Obsidian, Polypane, Bruno, LocalSend, MS Storage Explorer) *(WIP — coming soon)*

## License

[MIT](./LICENSE). Recipes, scripts, and docs are mine to share. The packages they pull in have their own licenses, owned by their respective upstreams.
