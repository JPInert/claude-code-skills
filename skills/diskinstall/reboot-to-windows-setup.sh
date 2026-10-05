#!/bin/bash
# reboot-to-windows-setup.sh: a one-tap "restart into Windows once" for a dual-boot Debian box.
# Installs a root-owned script that sets UEFI BootNext to Windows Boot Manager and reboots, a sudoers
# rule for that exact path only, and a .desktop launcher behind a kdialog confirm (a stray tap on a
# tablet must not reboot it). Run on the Debian side as the desktop user; needs efibootmgr, kdialog.
# Why not grub-reboot: it is a no-op while GRUB_DEFAULT=0.
set -u
fail(){ echo "ABORT: $*"; exit 1; }
# ---- 1. root-owned one-shot BootNext script + exact-path sudoers rule
cat > /tmp/reboot-to-windows <<'X'
#!/bin/bash
# One-shot boot into Windows via UEFI BootNext, then reboot. Installed root:root 0755 by reboot-to-windows-setup.sh.
set -eu
n=$(efibootmgr | awk '/Windows Boot Manager/ {sub(/^Boot/,"",$1); sub(/\*$/,"",$1); print $1; exit}')
case "$n" in [0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]) ;; *) echo "no Windows Boot Manager entry in efibootmgr" >&2; exit 1;; esac
efibootmgr -n "$n" >/dev/null
systemctl reboot
X
sudo -n install -o root -g root -m 0755 /tmp/reboot-to-windows /usr/local/sbin/reboot-to-windows || fail "install script"
echo "$(id -un) ALL=(root) NOPASSWD: /usr/local/sbin/reboot-to-windows" > /tmp/91-reboot-to-windows
sudo -n visudo -cf /tmp/91-reboot-to-windows >/dev/null || fail "visudo rejected the rule"
sudo -n install -o root -g root -m 0440 /tmp/91-reboot-to-windows /etc/sudoers.d/91-reboot-to-windows || fail "install sudoers"
sudo -n visudo -c 2>&1 | tail -1
echo "-- script owner/mode: $(stat -c '%U:%G %a' /usr/local/sbin/reboot-to-windows)   sudoers: $(stat -c '%U:%G %a' /etc/sudoers.d/91-reboot-to-windows)"
echo "-- dry parse of the BootNext number (no reboot): $(efibootmgr 2>/dev/null | awk '/Windows Boot Manager/ {sub(/^Boot/,"",$1); sub(/\*$/,"",$1); print $1; exit}')"
command -v kdialog >/dev/null && echo "kdialog: yes" || echo "kdialog: NO"
# ---- 2. launcher with a confirm dialog (a stray tap must not reboot the tablet)
mkdir -p ~/.local/share/applications
cat > ~/.local/share/applications/reboot-to-windows.desktop <<'X'
[Desktop Entry]
Type=Application
Name=Windows
Comment=Restart into Windows once, then return to Debian on the next restart
Exec=sh -c 'kdialog --yesno "Restart into Windows now?" && sudo -n /usr/local/sbin/reboot-to-windows'
Icon=windows
Categories=System;
X
grep -c '^Exec=' ~/.local/share/applications/reboot-to-windows.desktop
