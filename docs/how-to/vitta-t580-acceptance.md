# Vitta T580 acceptance

Run this live on the T580 with the owner. Record a result for every numbered check; do not promote Vitta from this runbook.

## Preconditions

From the `bluefin-udx` checkout, confirm PR #8 is merged and the published testing image is both available and signed:

```bash
cd ~/dev/Projects/bluefin-udx
gh pr view 8 --repo dpietersz/bluefin-udx --json state,mergedAt
skopeo inspect docker://ghcr.io/dpietersz/vitta:testing
cosign verify --key cosign.pub ghcr.io/dpietersz/vitta:testing
```

The dotfiles `vitta` worktree (`~/dotfiles-vitta`) must already be merged into dotfiles `main`. On the T580, update the main checkout that Chezmoi uses:

```bash
git -C ~/dotfiles status --short --branch
git -C ~/dotfiles pull --ff-only
```

Record the current deployment before switching; it is the rollback target:

```bash
rpm-ostree status
```

Vitta inherits the `docker` transport policy entry for `ghcr.io/dpietersz` in `/etc/containers/policy.json`, installed by `files/scripts/install-cosign-policy.sh` through `common.yml`. Confirm that the current deployment already trusts that scope:

```bash
sudo jq '.transports.docker["ghcr.io/dpietersz"]' /etc/containers/policy.json
```

It must show a `sigstoreSigned` policy. The Vitta image uses the same boot-image signing key as `bluefin-udx`, so the signed switch below works when this entry is present.

## Switch and first login

```bash
sudo bootc switch --enforce-container-sigpolicy ghcr.io/dpietersz/vitta:testing
sudo systemctl reboot
```

At this reboot, the LUKS prompt is the stock prompt; boot-splash appearance is out of scope. Log in through the Vitta greeter, then refresh Chezmoi's data and deploy the Vitta-aware configuration before restarting:

```bash
chezmoi init
chezmoi apply
sudo systemctl reboot
```

## Acceptance checks

### 1. LUKS boot prompt

At the switch reboot, enter the normal LUKS passphrase. The stock prompt must unlock the disk and reach the Vitta greeter.

> **Result:** [ ] Pass  [ ] Fail
>
> **Notes:**

### 2. Greeter, login, and keyring

At the greeter, compare its palette with the currently selected mode, log in, then confirm the login keyring is unlocked. Open Teams and Storage Explorer; neither may request a separate keyring password.

```bash
vitta-theme mode
busctl --user get-property org.freedesktop.secrets /org/freedesktop/secrets/collection/login org.freedesktop.Secret.Collection Locked
```

Expected: the greeter matches the reported `light` or `dark` mode, login succeeds, and `busctl` returns `b false`.

> **Result:** [ ] Pass  [ ] Fail
>
> **Notes:**

### 3. Niri/Noctalia session and Chezmoi deployment

Confirm the Wayland session, Electron-compatible desktop tag, Vitta Chezmoi identity, and deployed lock script. Visually compare the niri and Noctalia session with the previous `bluefin-udx` desktop.

```bash
loginctl show-session "$XDG_SESSION_ID" -p Type
printf '%s\n' "$XDG_CURRENT_DESKTOP" | grep -F GNOME
chezmoi data | grep -E 'isVitta|isMyImage|expectedImageFamily'
test -x ~/.local/bin/scripts/niri-lock.sh
pgrep -a noctalia
```

Expected: `Type=wayland`; `XDG_CURRENT_DESKTOP` contains `GNOME`; Chezmoi reports `isVitta = true`, `isMyImage = true`, and the Vitta image family; the lock script and Noctalia are present.

> **Result:** [ ] Pass  [ ] Fail
>
> **Notes:**

### 4. Lock screen in both modes

Test once while `vitta-theme mode` reports `light` and once while it reports `dark`. `vitta-theme mode --at` only evaluates a hypothetical time and cannot control Hyprlock, so use the live mode for each lock. Lock with the command below (or `Ctrl+Alt+L`), verify the four-stripe Vitta look, and unlock with the account password.

```bash
vitta-theme mode
~/.local/bin/scripts/niri-lock.sh
# After unlocking:
grep -im1 'mode' ~/.cache/vitta/hyprlock-theme.conf
```

The mode header in `~/.cache/vitta/hyprlock-theme.conf` must match the live `vitta-theme mode` result. Repeat at the other live mode.

> **Result:** [ ] Pass  [ ] Fail
>
> **Notes:**

### 5. Teams screen sharing

```bash
teams-for-linux
```

Join a test call, then share each source through the Wayland portal:

1. Share one application window; the remote participant or preview must receive it.
2. Share a full screen; the remote participant or preview must receive it.

> **Result:** [ ] Pass  [ ] Fail
>
> **Notes:**

### 6. OBS virtual camera

Start OBS and start its virtual camera. Confirm that the loopback device and its Secure Boot signer are present, then select the OBS virtual camera in Teams and Chromium.

```bash
obs
v4l2-ctl --list-devices
modinfo -F signer v4l2loopback
```

Expected: `v4l2-ctl` lists `/dev/video10`; `modinfo` prints a non-empty signer; Teams and Chromium can select and display the OBS virtual camera.

> **Result:** [ ] Pass  [ ] Fail
>
> **Notes:**

### 7. Docker, distroboxes, and exported applications

```bash
docker run --rm hello-world
id -nG
distrobox list
for box in udx-toolbox ubuntu-gui-toolbox insta360-toolbox playwright-toolbox; do
  distrobox enter "$box" -- true
done
```

Expected: Docker prints its success message; `id -nG` includes `docker` and `libvirt`; every listed toolbox starts. From the application launcher, start an exported application from `udx-toolbox` (for example Obsidian) and one from `ubuntu-gui-toolbox` (LocalSend); both must open.

> **Result:** [ ] Pass  [ ] Fail
>
> **Notes:**

### 8. Windows work VM and VirtioFS

Start the existing VM; do not recreate it. On Windows, sign in and run the PowerShell command to verify its host shares. The authoritative recovery details and drive ownership are in `~/dotfiles/docs/how-to/windows-work-vm.html`.

```bash
virsh -c qemu:///system start windows-work
virsh -c qemu:///system domstate windows-work
# In Windows PowerShell:
Get-PSDrive -Name Z,Y,X | Select-Object Name, Root
```

Expected: the guest is running and exposes `Z:` (read-only `~/dev`), `Y:` (read/write `~/dev/Downloads`), and `X:` (read/write Hollands Kroon repository share).

> **Result:** [ ] Pass  [ ] Fail
>
> **Notes:**

### 9. Developer tools and connectivity

```bash
getent passwd "$USER"
bash -lc 'command -v brew && brew --version'
zeditor --version
code --version
tailscale status
```

Expected: the account's login shell is `/bin/bash`; the Bash login shell finds Homebrew; Zed, VS Code, and Tailscale all respond; Tailscale reports the machine online.

> **Result:** [ ] Pass  [ ] Fail
>
> **Notes:**

### 10. Roll back to bluefin-udx

Run this last: it ends the Vitta trial deployment.

```bash
sudo bootc rollback
sudo systemctl reboot
rpm-ostree status
```

Expected: the T580 boots its previous `bluefin-udx` deployment cleanly and `rpm-ostree status` shows it as booted.

> **Result:** [ ] Pass  [ ] Fail
>
> **Notes:**

## Known follow-ups

- P14s/NVIDIA acceptance is separate from this T580-first run.
- The fingerprint greeter path is separate; this runbook covers the T580 password/keyring path.
- Boot-splash appearance is out of scope.
- Promotion of `ghcr.io/dpietersz/vitta:testing` to `:stable` is a separate owner-approved change after all acceptance checks pass.
