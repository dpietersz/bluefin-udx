# bluefin-udx

Personal [Bluefin DX](https://docs.projectbluefin.io/) custom image, built with [BlueBuild](https://blue-build.org/). Two variants:

- `ghcr.io/dpietersz/bluefin-udx:stable` — Intel/AMD (e.g. ThinkPad T580)
- `ghcr.io/dpietersz/bluefin-udx-nvidia:stable` — NVIDIA open kernel modules (e.g. ThinkPad P14s Gen5 RTX)

## What this is

A thin layer on top of `bluefin-dx` that bakes in:

- **Bootstrap-critical tooling** (`pass`, `gnupg2`, `age`, `openssh-clients`, `git`, `jq`, `curl`) so the [dotfiles](https://github.com/dpietersz/dotfiles) SSH/GPG/password-store decryption chain works on first boot of a fresh machine without any `rpm-ostree` layering from chezmoi.
- **Microsoft Teams** (`teams-for-linux` from `repo.teamsforlinux.de`) with a Wayland integration patch — screen sharing works natively via the xdg-desktop-portal + PipeWire pipeline. The original motivator for splitting OS-level concerns out of chezmoi.

Later phases (see [Plans](https://github.com/dpietersz/dotfiles/tree/main/Plans)) add system tools, GUI apps, Playwright system deps, and CUDA toolkit (NVIDIA variant only).

Full package manifest and rationale per package: see [`RECIPE.md`](./RECIPE.md).

## Bootstrap order on a fresh machine

```
1. Install vanilla Bluefin DX from USB
2. sudo bootc switch ghcr.io/dpietersz/bluefin-udx:stable    # or -nvidia
3. systemctl reboot
   (now pass / gpg / age / ssh / git / jq / curl are on PATH)
4. chezmoi init dpietersz/dotfiles
5. chezmoi apply
   - 08-decrypt-keys     prompts for passphrase, decrypts SSH+GPG
   - 09-add-ssh-key       adds key to agent
   - 10-clone-password    clones password-store
   - 01-install-packages  runs mise install (pass is on PATH so GH token works)
   - …all run_onchange_* scripts proceed normally
```

The image provides the **tools**. Secrets (the age-encrypted SSH/GPG keys, the
password store) stay in the dotfiles repo and never touch this image.

## Daily updates

Both variants are rebuilt nightly by GitHub Actions; `bootc upgrade && systemctl reboot` on each machine pulls the latest. Image signed with cosign — verification key is [`cosign.pub`](./cosign.pub).

## Local iteration

```bash
./scripts/local-build-test.sh                  # build + smoke-test Intel variant
./scripts/local-build-test.sh bluefin-udx-nvidia
```

See [`MAINTENANCE.md`](./MAINTENANCE.md) for the quarterly review checklist.
