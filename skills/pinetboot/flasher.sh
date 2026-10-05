#!/bin/bash
# flasher.sh: write a raw image from STDIN onto the Pi's SD card, ONLY if the Pi is running
# from the NFS root and nothing on the card is mounted. Run ON the netbooted Pi, as root.
#
# Stage this file on the Pi first (scp), then pipe ONLY the image data into ssh:
#     scp flasher.sh root@<netbooted-pi>:/tmp/flasher.sh
#     xzcat image.img.xz | ssh root@<netbooted-pi> 'bash /tmp/flasher.sh'
# Never `xzcat img | ssh pi 'bash -s' <<EOF ...`: the heredoc and the pipe both claim ssh's
# stdin, and the disk silently receives script text.
#
# Every gate is on a VALUE, not a printed message.
set -euo pipefail
DEV=${FLASH_DEV:-/dev/mmcblk0}

fail() { echo "REFUSING: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "must run as root"
[ -b "$DEV" ] || fail "$DEV is not a block device"
[ ! -t 0 ] || fail "no image on stdin"

rootfs=$(findmnt -n -o FSTYPE /)
case "$rootfs" in nfs|nfs4) ;; *) fail "root filesystem is '$rootfs', not nfs: this Pi is not netbooted" ;; esac

mounted=$(findmnt -rn -o SOURCE | grep -c "^${DEV}" || true)
[ "$mounted" -eq 0 ] || fail "$mounted mount(s) still on $DEV"

swaps=$(grep -c "^${DEV}" /proc/swaps || true)
[ "$swaps" -eq 0 ] || fail "swap active on $DEV"

echo "gates passed: root=$rootfs, 0 mounts on $DEV. Writing..."
dd of="$DEV" bs=4M conv=fsync status=progress
sync
echo "done. Re-read the partition table before mounting: partprobe $DEV (or blockdev --rereadpt $DEV)"
