# Vitta NVIDIA P14s acceptance

Run this live on the ThinkPad P14s Gen 5 with the owner. The switch is the
owner's decision; nothing in this document runs by itself. Record a result for
every numbered check. At any point, boot the previous GRUB deployment or run
`sudo rpm-ostree rollback && systemctl reboot` to return to
`bluefin-udx-nvidia:stable`.

## Before the switch

The target is the signed, anonymously pullable testing image published on
2026-11-12:

```bash
cd ~/dev/Projects/bluefin-udx
skopeo inspect docker://ghcr.io/dpietersz/vitta-nvidia:testing
cosign verify --key cosign.pub ghcr.io/dpietersz/vitta-nvidia:testing
```

Expected: the digest is
`sha256:4657751d80ebfcb55d4a97a725736f4d37508a88a45db987051467df21fec85c`
and cosign verification succeeds.

The dotfiles `vitta-nvidia` branch, including
`run_onchange_after_16a-keyring-passwordless-greetd`, must be merged before
switching. Save the current deployment facts and the passwordless keyring. Do
not copy the keyring after the first greetd login.

```bash
mkdir -p ~/vitta-nvidia-acceptance
rpm-ostree status -v | tee ~/vitta-nvidia-acceptance/rpm-ostree-status.before
rpm-ostree kargs | tee ~/vitta-nvidia-acceptance/rpm-ostree-kargs.before
virsh -c qemu:///system dumpxml windows-work > ~/vitta-nvidia-acceptance/windows-work.before.xml
authselect current | tee ~/vitta-nvidia-acceptance/authselect.before
fprintd-list "$USER" | tee ~/vitta-nvidia-acceptance/fprintd.before
flatpak list | wc -l | tee ~/vitta-nvidia-acceptance/flatpak-count.before
cp -p ~/.local/share/keyrings/login.keyring ~/vitta-nvidia-acceptance/login.keyring.before
sha256sum ~/.local/share/keyrings/login.keyring | tee ~/vitta-nvidia-acceptance/login.keyring.before.sha256
ls -l ~/.local/share/keyrings/login.keyring ~/vitta-nvidia-acceptance/login.keyring.before
```

Expected: the current deployment is `bluefin-udx-nvidia:stable`; authselect
includes `with-fingerprint`; the enrolled Synaptics finger is listed; and the
keyring copy has the same size and timestamp as `login.keyring`. Today,
`rpm-ostree status -v` prints:

```text
InactiveRequests: fuse-libs
LocalPackages: equibop-3.3.2-1.x86_64
```

Bluefin ships `fuse-libs`, so its request is inactive; Vitta does not, so the
same request must become a layer. The login keyring must have an empty
password: open it in Seahorse before switching if that is uncertain, and set
its password to empty. Record the Flatpak count; Flatpak state is in `/var` and
must survive the rebase.

## 1. Stage the signed rebase

```bash
sudo rpm-ostree rebase ostree-image-signed:docker://ghcr.io/dpietersz/vitta-nvidia:testing
rpm-ostree status
rpm-ostree status -v
```

First confirm that the first deployment listed by `rpm-ostree status` is the
staged `vitta-nvidia:testing` deployment. Index `0` means that first-listed
deployment. In its `rpm-ostree status -v` entry, expect both:

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

At the greeter, confirm the bands and fields are edge to edge on the internal
panel. Then repeat with the Thunderbolt dock connected and the lid closed; it
must use one display rather than span a seam. Leave the greeter idle for five
minutes; it must blank.

```bash
/usr/libexec/vitta/vitta-greeter-gpu
journalctl -b -u greetd --no-pager
cat /sys/bus/pci/devices/0000:01:00.0/power/runtime_status
```

Expected: the helper prints `/dev/dri/card0`; the greetd journal has no error;
and the NVIDIA device is `suspended` while idle.

After this first successful boot, record the `Digest:` line for the booted
(`●`) deployment. It is the tested source for promotion.

```bash
rpm-ostree status | tee ~/vitta-nvidia-acceptance/rpm-ostree-status.first-vitta-boot
```

Expected: the saved status has the booted Vitta deployment and its
`Digest: sha256:…` line.

> **Result:** [ ] Pass  [ ] Fail
>
> **Notes:**

## 3. Login, lock, sudo, and keyring

Follow these steps in order. Do not restore the keyring before step 3 verifies
the guard.

1. Before the switch, while still on Bluefin, copy
   `~/.local/share/keyrings/login.keyring` to the named backup path
   `~/vitta-nvidia-acceptance/login.keyring.before` and record `sha256sum`.
   The capture block above does both.
2. At the Vitta greeter, enter one wrong password. It must fail in about 2–3
   seconds, with no fingerprint prompt or fingerprint timeout. Then log in
   with the account password.
3. In this first session, deploy and verify the guard before returning to
   greetd:

   ```bash
   cd ~/dotfiles
   git pull --ff-only
   chezmoi init
   chezmoi apply
   chezmoi data | grep -E 'isVitta|isMyImage|expectedImageFamily'
   grep -n pam_gnome_keyring /etc/pam.d/greetd
   ```

   Expected: Chezmoi reports `isVitta = true`, `isMyImage = true`, and
   `expectedImageFamily = vitta-nvidia`. `grep` shows three
   `pam_gnome_keyring` lines, all commented with `# [keyring-pam disabled]`.
4. Compare the current keyring with the recorded hash:

   ```bash
   sha256sum ~/.local/share/keyrings/login.keyring
   cat ~/vitta-nvidia-acceptance/login.keyring.before.sha256
   ```

   Expected: the two hashes match. The keyring was not touched; continue with
   check 4.
5. If the hashes differ, the first login re-encrypted the keyring. Log out,
   press `Ctrl+Alt+F3`, and log in on the text console. Keep the re-encrypted
   file, stop any of your keyring daemons, then restore the backup:

   ```bash
   mv ~/.local/share/keyrings/login.keyring ~/.local/share/keyrings/login.keyring.reencrypted
   pkill -u "$USER" gnome-keyring-daemon
   cp -p ~/vitta-nvidia-acceptance/login.keyring.before ~/.local/share/keyrings/login.keyring
   exit
   ```

   Return to greetd with `Ctrl+Alt+F1`; its `/etc/greetd/config.toml` sets
   `vt = 1`. Log in again. The verified guard is active, so this login cannot
   re-encrypt the keyring. Re-check the hash from step 4.

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

Rollback ends the trial and returns to the maintained fallback:

```bash
sudo rpm-ostree rollback
systemctl reboot
# After logging in to bluefin-udx-nvidia:
rpm-ostree status
chezmoi init && chezmoi apply
```

Expected: the previous `bluefin-udx-nvidia:stable` deployment boots and
`rpm-ostree status` shows it as booted. After `chezmoi init`,
`expectedImageFamily` is `bluefin-udx-nvidia` and `isVitta` is `false`. The
Vitta `/etc/pam.d/greetd` keyring guard stays behind as an unused file on
Bluefin; it is harmless. Selecting the previous deployment in GRUB is
equivalent when the current boot cannot reach a terminal.

Nightly CI moves `:testing`. An `rpm-ostree upgrade` during the acceptance week
changes what is being tested, so record the booted deployment's `Digest:` line
again after every upgrade. The workflow accepts `testing`, a `YYYYMMDD` tag, a
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
