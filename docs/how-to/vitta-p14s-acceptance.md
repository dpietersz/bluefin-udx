# Vitta NVIDIA P14s acceptance

Run this live on the ThinkPad P14s Gen 5 with the owner. The switch is the
owner's decision; nothing in this document runs by itself. Record a result for
every numbered check. Immediately after the first Vitta boot, pin the Bluefin
deployment. Until then, rollback reaches Bluefin only while it is still the
previous deployment; the pin, its GRUB entry, or a signed Bluefin rebase gets
back to `bluefin-udx-nvidia:stable` afterwards.

## Before the switch

This PR must be merged. The `build` workflow on `main` for that merge must be
green. The dotfiles `vitta-nvidia` branch, including
`run_onchange_after_16a-keyring-passwordless-greetd`, must be merged to
dotfiles `main` before switching.

Record the testing image that will be tested. Substitute the recorded digest
for `<digest>` in later checks.

```bash
cd ~/dev/Projects/bluefin-udx
skopeo inspect --no-creds docker://ghcr.io/dpietersz/vitta-nvidia:testing --format "{{.Digest}} {{.Created}}"
# Optional, when cosign is available:
cosign verify --key cosign.pub ghcr.io/dpietersz/vitta-nvidia@<digest>
```

Expected: the creation time is after the merge. The optional cosign check
succeeds. `rpm-ostree` enforces this signature again through
`ostree-image-signed:`.

Save the current deployment facts and the passwordless keyring. Do not copy the
keyring after the first graphical greetd login.

```bash
mkdir -p ~/vitta-nvidia-acceptance
rpm-ostree status -v | tee ~/vitta-nvidia-acceptance/rpm-ostree-status.before
rpm-ostree kargs | tee ~/vitta-nvidia-acceptance/rpm-ostree-kargs.before
virsh -c qemu:///system dumpxml windows-work > ~/vitta-nvidia-acceptance/windows-work.before.xml
authselect current | tee ~/vitta-nvidia-acceptance/authselect.before
fprintd-list "$USER" | tee ~/vitta-nvidia-acceptance/fprintd.before
flatpak list | wc -l | tee ~/vitta-nvidia-acceptance/flatpak-count.before
head -c 9 ~/.local/share/keyrings/login.keyring
cp -p ~/.local/share/keyrings/login.keyring ~/vitta-nvidia-acceptance/login.keyring.before
ls -l ~/.local/share/keyrings/login.keyring ~/vitta-nvidia-acceptance/login.keyring.before
```

Expected: the current deployment is `bluefin-udx-nvidia:stable`; authselect
includes `with-fingerprint`; the enrolled Synaptics finger is listed; and
`head` prints `[keyring]`. If it does not, stop: this runbook preserves a
passwordless keyring only. The backup copy has the same size and timestamp as
`login.keyring`. Today, `rpm-ostree status -v` prints:

```text
InactiveRequests: fuse-libs
LocalPackages: equibop-3.3.2-1.x86_64
```

Bluefin ships `fuse-libs`, so its request is inactive; Vitta does not, so the
same request must become a layer. Record the Flatpak count; Flatpak state is in
`/var` and must survive the rebase.

## 1. Stage the signed rebase

```bash
sudo rpm-ostree rebase ostree-image-signed:docker://ghcr.io/dpietersz/vitta-nvidia:testing
rpm-ostree status
rpm-ostree status -v
```

First confirm that the first deployment listed by `rpm-ostree status` is the
staged `vitta-nvidia:testing` deployment. Index `0` means that first-listed
deployment. Compare its `Digest:` line in `rpm-ostree status -v` with the
digest recorded above. If it differs, CI published a newer build in between:
record the new digest by re-running the `skopeo` command and continue, or run
`sudo rpm-ostree cleanup -p` and start over. In its `rpm-ostree status -v`
entry, expect both:

```text
LayeredPackages: fuse-libs
LocalPackages: equibop-…
```

If `fuse-libs` is missing, booting is still allowed. After the switch, run
`sudo rpm-ostree install fuse-libs`; AppImages need its `libfuse.so.2`.

Check the staged deployment's kernel arguments exactly once each:

```bash
for arg in \
  rd.driver.blacklist=nouveau \
  modprobe.blacklist=nouveau \
  nvidia-drm.modeset=1 \
  initcall_blacklist=simpledrm_platform_driver_init
do
  printf '%s: ' "$arg"
  rpm-ostree kargs --deploy-index=0 | tr ' ' '\n' | grep -Fxc -- "$arg"
done
```

Expected: four lines ending in `1`, one per argument. These come from
`/usr/lib/bootc/kargs.d/00-bluebuild-nvidia-kargs.toml`, owned by the BlueBuild
akmods module. If any count is not `1`, do not reboot. Run
`sudo rpm-ostree cleanup -p` and report the output.

> **Result:** [ ] Pass  [ ] Fail
>
> **Notes:**

## 2. First boot: Plymouth, LUKS, and greeter

```bash
systemctl reboot
```

Expected: because simpledrm is disabled, the splash and LUKS prompt appear
when initramfs `i915` takes over. On the 2560x1600 panel they are crisp, not an
upscaled 1280x800 layout. The splash has the Fedora and Lenovo badge. The LUKS
prompt has its bands flush to the bottom edge, as on the T580.

If the prompt is black or unusable, type the passphrase blind and press Enter,
or press `Esc` for the text prompt. If that does not boot, select the previous
deployment in GRUB.

Before any greeter check or automatic update can replace the previous
deployment, pin Bluefin. `rpm-ostree status` lists deployments in index order
starting at `0`. With the booted Vitta deployment first and
`bluefin-udx-nvidia:stable` second, Bluefin is index `1`; otherwise count the
listed deployments to its index.

```bash
rpm-ostree status
sudo ostree admin pin 1
rpm-ostree status
```

Expected: the second status retains Bluefin as a pinned deployment. The pin
survives future Vitta updates until it is explicitly unpinned. Automatic
updates stage new `:testing` builds nightly. For the acceptance week, an
optional pause keeps the tested image fixed until an explicit `rpm-ostree
upgrade`:

```bash
sudo systemctl disable --now rpm-ostreed-automatic.timer
```

Re-enable the timer after acceptance if it was paused:

```bash
sudo systemctl enable --now rpm-ostreed-automatic.timer
```

At the greeter, confirm the bands and fields are edge to edge on the internal
panel. Then repeat with the Thunderbolt dock connected and the lid closed; it
must use one display rather than span a seam. Leave the greeter idle for five
minutes; it must blank.

```bash
/usr/libexec/vitta/vitta-greeter-gpu
journalctl -b -u greetd --no-pager
cat /sys/bus/pci/devices/0000:01:00.0/power/runtime_status
```

Expected: the helper prints a DRM path such as `/dev/dri/card0`; the card it
prints belongs to the Intel GPU at PCI `0000:00:02.0`; the greetd journal has
no error; and the NVIDIA device is `suspended` while idle. Check the selected
card explicitly:

```bash
card=$(/usr/libexec/vitta/vitta-greeter-gpu)
readlink -f "/sys/class/drm/${card##*/}/device"
```

Expected: the path ends in `0000:00:02.0`.

After this first successful boot, record the `Digest:` line for the booted
(`●`) deployment. It must equal the digest recorded before the rebase. It is
the tested source for promotion. Also prove this image includes the PR.

```bash
rpm-ostree status | tee ~/vitta-nvidia-acceptance/rpm-ostree-status.first-vitta-boot
rpm -q fprintd-pam
grep -E '^-?auth[[:space:]].*system-auth' /etc/pam.d/greetd
```

Expected: the saved status has the booted Vitta deployment and its recorded
`Digest: sha256:…` line; `fprintd-pam` is installed; and the final command
prints nothing.

> **Result:** [ ] Pass  [ ] Fail
>
> **Notes:**

## 3. Login, lock, sudo, and keyring

Follow these steps in order. The text console login does not touch the
keyring. Do this before the first graphical login.

1. At the Vitta greeter, press `Ctrl+Alt+F3` and log in on the text console.
   **Warning:** This machine asks for a fingerprint first because authselect
   puts the fingerprint module first for console logins and `sudo`. Touch the
   sensor, or wait about 30 seconds for the `Password:` prompt; the `sudo` in
   the next command does the same. Comment out precisely the three keyring PAM
   lines:

   ```bash
   sudo sed -i -E 's@^([[:space:]]*-?(auth|password|session)[[:space:]].*pam_gnome_keyring\.so.*)$@# [keyring-pam disabled] \1@' /etc/pam.d/greetd
   grep -n pam_gnome_keyring /etc/pam.d/greetd
   grep -E "^auth" /etc/pam.d/greetd
   ```

   Expected: the first `grep` prints three lines with
   `# [keyring-pam disabled]` immediately after the line number. The second still lists `pam_unix.so`,
   `pam_deny.so`, and `pam_permit.so`. Run `exit`, return to the login screen
   with `Ctrl+Alt+F1` (`greetd` uses `vt = 1`), enter one wrong password, then
   log in with the account password. The wrong password must fail in about 2–3
   seconds with no fingerprint prompt or timeout.
2. In the first graphical session, deploy the guard. From then on it owns
   `/etc/pam.d/greetd`: it keeps those three lines commented and rebuilds the
   file from `/usr/etc/pam.d/greetd` when an image changes it.

   ```bash
   cd ~/dotfiles
   git pull --ff-only
   chezmoi init
   chezmoi apply
   chezmoi data --format json | jq '{isVitta, isMyImage, expectedImageFamily}'
   grep -n pam_gnome_keyring /etc/pam.d/greetd
   ```

   Expected:

   ```json
   {
     "isVitta": true,
     "isMyImage": true,
     "expectedImageFamily": "vitta-nvidia"
   }
   ```

   The final command prints three lines with `# [keyring-pam disabled]`
   immediately after the line number.
3. After this graphical login, and again after a reboot, verify the keyring:

   ```bash
   head -c 9 ~/.local/share/keyrings/login.keyring
   ```

   Expected: `[keyring]`, with no keyring unlock prompt.
4. Only if the command prints `GnomeKeyr`, a graphical login happened before
   the lines were commented and re-encrypted the keyring. Confirm the three
   lines are commented, log out, and use `Ctrl+Alt+F3` to log in on the text
   console. If a daemon runs, stop it; then preserve the encrypted file and
   restore the backup:

   ```bash
   pkill -u "$USER" gnome-keyring-daemon
   mv ~/.local/share/keyrings/login.keyring ~/.local/share/keyrings/login.keyring.reencrypted
   cp -p ~/vitta-nvidia-acceptance/login.keyring.before ~/.local/share/keyrings/login.keyring
   exit
   ```

   Return to greetd with `Ctrl+Alt+F1` and log in. Secrets saved since the
   backup remain in `login.keyring.reencrypted`, which opens with the login
   password.

> **Result:** [ ] Pass  [ ] Fail
>
> **Notes:**

## 4. Confirm Vitta dotfiles and authentication

```bash
sudo -k
sudo true
authselect current
```

Expected: `sudo true` requests the enrolled finger, and `authselect current`
still lists `with-fingerprint`. Lock with `Ctrl+Alt+L`; unlock once with the
finger and once with the account password. Fingerprint is for hyprlock and
sudo, not greetd.

> **Result:** [ ] Pass  [ ] Fail
>
> **Notes:**

## 5. NVIDIA and media

```bash
nvidia-smi
modinfo -F signer nvidia
podman run --rm --device nvidia.com/gpu=all nvcr.io/nvidia/cuda:13.2-devel-fedora41 nvidia-smi
distrobox enter udx-toolbox -- nvidia-smi
switcherooctl list
```

Expected: `nvidia-smi` lists the RTX 500 Ada on driver 620.70.x; `modinfo`
prints the `ublue kernel` signer; the CUDA container reaches the GPU through
the CDI spec refreshed by `nvidia-cdi-refresh`; the NVIDIA-enabled toolbox
also reaches it; and switcheroo lists the Intel and NVIDIA GPUs.

```bash
if command -v glxinfo >/dev/null; then
  __NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia glxinfo -B
else
  nvtop
fi
ffmpeg -f lavfi -i testsrc=duration=2:size=1280x720:rate=30 -c:v h264_nvenc -f null -
obs
v4l2-ctl --list-devices
```

Expected: PRIME offload reports NVIDIA (or `nvtop` shows the offloaded
process); the short NVENC encode succeeds; and OBS can start its virtual
camera on `/dev/video10`.

> **Result:** [ ] Pass  [ ] Fail
>
> **Notes:**

## 6. Windows Work VM

```bash
cd ~/dotfiles
python3 -m unittest discover -s tests -p 'test_windows_work*.py' -v
windows-work
virsh -c qemu:///system dumpxml windows-work | grep -E 'vcpu|vcpupin|filesystem|hostdev'
```

Expected: all Windows Work tests pass; the existing VM starts without being
recreated; its XML retains six vCPUs pinned to the P-cores, three VirtioFS
shares, and the USB camera hostdev. In Windows, verify `Z:` (read-only
`~/dev`), `Y:` (read/write `~/dev/Downloads`), `X:` (the Hollands Kroon repo),
the camera, and `windows-work-audio`.

> **Result:** [ ] Pass  [ ] Fail
>
> **Notes:**

## 7. Dock, bot, idle, and workstation services

```bash
boltctl list
systemctl --user status pai-pulse-watchdog.timer pai-pulse.service --no-pager
flatpak list | wc -l
docker run --rm hello-world
distrobox list
tailscale status
```

Expected: the TBU405Pro dock is authorised, external displays and dock network
work, `pai-pulse-watchdog.timer` and `pai-pulse.service` are enabled and
active, Flatpak count matches the saved count, Docker succeeds, the existing
distroboxes remain listed, and Tailscale is online.

Exercise the real idle chain: let the session idle until it locks, wait for
suspend, resume, and unlock with fingerprint and password. Confirm the niri
session, dock, and Telegram poller recover.

> **Result:** [ ] Pass  [ ] Fail
>
> **Notes:**

## 8. Greeter recovery and known follow-up

If the login screen stops responding to Enter, switch to a TTY and restart
only greetd:

```bash
# Press Ctrl+Alt+F3, log in, then:
sudo systemctl restart greetd
journalctl -b -u greetd --no-pager
```

Expected: the greeter returns and the journal captures the failure. Fedora's
Quickshell build lacks two upstream greetd fixes; a rare loss of sync with
this symptom is the known follow-up. Keep Fedora's package unless it happens.

> **Result:** [ ] Pass  [ ] Fail
>
> **Notes:**

## 9. Rollback and promotion

Use these paths back to Bluefin in this order.

1. While Bluefin is still the previous deployment—no update has been applied
   since the switch—rollback returns to it:

   ```bash
   sudo rpm-ostree rollback
   systemctl reboot
   ```

   Expected: `bluefin-udx-nvidia:stable` boots. Once a Vitta update has
   replaced the previous deployment, this instead returns to an older Vitta.
2. The pinned Bluefin GRUB entry works after later Vitta updates. Immediately
   after the firmware logo, hold Shift or press Esc repeatedly to show the
   hidden GRUB menu. Select the pinned `bluefin-udx-nvidia:stable` entry. It
   stays available until it is unpinned.
3. A signed rebase always works:

   ```bash
   sudo rpm-ostree rebase ostree-image-signed:docker://ghcr.io/dpietersz/bluefin-udx-nvidia:stable
   systemctl reboot
   ```

   Expected: the staged Bluefin deployment boots after the reboot.

Each deployment keeps the `/etc` it last ran with. Bluefin has no
`/etc/pam.d/greetd`; passwords, Wi-Fi settings, and libvirt XML changed on
Vitta are not visible after returning through GRUB or rollback. After logging
in to Bluefin, restore its user configuration:

```bash
rpm-ostree status
chezmoi init && chezmoi apply
```

Expected: `rpm-ostree status` shows Bluefin as booted. After `chezmoi init`,
`expectedImageFamily` is `bluefin-udx-nvidia` and `isVitta` is `false`.

After acceptance, remove the fallback pin. Find its current index with
`rpm-ostree status`; do not assume it is still `1`.

```bash
sudo ostree admin pin --unpin <index>
```

Nightly CI moves `:testing`, and automatic updates stage those builds. If the
timer was left enabled, record the booted deployment's `Digest:` line after
every update. The workflow accepts `testing`, a `YYYYMMDD` tag, a
seven-character SHA tag, or `sha256:<64 hex>`; promote the recorded digest,
never `testing`:

```bash
cd ~/dev/Projects/bluefin-udx
gh workflow run promote-vitta.yml -f image=vitta-nvidia -f source=sha256:<recorded-digest> -f confirm=promote
sudo rpm-ostree rebase ostree-image-signed:docker://ghcr.io/dpietersz/vitta-nvidia:stable
systemctl reboot
```

Expected: promotion verifies cosign, advances only `vitta-nvidia:stable`, and
the final rebase stages and boots that signed stable deployment.

> **Result:** [ ] Pass  [ ] Fail
>
> **Notes:**
