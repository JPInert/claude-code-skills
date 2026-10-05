#!/bin/bash
# grub-bigfont.sh: make GRUB's menu readable on a high-DPI panel (60 px DejaVu Sans Mono).
# Run on the installed Debian. Backs up /etc/default/grub and grub.cfg, and restores both if the
# regenerated grub.cfg is missing the Debian entry, the Windows entry or the font. SIZE=60 to change.
set -u
SIZE=${SIZE:-60}
STAMP=$(date +%Y%m%d-%H%M%S)
fail(){ echo "ABORT: $*"; exit 1; }
TTF=/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf
[ -f "$TTF" ] || fail "no $TTF"
command -v grub-mkfont >/dev/null || fail "no grub-mkfont"
sudo -n cp -p /etc/default/grub /etc/default/grub.bak-$STAMP || fail "backup default"
sudo -n cp -p /boot/grub/grub.cfg /boot/grub/grub.cfg.bak-$STAMP || fail "backup grub.cfg"
echo "backups listed: $(ls -1 /etc/default/grub.bak-$STAMP /boot/grub/grub.cfg.bak-$STAMP | wc -l) files, $(stat -c %s /boot/grub/grub.cfg.bak-$STAMP) bytes"
sudo -n mkdir -p /boot/grub/fonts
sudo -n grub-mkfont -s $SIZE -o /boot/grub/fonts/DejaVuSansMono$SIZE.pf2 "$TTF" 2>&1 | head -2
[ -s /boot/grub/fonts/DejaVuSansMono$SIZE.pf2 ] || fail "font not generated"
echo "font bytes: $(stat -c %s /boot/grub/fonts/DejaVuSansMono$SIZE.pf2)"
if grep -q '^GRUB_FONT=' /etc/default/grub; then sudo -n sed -i 's#^GRUB_FONT=.*#GRUB_FONT=/boot/grub/fonts/DejaVuSansMono$SIZE.pf2#' /etc/default/grub; else echo 'GRUB_FONT=/boot/grub/fonts/DejaVuSansMono$SIZE.pf2' | sudo -n tee -a /etc/default/grub >/dev/null; fi
sudo -n update-grub 2>&1 | tail -6
n_deb=$(sudo -n grep -c "^menuentry 'Debian GNU/Linux'" /boot/grub/grub.cfg); n_win=$(sudo -n grep -c "^menuentry 'Windows Boot Manager" /boot/grub/grub.cfg); n_font=$(sudo -n grep -c 'loadfont /boot/grub/fonts/DejaVuSansMono$SIZE.pf2' /boot/grub/grub.cfg)
echo "READBACK: debian_entries=$n_deb windows_entries=$n_win font_loaded=$n_font"
if [ "$n_deb" -lt 1 ] || [ "$n_win" -lt 1 ] || [ "$n_font" -lt 1 ]; then sudo -n cp -p /boot/grub/grub.cfg.bak-$STAMP /boot/grub/grub.cfg; sudo -n cp -p /etc/default/grub.bak-$STAMP /etc/default/grub; echo "RESTORED backups (check failed)"; fi
grep -E '^GRUB_(DEFAULT|TIMEOUT|FONT|GFXMODE)' /etc/default/grub
