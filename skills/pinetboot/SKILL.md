---
name: pinetboot
description: Rewrite or rescue a Raspberry Pi's SD card when there is no card reader - netboot the Pi over the network so its card is unmounted, then dd a fresh image onto it. Use when the user says /pinetboot, "reflash the pi", "reimage the pi", "the pi won't boot", "wipe the sd card", "I can't find the usb adapter", "no card reader", "upgrade dietpi", or when any task needs to write to a Pi's boot medium. Also use before saying a Pi cannot be reimaged or recovered remotely.
---
<!-- needs: a Pi 4-class board (EEPROM bootloader) on the SAME flat LAN as a Linux machine running dnsmasq, nfs-kernel-server, ufw, rsync; root ssh to the Pi. -->
<!-- optional: a way to power-cycle the Pi remotely (PoE switch port, smart plug). Per-host config in ~/.config/pi-netboot/<host>.conf. -->

# Reflash a Pi with no card reader (PXE netboot)

With no USB-to-microSD reader and no card slot on the desktop (`/sys/class/mmc_host` empty),
the only way to rewrite a Pi's card is to boot that Pi from somewhere else so `/dev/mmcblk0`
is unmounted. Proven on a Pi 4 running DietPi, September 2026.

Scripts next to this file: `pi_netboot.sh` (the rig) and `flasher.sh` (the gated write).

## Ruled out: do not spend time re-deriving

- **`rpiboot` / mass-storage-gadget (Pi as its own reader): impossible on a 4B.** Needs a special
  SD image to bootstrap (chicken-and-egg) *and* permanently burns OTP. Source: raspberrypi/usbboot.
- **Network Install** (bootloader fetches Imager) works on EEPROM ≥ 2022-02 but needs **HDMI +
  keyboard**. Offer it only if the user accepts non-headless.
- **In-place overwrite of the running card**: no reader means a half-written card is a brick.

## Gates: check BOTH before promising anything

```
ssh <pi> 'grep -i nfs /proc/filesystems; lsmod | grep -c nfs; ls /boot/initramfs* 2>/dev/null'
```
- `nfs`/`nfs4` listed **with 0 modules loaded** = NFS is built in, so `root=/dev/nfs` works.
- **No initramfs** = nothing else to configure. Bullseye/DietPi Pi kernels pass; a *fresh*
  Bookworm/Trixie root does **not** (it uses an initramfs that needs NFS support added).
  So **netboot a trimmed clone of the Pi's OWN running system**, never a fresh distro root.
  That single choice removes the hardest part of this job.
- EEPROM ≥ 2020-09 (`vcgencmd bootloader_version`). DietPi ships neither `vcgencmd` nor
  `rpi-eeprom`: `apt install rpi-eeprom` first, **then read the EEPROM section below**.

## Procedure

1. **Back up, and LIST the backup.** Per-container `docker inspect <c> --format '{{json .Mounts}}'`:
   a "volume" in a tarball is often an empty mountpoint while the real data is a *bind* mount.
   Dump databases, don't tar them live. A tar of one Pi once hit a 13.5 GB log file, stopped at
   123 MB, and contained none of the compose files it was taken for. `tar tzf` it.
2. Write `~/.config/pi-netboot/<host>.conf` (format in the header of `pi_netboot.sh`). The TFTP
   directory name is **the last 8 hex of the serial** in `/proc/cpuinfo`.
3. **`pi_netboot.sh <host> clone`**: rsyncs the running rootfs, blanks the SD lines out of the
   clone's `/etc/fstab` (gated on a count of 0), masks the services in `MASK_UNITS`, neuters a
   static eth0, copies `/boot` to the TFTP dir and writes a `cmdline.txt` with `root=/dev/nfs`.
4. **`BOOT_ORDER=0xf412`** (net, then SD, then USB, then restart) for the flashing window: a
   failed netboot falls back to the intact card, so there is no brick path. Nibbles: `1`=SD
   `2`=net `4`=USB `f`=restart, read right to left.
5. `pi_netboot.sh <host> start`, then power-cycle (`cycle` if you configured power commands),
   then **verify before touching the card**: `findmnt -n -o FSTYPE /` is `nfs`, and
   `findmnt -rn | grep -c mmcblk0` is `0`.
6. **Flash, gated on values not prints:**
   ```
   scp flasher.sh root@<netbooted-pi>:/tmp/
   xzcat img.xz | ssh root@<netbooted-pi> 'bash /tmp/flasher.sh'
   ```
   The script re-checks root=nfs and mounts=0 and exits non-zero otherwise.
7. Headless first boot, then `BOOT_ORDER=0xf241` (SD first, net last) **from the new system**.
8. `pi_netboot.sh <host> stop`, and diff ufw against the snapshot you took.

## Traps that cost time

- **The bootloader takes a DIFFERENT DHCP lease than the OS** (`.40` while the OS held `.12`).
  Never scope an export or a firewall rule to the address the OS normally has. The script scopes
  to the subnet.
- **`ping` proves nothing.** `ip=dhcp` means the *kernel* answers ICMP with no userspace. Prove
  progress with an ESTABLISHED connection on `:2049`, not liveness.
- **Heredoc + pipe both claiming ssh's stdin**: `xzcat f | ssh h 'bash -s' <<'EOF'` silently
  writes *script text* to the disk. Stage the script with `scp`, pipe data only.
- **`| tail` swallows the exit code**, and `sudo rsync -e ssh` runs **ssh as root**, which has no
  `~/.ssh/config` aliases. Pass `-i` and an IP; read `${PIPESTATUS[*]}`.
- **A fresh Pi OS image has no passwordless sudo.** `userconf` *renames* `pi` (uid 1000) and
  moves its home, and Trixie ships no `010_pi-nopasswd`: the new user lands in the `sudo` group
  unable to escalate. Write `/etc/sudoers.d/` **while the card is mounted**, `visudo -cf` it.
- **`custom.toml` was not supported** by the September 2026 Trixie Lite image. It reads
  `userconf.txt` plus an empty `ssh` file. Verify in the image before writing.
- **Don't pre-seed `/home/<newuser>`**: it collides with `usermod -m -d`. Put keys in
  `/etc/ssh/authorized_keys/<user>` (root:root 644) with an `AuthorizedKeysFile` drop-in.
- **Copy private keys and you inherit loose modes**: `chmod 600` them after any tar/rsync.
- **polkit refuses `systemctl reboot` over ssh** when the user can't sudo.
- **dnsmasq won't reopen its own existing log**: delete it before restarting.
- **Blanking the SD lines out of the clone's `/etc/fstab` is easy to get silently wrong.** Two
  separate bugs did it: `|` as the sed delimiter collides with the alternation
  `(mmcblk0|PARTUUID)` and sed dies; and `^([^#].*(mmcblk0|PARTUUID)...` can never match a line
  that *starts* with `PARTUUID`, because `[^#]` consumes its leading `P`. Select by **address**
  (`/mmcblk0|PARTUUID/ { /^[[:space:]]*#/! s,^,# ,}`) and then **gate on a count of 0**.
- **A STATIC-IP box will hang on netboot unless you neuter the clone's network config.** The
  kernel brings eth0 up with `ip=dhcp` and mounts the NFS root over **that** address; if the
  clone then runs `ifup` and reconfigures eth0 to its static IP, the NFS root's TCP connection
  dies mid-boot and the box hangs, which looks exactly like "netboot doesn't work". The script
  sets the clone's `iface eth0 inet static` to `manual` and comments its address lines.
  **Gate that edit on the eth0 STANZA, not the whole file**: a file-wide grep also counts other
  interfaces' address lines and reports a false failure.
  **Consequence: once netbooted the Pi is on a DHCP address, NOT its usual one.** Find it in
  your router's lease list.
- **Make the rescue root INERT.** Mask anything that writes state in the clone (`MASK_UNITS`):
  docker, containerd, and bare-metal services such as a DNS server or a VPN. Otherwise they start
  and write into the NFS export believing they are live.
- **`rsync -x` only skips other FILESYSTEMS.** A big data directory that is a plain dir on `/`
  is NOT skipped; exclude it by name or the rescue root is enormous (one was 70 GB instead of 9).
- **A process check by name matches your own shell.** `pgrep -f`/`pkill -f` on a pattern you
  typed will match the command running it. Use a pidfile, and `[ -d /proc/$pid ]`, **not**
  `kill -0`, which returns EPERM against a root-owned process and reads as "down".

## Before ANY reboot of a Pi: gate on these, they are cheap

**1. A staged EEPROM flash. This is the one that bites.** Installing `rpi-eeprom` (which the
gates above tell you to do) **silently stages a firmware flash** via its postinst:
`/boot/{recovery.bin,pieeprom.upd,pieeprom.sig}`. The **ROM loads `recovery.bin` off the card at
power-on, before any OS runs**, so `systemctl mask rpi-eeprom-update.service` does **not** stop
it, and neither does `apt-mark hold` once the files exist. Caught one reboot away from flashing a
2020 bootloader to 2026 on a box with no remote power cycle.
```
N=$(ls /boot/recovery.bin /boot/pieeprom.upd /boot/pieeprom.sig /boot/vl805.* 2>/dev/null | wc -l)
[ "$N" -eq 0 ] || { echo "REFUSING: $N staged EEPROM file(s)"; exit 1; }   # cancel: rpi-eeprom-update -r
```
Re-check **after** `dietpi-update` or anything that may call `rpi-eeprom-update -a`.

**The one legitimate exception is a flash YOU just staged**, and setting `BOOT_ORDER` is exactly
that, see below. When staged files are expected, don't just count them: read which image is
pending (`rpi-eeprom-update -l`, or the `.upd` filename) and confirm it is the version you meant
to install before rebooting into it.

**Setting `BOOT_ORDER` IS a firmware update; there is no config-only path.**
`rpi-eeprom-config --apply` calls `get_latest_eeprom()` → `rpi-eeprom-update -l`, applies your
config to **the newest image shipped by the `rpi-eeprom` package**, and stages *that*. It does
**not** edit the bootloader currently in the chip (verified by reading `/usr/bin/rpi-eeprom-config`;
the package shipped only one image, the same file in every channel). So on an old Pi, "keep the
current EEPROM" and "enable netboot" are **incompatible** via the supported path. Either accept
the firmware update deliberately, as its own reboot, with a power cycle available, before
anything else depends on it, or pass an explicit older `pieeprom.bin`, which you must first
obtain. Taking the update is usually right: newer bootloaders netboot better.

**2. Configs edited after their daemon started have never been parsed.** The reboot is the first
parse. Compare each file's mtime to the process/container start time, and validate the ones that
are newer: `python3 -m json.tool /etc/docker/daemon.json` (a typo takes out *every* container at
once), `unbound-checkconf`, and for Home Assistant
`docker exec homeassistant python -m homeassistant --script check_config -c /config` (rc=0).
One box had a `scripts.yaml` two months newer than the running Home Assistant.

**3. `enabled`, not just `active`**: `systemctl is-enabled` each service that must return.
**4. Containers**: `unless-stopped` comes back on boot, **but NOT one you stopped by hand.**
Stop a database container gracefully (`docker stop -t 90`; Home Assistant took 20 s, and docker's
default grace on shutdown is 10 s, which can tear the recorder DB), then `docker start` it after.
**5. fstab** targets all mounted, and `tune2fs -l` max-mount-count `-1` so there is no fsck stall.
**6. Snapshot first**: `/var/log` is tmpfs on DietPi, so `dmesg`, `ss -tlnup`, `docker ps` and
`wg show` are **gone** after the reboot. Keep them; they are the diff target, not just forensics.

**Verify it actually rebooted by VALUE:** record the epoch before, then require the new
`uptime -s` epoch to be greater. A box that answers ssh but never rebooted passes a liveness
check and fails this one. On DietPi `systemctl reboot` prints `Failed to connect to bus` (no
dbus) **and reboots anyway**: that message is not a failure.

## Power cycling

A PoE-powered Pi can be cycled from the switch (port off, 8 s, on: a Pi that does not lose power
long enough never resets). **Confirm the port from the switch's MAC address table, never from a
note.** A note once had the wrong port for a day, and `show power inline` alone would not have
caught it, because the wrong port also read `Searching`. The check that settles it is the MAC
table lookup for the device's MAC, then the port's PoE state, then the MAC table for that port to
be sure it carries only that one device and not a downstream switch.

## The rig only works on a FLAT LAN: check the VLAN before you start

`pi_netboot.sh` hands out **proxy DHCP** (udp 67 + 4011). Proxy DHCP is **broadcast**: it does
not cross a VLAN boundary without a relay, so a Pi in another VLAN never sees the offer and the
bootloader just times out, looking like a dead NIC. Every ufw rule the script opens (tftp 69,
rpcbind 111, nfs 2049, mountd 20048) is also scoped to `LAN_CIDR`.

If the Pi lives in another VLAN, the recovery is **switch first**: put its port into the rig's
VLAN, netboot and recover as normal, then move the port back. Check which VLAN the port is in
**before** concluding the rig is broken.
