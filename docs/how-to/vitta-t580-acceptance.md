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

### If the greeter does not appear

The first greetd boot exercises pieces no CI step can: `systemd-sysusers` creating the `greetd` user, the `/etc` merge pointing `display-manager.service` at `greetd.service`, logind seat access for cage, and SELinux for cage and Quickshell. If any of them fails, greetd restart-loops and VT1 stays blank.

1. Press `Ctrl+Alt+F2` (or `Ctrl+Alt+F3`) for a text console; cage runs with `-s`, so VT switching works even while the greeter is up. Log in with the normal account.
2. Collect the evidence before changing anything, and record it in the check 1 or 2 notes:

   ```bash
   journalctl -b -u greetd -u systemd-sysusers
   getent passwd greetd
   ls -ldZ /var/lib/greetd
   readlink -f /etc/systemd/system/display-manager.service
   sudo ausearch -m avc -ts boot
   ```

3. Return to the previous `bluefin-udx` deployment:

   ```bash
   sudo bootc rollback && sudo systemctl reboot
   ```

   If no console login works, reboot and pick the previous deployment in the GRUB menu instead (press `Esc` during boot to show the menu); then run `sudo bootc rollback` from the booted `bluefin-udx` so it stays the default.
4. Back on `bluefin-udx`, refresh Chezmoi's data as in check 10 (`chezmoi init && chezmoi apply`).

## Acceptance checks

### 1. LUKS boot prompt

At the switch reboot, enter the normal LUKS passphrase. The stock prompt must unlock the disk and reach the Vitta greeter.

> **Result:** [ ] Pass  [ ] Fail
>
> **Notes:**

### 2. Greeter, login, and keyring

At the greeter, compare its palette with the currently selected mode and with layout A (`docs/superpowers/specs/assets/vitta-login-layout-a.png`): there is no card or frame; four flat, touching bands (no bevel, shadow or gradient) run edge to edge across the screen a little above the middle, and the logo sits centred on them in a clean round gap. The clock and date are above the bands, the login and password fields and the `host · vitta <version>` line below; nothing overlaps the bands or the logo gap. Boot once docked (laptop plus external monitor) and once undocked: the login screen must fill exactly one screen, never straddling the seam. Type the user name and press `Tab`: focus must move to the password field (`Shift+Tab` goes back). Log in, then confirm the login keyring is unlocked and the greeter's user manager started. Open Teams and Storage Explorer; neither may request a separate keyring password.

```bash
vitta-theme mode
busctl --user get-property org.freedesktop.secrets /org/freedesktop/secrets/collection/login org.freedesktop.Secret.Collection Locked
journalctl -b -u vitta-shadow-sync -u "user@$(id -u greetd).service" --no-pager
```

Expected: the greeter matches the reported `light` or `dark` mode, login succeeds, `busctl` returns `b false`, and the journal shows `Started user@<greetd uid>.service` with no `PAM failed` line. On the first boot after this fix, `vitta-shadow-sync` logs the accounts it gave a locked shadow entry (`greetd` at least).

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

Test once while `vitta-theme mode` reports `light` and once while it reports `dark`. `vitta-theme mode --at` only evaluates a hypothetical time and cannot control Hyprlock, so use the live mode for each lock. Lock with the command below (or `Ctrl+Alt+L`), verify it has the greeter's layout A look (four full-width bands, logo in a round gap on them, clock and date above, password field and host line below), and unlock with the account password. While locked, photograph the screen (hyprlock blocks screenshots) and check that the clock, date, bands, logo, password field and `host · vitta <version>` footer do not overlap (only the bands run into the logo gap), that the bands reach both screen edges, and that the clock and date match the greeter's.

```bash
vitta-theme mode
~/.local/bin/scripts/niri-lock.sh
# After unlocking:
head -n1 ~/.cache/vitta/hyprlock-theme.conf
```

Expected: `# vitta-theme render hyprlock --mode light` or `… --mode dark`, matching the live `vitta-theme mode` result. Any other first line means a fallback was used, which fails this check:

- `# Pre-Vitta Gruvbox fallback: valid even when vitta-theme is unavailable.` — `vitta-theme` could not render, so `niri-lock.sh` wrote the classic pre-Vitta visuals into the cache file.
- A missing file, or one older than the lock (`ls -l --time-style=full-iso ~/.cache/vitta/hyprlock-theme.conf`), together with `niri-lock: using static fallback config` on the lock command's output — the cache could not be written, so hyprlock ran on the static `~/.config/hypr/hyprlock-pre-vitta.conf`.

Repeat at the other live mode.

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
grep -x /home/linuxbrew/.linuxbrew/bin/bash /etc/shells
bash -lc 'command -v brew && brew --version'
zeditor --version
code --version
tailscale status
```

Expected: the account's login shell is Homebrew Bash, `/home/linuxbrew/.linuxbrew/bin/bash` (set by the dotfiles' `run_once_after_05-set-default-shell-bash`), and `/etc/shells` still lists it after the switch; the Bash login shell finds Homebrew; Zed, VS Code, and Tailscale all respond; Tailscale reports the machine online.

> **Result:** [ ] Pass  [ ] Fail
>
> **Notes:**

### 10. Roll back to bluefin-udx

Run this last: it ends the Vitta trial deployment.

```bash
sudo bootc rollback
sudo systemctl reboot
# After logging in to bluefin-udx:
rpm-ostree status
chezmoi init && chezmoi apply
```

Expected: the T580 boots its previous `bluefin-udx` deployment cleanly and `rpm-ostree status` shows it as booted. `chezmoi init` must run after the rollback: until it does, the cached Chezmoi data still says `isVitta = true`, so `verify-image` warns that `bluefin-udx` is the wrong variant and, with no `vitta-theme` on `bluefin-udx`, every lock goes through `niri-lock.sh`'s fallback path instead of the classic configuration.

> **Result:** [ ] Pass  [ ] Fail
>
> **Notes:**

## Known follow-ups

- P14s/NVIDIA acceptance is separate from this T580-first run.
- The fingerprint greeter path is separate; this runbook covers the T580 password/keyring path.
- Boot-splash appearance is out of scope.
- Promotion of `ghcr.io/dpietersz/vitta:testing` to `:stable` is a separate owner-approved change after all acceptance checks pass.
