#!/bin/bash
# Bring a Raspberry Pi's PXE netboot rig up or down, so the Pi's SD card can be rewritten
# with no card reader.
#
# WHY THIS EXISTS: with no USB-to-microSD reader, a Pi's card can only be rewritten from a
# system that is not running off it. Netbooting the Pi leaves /dev/mmcblk0 completely
# unmounted, which is the only no-reader recovery path. Procedure + every trap: SKILL.md.
#
#   pi_netboot.sh <host> start     # serve TFTP + NFS root for that host, open ufw
#   pi_netboot.sh <host> stop      # tear that host down; dnsmasq stops when no host is left up
#   pi_netboot.sh <host> cycle     # power-cycle the Pi with your POWER_OFF_CMD / POWER_ON_CMD
#   pi_netboot.sh <host> clone     # (re)build the NFS root from the LIVE Pi
#   pi_netboot.sh <host> status
#
# Per-host config: ~/.config/pi-netboot/<host>.conf (override the dir with PI_NETBOOT_CONF_DIR),
# a bash fragment that sets:
#   SERIAL=1234abcd                 # last 8 hex of the Pi's /proc/cpuinfo Serial (TFTP dir name)
#   SSH_HOST=mypi                   # how to reach the LIVE Pi (alias or IP) for `clone`
#   NFS_DIR=/data/nfs/mypi          # where the cloned root lives on this machine
#   CLONE_EXCLUDES=(--exclude=/var/lib/docker --exclude='/var/log/*')
#   MASK_UNITS=(docker containerd)  # services that must NOT start in the rescue root
#   POWER_OFF_CMD='...'             # optional, for `cycle` (e.g. a PoE switch or smart plug command)
#   POWER_ON_CMD='...'
#
# Machine-wide settings (environment), detected when unset:
#   LAN_IF      interface the Pi is on        (default: interface of the default route)
#   LAN_CIDR    the flat LAN, e.g. 192.0.2.0/24 (default: that interface's subnet)
#   NFS_SERVER  this machine's LAN address    (default: that interface's address)
#   SUDO        how to run root commands      (default: sudo; use "sudo -A" with an askpass helper)
#   SSH_KEY     key root's rsync uses         (default: ~/.ssh/id_ed25519)
#
# TESTING CAVEAT: with BOOT_ORDER SD-first the Pi ignores the network entirely, so `start`
# cannot be proven end to end on a healthy box. To rehearse, set BOOT_ORDER=0xf412 (net first,
# SD second - a failed netboot still falls back to the intact card, so there is no brick path),
# cycle, confirm `findmnt -n -o FSTYPE /` says nfs, then put it back to 0xf241.
# NOTE: on an old EEPROM, changing BOOT_ORDER also FLASHES the bootloader - see SKILL.md.
set -u

SUDO=${SUDO:-sudo}
SSH_KEY=${SSH_KEY:-$HOME/.ssh/id_ed25519}
CONF_DIR=${PI_NETBOOT_CONF_DIR:-$HOME/.config/pi-netboot}

host_config() {
    local f="$CONF_DIR/$1.conf"
    [ -f "$f" ] || die "no config for '$1' - create $f (see the header of this script)"
    SERIAL=""; SSH_HOST=""; NFS_DIR=""; POWER_OFF_CMD=""; POWER_ON_CMD=""
    CLONE_EXCLUDES=(--exclude=/var/lib/docker --exclude='/var/log/*'); MASK_UNITS=(docker containerd)
    # shellcheck source=/dev/null
    . "$f"
    [[ "$SERIAL" =~ ^[0-9a-f]{8}$ ]] || die "$f: SERIAL must be the last 8 lower-hex of the Pi's serial"
    [ -n "$SSH_HOST" ] || die "$f: SSH_HOST is empty"
    [ -n "$NFS_DIR" ] && [ "$NFS_DIR" != / ] || die "$f: NFS_DIR is empty or /"
}

detect_net() {
    LAN_IF=${LAN_IF:-$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')}
    [ -n "$LAN_IF" ] || die "cannot detect LAN_IF; set it"
    local cidr
    cidr=$(ip -o -4 addr show dev "$LAN_IF" 2>/dev/null | awk '{print $4; exit}')
    NFS_SERVER=${NFS_SERVER:-${cidr%/*}}
    [ -n "$NFS_SERVER" ] || die "cannot detect NFS_SERVER; set it"
    if [ -z "${LAN_CIDR:-}" ]; then
        LAN_CIDR=$(ip -o -4 route show dev "$LAN_IF" scope link 2>/dev/null | awk '{print $1; exit}')
    fi
    [ -n "$LAN_CIDR" ] || die "cannot detect LAN_CIDR; set it"
    # proxy DHCP answers on the subnet's broadcast address
    BCAST=$(python3 -c "import ipaddress,sys; print(ipaddress.ip_network(sys.argv[1], strict=False).broadcast_address)" "$LAN_CIDR")
}

TFTP_DIR=${TFTP_DIR:-/data/tftp}
CONF=/tmp/dnsmasq-pi-netboot.conf
LOG=/tmp/dnsmasq-pi-netboot.log
PIDF=/tmp/dnsmasq-pi-netboot.pid
STATE_DIR=/tmp/pi-netboot-active

die() { echo "ERROR: $*" >&2; exit 1; }

# Liveness by PID FILE, never a process-name search: such a pattern also matches the command
# line of whatever shell invoked this script, which reported a false "UP" on 2026-09-20.
# A stale pidfile outlives its process, so check /proc and confirm it is really dnsmasq.
alive() {
  local pid
  [ -f "$PIDF" ] || return 1
  pid=$(cat "$PIDF" 2>/dev/null) || return 1
  [ -n "$pid" ] || return 1
  # NOT kill -0: dnsmasq runs as root, and kill -0 from an unprivileged user against a
  # root-owned process fails with EPERM - it reported "down" while TFTP was serving (09-20).
  [ -d "/proc/$pid" ] || return 1
  tr -d '\000' < "/proc/$pid/cmdline" 2>/dev/null | grep -q dnsmasq
}

active_hosts() { ls "$STATE_DIR" 2>/dev/null; }

write_conf() {
  cat > "$CONF" <<CONF
# port=0: no DNS. Whatever already serves DNS on this LAN keeps doing so.
# proxy : hands out NO addresses. Your router stays the only DHCP server; this adds
#         only the boot-server info a PXE client asks for.
# One dnsmasq serves EVERY host: tftp-root holds a subdirectory per serial.
port=0
interface=$LAN_IF
bind-interfaces
dhcp-range=$BCAST,proxy
pxe-service=0,"Raspberry Pi Boot"
enable-tftp
tftp-root=$TFTP_DIR
log-dhcp
CONF
}

# ---- entry point --------------------------------------------------------------------------
[ $# -ge 1 ] || die "usage: $(basename "$0") <host> {start|stop|cycle|status|clone}"
HOST="$1"; shift
host_config "$HOST"
detect_net
ACTION="${1:-status}"

case "$ACTION" in
start)
  [ -d "$TFTP_DIR/$SERIAL" ] || die "$TFTP_DIR/$SERIAL missing - $HOST's boot files are gone (run: $0 $HOST clone)"
  [ -d "$NFS_DIR/etc" ]      || die "$NFS_DIR looks empty - run: $0 $HOST clone"
  # The clone must NOT try to mount the card it is about to overwrite.
  grep -qE '^[^#]*mmcblk0|^[^#]*PARTUUID' "$NFS_DIR/etc/fstab" 2>/dev/null \
    && die "$NFS_DIR/etc/fstab still mounts the SD card - fix before booting"

  grep -q " $NFS_DIR " /etc/exports 2>/dev/null || \
    echo "$NFS_DIR ${LAN_CIDR}(rw,sync,no_subtree_check,no_root_squash)   # $HOST netboot" \
    | $SUDO tee -a /etc/exports >/dev/null
  # rpc.mountd otherwise binds RANDOM high ports, which is why the first run needed a
  # host-wide allow. Pin it so the firewall holes can stay port-scoped.
  if ! grep -q '^port=20048' /etc/nfs.conf 2>/dev/null; then
    printf '\n[mountd]\nport=20048\n' | $SUDO tee -a /etc/nfs.conf >/dev/null
  fi
  $SUDO systemctl restart nfs-kernel-server || die "nfs-kernel-server would not start"
  $SUDO exportfs -ra

  # Scope to the SUBNET, not to the Pi's usual address: the BOOTLOADER takes its own DHCP
  # lease, which is NOT the address the OS holds (one Pi took .40 while its OS lived on .12).
  for r in "67 proto udp|proxy dhcp" "4011 proto udp|proxy" "69 proto udp|tftp" "111|rpcbind" "2049|nfs" "20048|mountd"; do
    port="${r%%|*}"; what="${r##*|}"
    $SUDO ufw allow from "$LAN_CIDR" to any port ${port} comment "PINETBOOT $what" >/dev/null
  done

  mkdir -p "$STATE_DIR"; touch "$STATE_DIR/$HOST"
  if ! alive; then
    write_conf
    $SUDO rm -f "$LOG"          # dnsmasq will not reopen an existing root-owned log
    $SUDO /usr/sbin/dnsmasq --conf-file="$CONF" --log-facility="$LOG" --pid-file="$PIDF" \
      || die "dnsmasq failed to start"
    sleep 1
    alive || die "dnsmasq did not stay up"
  fi
  echo "netboot rig UP for $HOST (serial $SERIAL, export $NFS_DIR, server $NFS_SERVER on $LAN_IF)."
  echo "Now: $0 $HOST cycle    then: ssh $SSH_HOST 'findmnt -n -o FSTYPE /'   (expect: nfs)"
  ;;

stop)
  rm -f "$STATE_DIR/$HOST"
  $SUDO sed -i "\\#^${NFS_DIR} #d" /etc/exports 2>/dev/null
  $SUDO exportfs -ra 2>/dev/null
  if [ -z "$(active_hosts)" ]; then
    [ -f "$PIDF" ] && $SUDO kill "$($SUDO cat "$PIDF")" 2>/dev/null
    $SUDO exportfs -ua 2>/dev/null
    $SUDO systemctl stop nfs-kernel-server 2>/dev/null
    for n in $($SUDO ufw status numbered | grep -E 'PINETBOOT' | grep -oE '^\[ *[0-9]+' \
               | grep -oE '[0-9]+' | sort -rn); do yes | $SUDO ufw delete "$n" >/dev/null 2>&1; done
    echo "netboot rig DOWN (no hosts left active). ufw rules remaining: $($SUDO ufw status | grep -cE 'PINETBOOT')"
  else
    echo "$HOST stopped; still up for: $(active_hosts | tr '\n' ' ')"
  fi
  echo "NOTE: with BOOT_ORDER SD-first the Pi just falls through to its card."
  ;;

cycle)
  # A Pi that does not see power drop for long enough never resets. 8 s was what worked.
  [ -n "$POWER_OFF_CMD" ] && [ -n "$POWER_ON_CMD" ] || die "set POWER_OFF_CMD and POWER_ON_CMD in $CONF_DIR/$HOST.conf"
  echo "cycling $HOST"
  bash -c "$POWER_OFF_CMD" || die "power off failed"
  echo "power off; waiting 8s for the Pi to drop"
  sleep 8
  bash -c "$POWER_ON_CMD" || die "power on failed"
  echo "powered. Watch for the netbooted Pi on a DHCP address, then: findmnt -n -o FSTYPE /"
  ;;

clone)
  # Clone the Pi's OWN running rootfs - never a fresh distro. A fresh Bookworm/Trixie root boots
  # through an initramfs with no NFS support; the running system has NFS built in and no
  # initramfs, which is the whole reason this method works.
  $SUDO mkdir -p "$NFS_DIR" "$TFTP_DIR/$SERIAL"
  echo "cloning $SSH_HOST rootfs -> $NFS_DIR (excludes: ${CLONE_EXCLUDES[*]})"
  # sudo rsync -e ssh runs SSH AS ROOT, which has no ~/.ssh/config aliases - pass the key and
  # an IP, and read PIPESTATUS rather than letting a pipe swallow the exit code.
  IP=$(getent hosts "$SSH_HOST" 2>/dev/null | awk '{print $1}')
  [ -n "$IP" ] || IP=$(ssh -G "$SSH_HOST" 2>/dev/null | awk '/^hostname /{print $2}')
  [ -n "$IP" ] || die "cannot resolve $SSH_HOST to an IP for the root-side rsync"
  $SUDO rsync -aAXH --numeric-ids -x "${CLONE_EXCLUDES[@]}" \
      -e "ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" \
      "root@$IP:/" "$NFS_DIR/"
  rc=$?
  [ $rc -eq 0 ] || die "rsync exited $rc - clone is incomplete, refusing to leave it usable"

  # Blank the SD entries out of the clone's fstab: it must not mount the card it may overwrite.
  # Two bugs lived here on 2026-09-21, both leaving the card mountable:
  #   1. '|' as the sed delimiter collides with the alternation (mmcblk0|PARTUUID) -> sed dies.
  #   2. '^([^#].*(mmcblk0|PARTUUID)...' can never match a line that STARTS with PARTUUID,
  #      because [^#] eats its leading 'P'.
  # So: select the lines by ADDRESS, skip ones already commented, and prefix them.
  $SUDO sed -i -E '/mmcblk0|PARTUUID/ { /^[[:space:]]*#/! s,^,# netboot-clone: , }' "$NFS_DIR/etc/fstab"
  # Gate on the VALUE: a rescue root that still mounts the card it may overwrite is unusable.
  left=$($SUDO grep -cE '^[^#]*mmcblk0|^[^#]*PARTUUID' "$NFS_DIR/etc/fstab" 2>/dev/null)
  [ "$left" -eq 0 ] || die "$left card-mounting line(s) still active in $NFS_DIR/etc/fstab"
  # The rescue root must be INERT: these services belong to the real box, and some of them
  # would write to the NFS export believing they are live.
  for u in "${MASK_UNITS[@]}"; do
    $SUDO ln -sf /dev/null "$NFS_DIR/etc/systemd/system/$u.service" 2>/dev/null
  done

  # CRITICAL for a STATICALLY addressed Pi:
  # the kernel brings eth0 up via ip=dhcp and mounts the NFS root over THAT address. If the
  # clone then runs ifup and reconfigures eth0 to its static IP, the NFS root's TCP connection
  # dies mid-boot and the box hangs - indistinguishable from "netboot does not work".
  # So the rescue root must leave the kernel-configured interface completely alone.
  if $SUDO grep -qE '^[[:space:]]*iface[[:space:]]+eth0[[:space:]]+inet[[:space:]]+static' \
        "$NFS_DIR/etc/network/interfaces" 2>/dev/null; then
    $SUDO cp "$NFS_DIR/etc/network/interfaces" "$NFS_DIR/etc/network/interfaces.netboot-orig"
    $SUDO python3 - "$NFS_DIR/etc/network/interfaces" <<'EOP'
import sys, re
p = sys.argv[1]; out = []; skip = False
for line in open(p):
    if re.match(r'^\s*iface\s+eth0\s+inet\s+static', line):
        out.append('# netboot-clone: eth0 left to the kernel (ip=dhcp); reconfiguring it here\n')
        out.append('# would drop the NFS root mid-boot. Original saved as interfaces.netboot-orig\n')
        out.append('iface eth0 inet manual\n'); skip = True; continue
    if skip:
        if re.match(r'^\s*(address|netmask|gateway|dns-|broadcast|network)', line):
            out.append('# netboot-clone: ' + line); continue
        skip = False
    out.append(line)
open(p, 'w').write(''.join(out))
EOP
    # Scope the gate to the eth0 STANZA. A file-wide grep also counts other interfaces'
    # address/gateway lines (e.g. a static wlan0) and reports a false failure.
    left=$($SUDO awk '/^[[:space:]]*iface[[:space:]]+eth0/{f=1;next} /^[[:space:]]*iface[[:space:]]/{f=0} f&&/^[[:space:]]*(address|gateway|netmask)/{c++} END{print c+0}' \
           "$NFS_DIR/etc/network/interfaces")
    [ "$left" -eq 0 ] || die "static eth0 config still active in the clone's interfaces file"
    echo "  clone: eth0 set to 'manual' so the netbooted box keeps its DHCP address"
  fi

  echo "copying $SSH_HOST:/boot -> $TFTP_DIR/$SERIAL"
  $SUDO rsync -a -e "ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" \
      "root@$IP:/boot/" "$TFTP_DIR/$SERIAL/" || die "boot copy failed"
  # The netboot cmdline must point root at NFS, not at the card.
  printf 'console=serial0,115200 console=tty1 root=/dev/nfs nfsroot=%s:%s,vers=3 rw ip=dhcp rootwait elevator=deadline\n' \
      "$NFS_SERVER" "$NFS_DIR" | $SUDO tee "$TFTP_DIR/$SERIAL/cmdline.txt" >/dev/null

  echo "clone done: $($SUDO du -sh "$NFS_DIR" 2>/dev/null | cut -f1) rootfs, $(ls "$TFTP_DIR/$SERIAL" | wc -l) boot files"
  echo "VERIFY BEFORE BOOTING:  grep -nE 'mmcblk0|PARTUUID' $NFS_DIR/etc/fstab   (all should be commented)"
  echo "NOTE: once netbooted the Pi holds a DHCP address, NOT its usual static one."
  echo "      Find it in your router's DHCP lease list; 'ssh $SSH_HOST' will NOT reach it."
  ;;

status)
  echo "host    : $HOST (serial $SERIAL, export $NFS_DIR, server $NFS_SERVER $LAN_CIDR)"
  echo "dnsmasq : $(alive && echo UP || echo down)"
  echo "active  : $(active_hosts | tr '\n' ' ')"
  echo "nfsd    : $(systemctl is-active nfs-kernel-server 2>/dev/null)"
  echo "export  : $($SUDO exportfs -v 2>/dev/null | grep -c "$NFS_DIR") entry for $HOST"
  echo "ufw     : $($SUDO ufw status 2>/dev/null | grep -cE 'PINETBOOT') rule(s)"
  echo "tftp    : $(ls "$TFTP_DIR/$SERIAL" 2>/dev/null | wc -l) files in $TFTP_DIR/$SERIAL"
  echo "nfsroot : $($SUDO du -sh "$NFS_DIR" 2>/dev/null | cut -f1)"
  ;;
*) die "usage: $(basename "$0") <host> {start|stop|cycle|status|clone}" ;;
esac
