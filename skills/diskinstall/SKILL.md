---
name: diskinstall
description: Install or dual-boot Debian onto a Windows machine with NO USB stick, driven over ssh - shrink Windows, stage the Debian installer on its own small partition, one-shot boot into it - and then set up KDE Plasma on it remotely. Use when the user says /diskinstall, "dual boot this", "put linux on that PC", "install debian on the tablet", "I don't have a usb stick", "set up plasma over ssh", "reboot into windows", "boot windows by default", "grub text is tiny", "grub background", "remote desktop to plasma", or when a task needs to change a Plasma/KWin desktop from a shell. Also use before saying an install needs someone to walk over with a stick.
---
<!-- needs: a UEFI Windows 10/11 machine with OpenSSH Server enabled (admin), BitLocker off, ~50 GB shrinkable on C:, and a person at its screen during the installer itself. -->
<!-- a Linux desktop to build the payload (grub-efi-amd64-bin, cpio, qemu-system-x86 + ovmf for the dry run). Tested on a Dell Latitude 7350 Detachable, Debian 13 (trixie). -->

# Disk-staged Linux install + remote Plasma setup

Proven September 2026 on a Dell Latitude 7350 Detachable (2-in-1 tablet, NVMe, Wi-Fi only).
Scripts next to this file, in order: `prep1.ps1` → `shrink.ps1` → `mkpart.ps1` → copy the payload
→ `bcdentry.ps1` → one-shot reboot. Then on Linux: `grub-bigfont.sh`, `reboot-to-windows-setup.sh`,
and later on Windows `windows-cleanup.ps1`. **Every `.ps1` starts with an `EDIT ME` block of guard
values (disk number, model substring, partition numbers, expected sizes). Edit the guards for your
machine; never delete them.** The model defaults to `CHANGE-ME`, so an unedited script refuses.

## The one constraint that shapes everything

**Once the machine leaves Windows, ssh is gone.** The installer is blind from here. So: a human
drives the installer, everything before and after is done over ssh, and every boot change is a
**one-shot** (UEFI BootNext / `bcdedit /set {fwbootmgr} bootsequence`) so a failure falls back to
Windows instead of stranding the box.

## Windows side (all staged `.ps1` files, never inline, read back every value)

Copy each script over with `scp` and run it with `powershell -File`. Nested quoting through ssh →
cmd → PowerShell mangles anything non-trivial.

0. Snapshot the partition table first:
   `Get-Partition -DiskNumber 0 | Export-Clixml C:\Users\Public\partition-snapshot.xml`.
1. `prep1.ps1`: guard the disk by bus + model, BitLocker off, `Repair-Volume -Scan`, `bcdedit /export`,
   and `powercfg /h off` + `HiberbootEnabled=0`. Fast Startup leaves NTFS hibernated, which is
   mandatory to turn off for dual boot.
2. `shrink.ps1`: `Resize-Partition` to a target ≥ SizeMin + 3 GiB; reads back the exact byte size
   and the gap. **`Get-PartitionSupportedSize` is the real ceiling:** 89.7 GB free gave only
   57.7 GB shrinkable.
3. `mkpart.ps1`: 1 GiB FAT32 at the END of the gap, type **Basic Data** (`ebd0a0a2…`), not ESP (a
   second ESP confuses the installer's partitioner). Mount it to a **folder** (`C:\debinst-mnt`).
   **Never give it a drive letter:** a 2-second `S:` mount popped "S: is unavailable" on the
   user's screen mid-session.
4. scp `linux`, `initrd.gz`, `firmware.cpio.gz`, `preseed.cpio.gz` into `debinst\` and
   `grubx64.efi` into `EFI\debinst\`, then **re-hash on the target** (a sha256 file with paths
   relative to the mount; a wrong path prefix reads as MISMATCH).
5. `bcdentry.ps1`: `bcdedit /copy {bootmgr}`, `device partition=\Device\HarddiskVolumeN` (found via
   `QueryDosDevice`), `path \EFI\debinst\grubx64.efi`, append to `{fwbootmgr}` displayorder.
6. Go gate, in the same turn as the reboot: hashes match, no Windows Update/CBS reboot pending,
   keyboard attached, on AC power (`BatteryStatus=2`), ask about unsaved work →
   `bcdedit /set {fwbootmgr} bootsequence {guid}` → read back → `shutdown /r /t 10`.

The ESP had 34 MB free, so the payload cannot go there. Don't touch `\EFI\Boot\BootX64.efi`
(the firmware's fallback loader).

PowerShell trap: never name a helper `Rd`/`Gc`/`Sl`…: built-in aliases win over your function
(`Rd` = Remove-Item gave 30 "cannot find path" errors). Use Verb-Noun names.

## Payload (build on the desktop)

- trixie **netboot** `linux` + `initrd.gz` (check SHA256SUMS) + cdimage
  `firmware/trixie/current/firmware.cpio.gz` (SHA512SUMS; a `/firmware` tree of .debs, NOT
  `/lib/firmware`) + the preseed as `echo preseed.cfg | cpio -H newc -o | gzip > preseed.cpio.gz`.
  GRUB stacks them: `initrd /debinst/initrd.gz /debinst/firmware.cpio.gz /debinst/preseed.cpio.gz`.
- `grub-mkstandalone -O x86_64-efi` with `grub-installer.cfg` embedded; it finds its partition with
  `search --file --set=root /debinst/linux`.
- `preseed.cfg`: **non-secret answers only**. No partman, no passwords, no Wi-Fi key. Its late
  command drops your public key and a TEMPORARY `/etc/sudoers.d/90-setup` NOPASSWD rule so the
  rest can be done over ssh. Remove that rule at the end.
- **Test on a fake first:** a GPT + FAT image under `qemu-system-x86_64 -enable-kvm -bios OVMF`,
  with a serial-console GRUB variant. GRUB → kernel → installer → preseed took 5 minutes to prove
  and found nothing, which is the point.
- **QEMU has a wired NIC; a tablet may be Wi-Fi only.** Check `zcat initrd.gz | cpio -t` for
  iwlwifi/iwlmvm/cfg80211/mac80211/wpa_supplicant before the reboot.

## Installer traps (the user is at the screen; you talk them through)

- **The installer offered NO Wi-Fi screen even though `wlp…` existed** and firmware had loaded;
  it looked like it wanted a cable. Escapes: USB tethering from a phone (fastest), or manual
  `wpa_supplicant` + `udhcpc` on Ctrl+Alt+F2. The installed system's NetworkManager is fine.
- Partitioning: **"Guided - use the largest continuous free space"**; check the format list names
  only the new ext4 + swap. Answer No to "force GRUB to removable media path".
- The partitioner made its **own ~1 GB ESP** and renumbered the GPT. The freed staging GiB is NOT
  adjacent to root.
- A black screen after the firmware logo is normal: GRUB loads ~550 MB silently, then the kernel
  unpacks it.

## After install (over ssh)

- **Remove staging from Linux:** `sfdisk -d` backup, **list it** (count + the partuuid you are
  deleting), gate on label/fstype/size/partuuid/unmounted, `sfdisk --delete`, then diff the on-disk
  table against the backup minus that line (`partx -d` to refresh the kernel).
  `efibootmgr -b NNNN -B` the one-shot entry.
- **Put Debian's bootloader on the WINDOWS ESP, never on its own ESP after a deleted partition.**
  Deleting the staging partition left an empty GPT slot, so Linux numbered the Debian ESP 6 and
  Windows numbered it 5. Windows rewrites every firmware entry with ITS number (`HD(5,...)`), on a
  bcdedit call AND on a plain Windows boot, and the firmware then says "No bootable devices" and
  falls through to Windows. Fix: copy `\EFI\debian` to the Windows ESP (p1), point `/boot/efi` at
  p1's UUID in fstab, firmware entry `HD(1,...)`. Check with `efibootmgr -v`: the `HD(n)` must
  equal `lsblk -o PARTN`. On the Dell this looked like a firmware "recovery" feature hijacking the
  boot; it was this numbering bug.
- **GRUB text is unreadable on a high-DPI panel** (2880x1920 here): `grub-bigfont.sh`. **Read
  `/boot/grub/grub.cfg` with sudo**: it is 0600, and a plain grep reads "empty".
- **`grub-reboot` is a no-op with `GRUB_DEFAULT=0`.** Reboot-to-Windows = `efibootmgr -n <nnnn>` +
  `systemctl reboot` in a root-owned `/usr/local/sbin` script, a sudoers rule for that exact path
  only, and a launcher wrapped in `kdialog --yesno`: `reboot-to-windows-setup.sh`.
- **Default to Windows by menuentry ID, never an index:** `GRUB_DEFAULT=osprober-efi-<ESP-UUID>`
  (read the id from `sudo grep -n "^menuentry" /boot/grub/grub.cfg`), so a new kernel can't shift
  it. Prove it by Windows' `LastBootUpTime` changing and ssh answering, not by grepping the cfg.
- **GRUB background:** `GRUB_BACKGROUND=/boot/grub/<png>` (Debian's `05_debian_theme` honours it;
  the image must live where GRUB can read it, so apply it from Debian). Use the panel's native
  resolution, darkened behind the menu box: large white text over a busy image is unreadable.
  Mock the menu text onto the image before installing; gate `update-grub` on a readback of
  background + default + font.
- **Windows cleanup trip:** `windows-cleanup.ps1`, whose **first action arms the one-shot back to
  Debian** and refuses to restart if it cannot. Then check `reagentc /info` (Windows numbers WinRE
  4 while Linux says 5: not a fault).

## Plasma 6 Wayland from ssh

```
export XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus \
       WAYLAND_DISPLAY=wayland-0 QT_QPA_PLATFORM=wayland
```
Without them every Qt tool dies on "could not connect to display".
- Panels/widgets/wallpaper: `busctl --user call org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell
  evaluateScript s '<js>'`; read back with the same call and `print()`.
- On-screen keyboard: `kwinrc [Wayland] InputMethod=/usr/share/applications/com.github.maliit.keyboard.desktop`
  **only takes effect after a re-login**; verify `org.kde.kwin.VirtualKeyboard available=true`.
  Login screen: `/etc/sddm.conf.d` `InputMethod=qtvirtualkeyboard` + `qt6-virtualkeyboard-plugin`.
- **`im-config` exports `QT_IM_MODULE=ibus` on Wayland too** (`/etc/profile.d/im-config_wayland.sh`),
  so Qt apps and the LOCK SCREEN talk to ibus and Maliit never appears. Fix: `im-config -n none`,
  re-login; check `systemctl --user show-environment | grep IM_MODULE` is empty.
- Keep titlebars on a keyboardless device (`BorderSize None`, not a borderless theme).
- **Screenshots over ssh do not work:** spectacle exits 0 and logs "KWin screenshot request
  failed". Ask the user to look.
- **It idle-suspends and drops off Wi-Fi** ("No route to host"). Hold it with
  `sudo setsid systemd-inhibit --what=idle:sleep … sleep 7200 &`; the user-level inhibit fails with
  "Interactive authentication required".
- **Ending a broken Plasma session** (`loginctl terminate-session N`) is NOT enough: KWin and
  plasmashell live in the user MANAGER (`user@<uid>.service/session.slice/plasma-*.service`) and keep
  running, and SDDM may not bring the greeter back. Do: `systemctl --user stop
  plasma-workspace.target plasma-workspace-wayland.target plasma-core.target
  graphical-session.target`, then `sudo systemctl restart sddm`, check `pgrep -a sddm-greeter`.
- **Driving other windows = a one-shot KWin script**: `busctl --user call org.kde.KWin /Scripting
  org.kde.kwin.Scripting loadScript ss <file.js> <name>` → `…/Scripting/Script<N> org.kde.kwin.Script
  run` → `unloadScript s <name>`. JS: `workspace.windowList()`, `w.resourceClass` (= Wayland app-id),
  `w.minimized`, `w.frameGeometry = {x,y,width,height}`. `print()` lands in the user journal as
  `js: …`, which is also how to READ window state (screenshots fail).
- Plasma scripting traps: `p.opacity=` is ignored (write `plasmashellrc [PlasmaViews][Panel N]
  panelOpacity`); widget `.index=` is ignored (write the containment's `[General] AppletOrder`);
  both need `systemctl --user restart plasma-plasmashell` (it blinks the screen: say so first).
  `w.remove()` is async: read back after a second. Delete a key with `kwriteconfig6 --key K
  --delete`; `--delete K` prints "cannot mark groups as deleted" and does nothing.
- **Remote desktop onto Plasma Wayland: NoMachine was a dead end here.** Its `compositor` mode calls
  GNOME's Mutter RemoteDesktop API ("Grabber init failed"); `drm` mode gave a blank white screen on
  a newer kernel; `egl` mode stripped `kwin_wayland`'s `cap_sys_nice` and put an `LD_PRELOAD` into
  the systemd user environment, which broke the display after re-login. Input worked in every mode,
  so "I can control it but not see it" = capture, not network. The next candidate is Plasma's own
  **KRdp** via the screencast portal.
- Never `pkill -f <pattern>` inside `ssh host '…'`: it kills the remote `bash -c` carrying the
  pattern, and the rest of the command silently never runs.

## When something "worked earlier"

Diff THEN vs NOW before touching config. `journalctl --list-boots` + `-b N -k | grep "Linux
version"` maps each boot to a kernel; a kernel change was the answer after three rounds of
config changes were not.

## A "freeze" = check pstore first

A hard freeze leaves the journal ending BEFORE the crash. The panic text is in
`sudo ls /var/lib/systemd/pstore/*/*/dmesg.txt` (grep `Kernel panic|RIP|Comm:|Workqueue`). On the
test tablet it was `typec_ucsi` after resume on kernel 6.12, fixed by the trixie-backports kernel.
