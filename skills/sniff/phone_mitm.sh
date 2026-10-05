#!/usr/bin/env bash
# phone_mitm.sh — watch the HTTP(S) an Android app actually sends, live, on the desktop.
#
# Why a proxy and not PCAPdroid: PCAPdroid cannot decrypt TLS while running its root
# capture ("the SOCKS5 proxy is not available. This means that the TLS decryption is not
# available with root capture enabled"), so decrypting on the phone forces its VPN mode —
# and Android has exactly one VPN slot, which the WireGuard tunnel occupies. A system-wide
# proxy (set by `proxy on`) uses no VPN, so a WireGuard tunnel can stay up. PCAPdroid remains the right
# tool for "which app talks to which host" with no setup at all — it needs no cert and no
# proxy, and works on cellular. See the comparison at the bottom of this file.
#
# Two halves, both needed before any HTTPS body shows up:
#
#   trust — put mitmproxy's CA in the phone's SYSTEM store. Mandatory because since
#           Android 7 an app ignores user-installed CAs. Android 14+ moved that store
#           into the Conscrypt APEX, whose mounts are PRIVATE, so a tmpfs over
#           /system/etc/security/cacerts is invisible to apps until it is bind-mounted
#           into each app's mount namespace (zygote for apps started later, every running
#           app for now). Technique from
#           https://httptoolkit.com/blog/android-14-install-system-ca-certificate/
#           It is TEMPORARY — the mounts die with the next reboot, so re-run after one.
#
#   proxy — point the phone's global proxy at this desktop. Restores with `proxy off`.
#
# adb, not ssh — where available: Termux has its own mount namespace (`su -c
# "ls /data/data"` there returns 2 entries), so anything mounted from Termux is invisible
# to the apps we want to intercept. adb shell's namespace is the normal one, and `adb
# root` fails on most retail builds — `su -c` is the working root path. Wireless debugging
# only turns on over WiFi, so away from home the transport is ssh: commands then run as
# `su -c "nsenter --mount=/proc/1/ns/mnt -- …"`, which lands in PID 1's namespace — the
# right one, and the tmpfs it creates propagates to the app namespaces that / finds
# shared; the per-app bind mounts are made explicitly in each namespace either way.
#
# Apps that ignore the system proxy (Flutter/dart:io, anything with its own network stack)
# will stay invisible here; those need PCAPdroid's SOCKS5 mode or HTTP Toolkit's VPN app.
#
# Usage:
#   phone_mitm.sh trust                    # inject the CA (once per phone boot)
#   phone_mitm.sh proxy on | off
#   phone_mitm.sh watch                    # one line per request + its status
#   phone_mitm.sh watch '~m POST'          # only POSTs
#   phone_mitm.sh watch --flow-detail 3    # include bodies        (2 = headers)
#   phone_mitm.sh watch -w /tmp/phone.mitm # save the whole capture
#   phone_mitm.sh web                      # mitmweb GUI — use the ?token=… URL it prints
#   phone_mitm.sh status
#   phone_mitm.sh off                      # proxy off + stop the local mitm on $PORT
set -euo pipefail

PHONE="${PHONE_SSH_HOST:-phone}"   # ssh alias for Termux's sshd on the phone
PORT="${PHONE_MITM_PORT:-8080}"
CERT="${PHONE_MITM_CERT:-$HOME/.mitmproxy/mitmproxy-ca-cert.pem}"
DEVTMP=/data/local/tmp
DEVICE_SCRIPT_NAME=phone-mitm-ca.sh
TRANSPORT=   # adb | ssh, resolved per command by require_phone
TERMUX_HOME= # Termux's $HOME on the phone, resolved lazily over ssh

die() { echo "phone_mitm: $*" >&2; exit 1; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

mitm_bin() {
    local name="$1" p
    p=$(command -v "$name" 2>/dev/null || true)
    [ -n "$p" ] || p="$HOME/.local/bin/$name"
    [ -x "$p" ] || die "$name not found — pipx install mitmproxy"
    printf '%s\n' "$p"
}

mitm_pids() { pgrep -f "mitm(dump|web).*-p $PORT" 2>/dev/null || true; }

# The phone's ip:port on adb, discovering wireless debugging over mDNS when nothing is
# connected yet — the connect port is re-randomized every time wireless debugging toggles
# or the phone rejoins the network, so it must never be hard-coded.
phone_addr() {
    local a
    a=$(adb devices | awk 'NR>1 && $2=="device"{print $1}' | grep -E '^[0-9.]+:[0-9]+$' | head -1 || true)
    if [ -z "$a" ]; then
        a=$(adb mdns services 2>/dev/null | awk '/_adb-tls-connect/{print $NF}' | head -1 || true)
    fi
    if [ -z "$a" ] && have_cmd avahi-browse; then
        a=$(timeout 5 avahi-browse -rtp _adb-tls-connect._tcp 2>/dev/null |
            awk -F';' '/^=/{print $8":"$9}' | head -1 || true)
    fi
    [ -n "$a" ] || return 1
    printf '%s\n' "$a"
}

adb_ready() {
    have_cmd adb || return 1
    local a
    a=$(phone_addr) || return 1
    case "$a" in
    *:*) adb connect "$a" >/dev/null 2>&1 || true ;;
    esac
    adb devices | awk 'NR>1 && $2=="device"' | grep -q .
}

# Two transports, because wireless debugging only turns on over WiFi: adb when the
# phone is on the same WiFi, Termux's sshd otherwise. Off-LAN the phone is only
# reachable through a VPN or, when the VPN's inbound path is broken, through its own
# reverse tunnel to this desktop (`ssh -R 8022:localhost:8022 <you>@<desktop>` in Termux).
ssh_ready() { ssh -o ConnectTimeout=8 -o BatchMode=yes "$PHONE" true >/dev/null 2>&1; }

# Sets TRANSPORT (adb|ssh) for the current connection; dies if neither answers.
require_phone() {
    if adb_ready; then
        TRANSPORT=adb
    elif ssh_ready; then
        TRANSPORT=ssh
    else
        die "no phone: no adb device (wireless debugging is WiFi-only) and 'ssh $PHONE' does not answer"
    fi
}

termux_home() {
    [ -n "${TERMUX_HOME:-}" ] && return 0
    TERMUX_HOME=$(ssh -o ConnectTimeout=8 "$PHONE" 'printf %s "$HOME"') || die "cannot read \$HOME over ssh"
    [ -n "$TERMUX_HOME" ] || die "empty \$HOME over ssh"
    # Every path built from this goes through another shell's quoting; nothing here
    # may contain a space, quote or shell metacharacter.
    case "$TERMUX_HOME" in
    *[!A-Za-z0-9/_.-]*) die "unexpected characters in the phone's \$HOME: $TERMUX_HOME" ;;
    esac
}

# Stage a local file on the device where root can read it, and set STAGED to that path.
# adb lands it in /data/local/tmp; ssh has to go through the Termux user's own home
# (nothing else is writable without root), which PID 1's namespace can read fine.
STAGED=
phone_stage() {
    case "$TRANSPORT" in
    adb)
        adb push "$1" "$DEVTMP/$2" >/dev/null
        STAGED="$DEVTMP/$2"
        ;;
    ssh)
        termux_home
        scp -q -o ConnectTimeout=8 "$1" "$PHONE:$TERMUX_HOME/$2"
        STAGED="$TERMUX_HOME/$2"
        ;;
    esac
}

# Root shell on the phone. `adb root` is not available on most retail builds;
# `su -c` works over both transports. From Termux the command needs nsenter: `su` there
# inherits Termux's own mount namespace, which cannot see the real /data.
sh_root() {
    case "$TRANSPORT" in
    adb) adb shell "su -c '$*'" ;;
    ssh) ssh -o ConnectTimeout=8 "$PHONE" "su -c 'nsenter --mount=/proc/1/ns/mnt -- $*'" ;;
    esac
}

# The address the phone must use for this desktop. Over adb it is whatever source address
# this host would use to reach the phone, which is right on the LAN and over WireGuard
# alike; over ssh the phone reaches the LAN through a VPN, so it is this host's
# primary address (that is also the address its reverse tunnel dials).
desktop_ip() {
    local ip
    if [ "$TRANSPORT" = adb ]; then
        local a
        a=$(phone_addr) || die "phone not on adb"
        ip=$(ip route get "${a%%:*}" 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')
    else
        ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')
    fi
    [ -n "$ip" ] || die "could not work out this desktop's IP for the phone"
    printf '%s\n' "$ip"
}

cert_fields() {
    [ -f "$CERT" ] || die "no CA at $CERT — run mitmdump once (or --version) to generate it"
    CERT_HASH=$(openssl x509 -inform PEM -subject_hash_old -in "$CERT" | head -1)
    CERT_SHA256=$(openssl x509 -in "$CERT" -noout -fingerprint -sha256 | cut -d= -f2)
    [ -n "$CERT_HASH" ] || die "could not hash $CERT"
}

# Fingerprint of the cert the phone is currently serving from its system store, if any.
installed_fingerprint() {
    sh_root "cat /system/etc/security/cacerts/$CERT_HASH.0" 2>/dev/null |
        openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 || true
}

usage() { awk '/^# Usage:/{p=1} /^set -euo pipefail/{exit} p{sub(/^# ?/, ""); print}' "$0"; }

# ── subcommands ───────────────────────────────────────────────────────────────
cmd_trust() {
    require_phone
    cert_fields
    sh_root id 2>/dev/null | grep -q 'uid=0' ||
        die "no root on the phone (su -c id did not print uid=0)"
    if [ "$CERT_SHA256" = "$(installed_fingerprint)" ]; then
        echo "already trusted: $CERT_HASH.0"
        return 0
    fi

    local script cert_on_device script_on_device out
    script=$(mktemp)
    trap 'rm -f "$script"' EXIT RETURN
    cat >"$script" <<'DEVICE_SCRIPT'
PATH=/system/bin:/system/xbin:$PATH
set -e
CERT="$1"
STORE=/system/etc/security/cacerts
APEX=/apex/com.android.conscrypt/cacerts
COPY=/data/local/tmp/phone-mitm-ca-copy

[ -f "$CERT" ] || { echo "phone-mitm: cert not found: $CERT" >&2; exit 1; }

# If we die before the store is rebuilt, take the tmpfs back down: apps then fall through
# to the untouched APEX/real store instead of reading an empty or half-copied one.
STORE_READY=0
trap '[ "$STORE_READY" = 1 ] || umount -l "$STORE" 2>/dev/null' EXIT

# Repeated injections stack mounts, and a stale layer would hide the real certificates.
# Lazy-unmount one layer at a time until the path is clear, bounded in case something
# cannot be unmounted at all.
unmount_all() {
    n=0
    while umount -l "$1" 2>/dev/null; do
        n=$((n + 1))
        [ "$n" -ge 50 ] && break
    done
    return 0
}
unmount_all "$APEX"
unmount_all "$STORE"

# Copy the existing certs out first: after the tmpfs goes on top they are unreadable.
rm -rf "$COPY"
mkdir -p "$COPY"
chmod 700 "$COPY"
if [ -d "$APEX" ]; then cp "$APEX"/* "$COPY"/; else cp "$STORE"/* "$COPY"/; fi

mount -t tmpfs tmpfs "$STORE" || { echo "phone-mitm: tmpfs mount on $STORE failed" >&2; exit 1; }
mv "$COPY"/* "$STORE"/
mv "$CERT" "$STORE"/

chown root:root "$STORE"/*
chmod 644 "$STORE"/*
if command -v chcon >/dev/null 2>&1; then
    chcon u:object_r:system_file:s0 "$STORE" "$STORE"/*
fi
rmdir "$COPY" 2>/dev/null || true
STORE_READY=1   # from here the mounted store is complete; never roll it back

# Android 14+: the APEX store is what apps read, and /apex is mounted PRIVATE, so the
# bind mount has to be repeated inside every mount namespace that matters.
if [ -d "$APEX" ]; then
    REBIND="for i in 1 2 3 4 5; do umount -l $APEX 2>/dev/null || break; done; mount --bind $STORE $APEX"
    sh -c "$REBIND"

    ZP="$(pidof zygote || true) $(pidof zygote64 || true)"
    # Apps started from now on inherit the zygote's mounts, so inject there first.
    for p in $ZP; do nsenter --mount=/proc/$p/ns/mnt -- sh -c "$REBIND"; done

    # Then every process whose parent is a zygote, so already-running apps see it too.
    # /proc rather than ps: no dependency on which ps flags this toybox build keeps.
    APP_PIDS=""
    for d in /proc/[0-9]*; do
        p=${d#/proc/}
        pp=$(cut -d' ' -f4 "$d/stat" 2>/dev/null || true)
        for z in $ZP; do
            [ -n "$z" ] && [ "$pp" = "$z" ] && APP_PIDS="$APP_PIDS $p"
        done
    done
    for p in $APP_PIDS; do
        nsenter --mount=/proc/$p/ns/mnt -- sh -c "$REBIND" &
    done
    wait || true
fi

echo "phone-mitm: system cert injected"
DEVICE_SCRIPT

    phone_stage "$CERT" "$CERT_HASH.0"
    cert_on_device="$STAGED"
    phone_stage "$script" "$DEVICE_SCRIPT_NAME"
    script_on_device="$STAGED"
    out=$(sh_root "sh $script_on_device $cert_on_device") ||
        die "injection failed on the phone: $out"
    case "$out" in
    *"phone-mitm: system cert injected"*) echo "trusted $CERT_HASH.0 (system store — until the next reboot)" ;;
    *) die "injection did not report success: $out" ;;
    esac
    [ "$CERT_SHA256" = "$(installed_fingerprint)" ] ||
        die "cert is not readable back from the system store — apps will still reject it"
}

cmd_proxy() {
    case "${1:-}" in
    on)
        require_phone
        local ip
        ip=$(desktop_ip)
        sh_root "settings put global http_proxy $ip:$PORT"
        echo "phone proxy → $ip:$PORT (apps that ignore the platform proxy stay direct)"
        ;;
    off)
        require_phone
        sh_root "settings put global http_proxy :0"
        sh_root "settings delete global http_proxy" >/dev/null
        sh_root "settings delete global global_http_proxy_host" >/dev/null
        sh_root "settings delete global global_http_proxy_port" >/dev/null
        echo "phone proxy cleared"
        ;;
    *) die "proxy takes on|off" ;;
    esac
}

cmd_watch() {
    local bin
    bin=$(mitm_bin mitmdump)
    exec "$bin" -p "$PORT" --flow-detail "${FLOW_DETAIL:-1}" --set termlog_verbosity=warn "$@"
}

cmd_web() {
    local bin
    bin=$(mitm_bin mitmweb)
    exec "$bin" -p "$PORT" "$@"
}

cmd_status() {
    local pids
    pids=$(mitm_pids | tr '\n' ' ' | sed 's/ *$//')
    echo "mitm:    ${pids:-nothing listening on :$PORT}"
    if adb_ready; then
        TRANSPORT=adb
    elif ssh_ready; then
        TRANSPORT=ssh
    else
        echo "phone:   unreachable — no adb device (wireless debugging is WiFi-only) and no ssh"
        return 0
    fi
    echo "phone:   $TRANSPORT"
    echo "desktop: $(desktop_ip)"
    echo "proxy:   $(sh_root "settings get global http_proxy" 2>/dev/null | tr -d '\r')"
    if [ -f "$CERT" ]; then
        # Never die here: `status` must report, not abort.
        local hash
        hash=$(openssl x509 -inform PEM -subject_hash_old -in "$CERT" 2>/dev/null | head -1)
        if [ -z "$hash" ]; then
            echo "cert:    $CERT is not a readable CA certificate"
        else
            CERT_HASH=$hash
            CERT_SHA256=$(openssl x509 -in "$CERT" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)
            if [ -n "$CERT_SHA256" ] && [ "$CERT_SHA256" = "$(installed_fingerprint)" ]; then
                echo "cert:    trusted ($CERT_HASH.0)"
            else
                echo "cert:    NOT trusted — run: $0 trust"
            fi
        fi
    else
        echo "cert:    no mitmproxy CA generated on this desktop yet"
    fi
}

cmd_off() {
    local pids
    pids=$(mitm_pids)
    if [ -n "$pids" ]; then
        kill $pids 2>/dev/null && echo "stopped mitm ($pids)" || true
    fi
    if adb_ready; then
        TRANSPORT=adb
    elif ssh_ready; then
        TRANSPORT=ssh
    else
        # Leave nothing silently pointing at a proxy that is no longer listening.
        echo "phone_mitm: phone unreachable — its proxy is still set; run '$0 proxy off' once it is back" >&2
        return 1
    fi
    cmd_proxy off
}

case "${1:-}" in
trust) shift; cmd_trust "$@" ;;
proxy) shift; cmd_proxy "$@" ;;
watch) shift; cmd_watch "$@" ;;
web) shift; cmd_web "$@" ;;
status) shift; cmd_status "$@" ;;
off) shift; cmd_off "$@" ;;
"" | -h | --help | help) usage ;;
*) die "unknown subcommand '$1' — try: $0 help" ;;
esac

# ── the alternatives, for when this is the wrong tool ─────────────────────────
#
# PCAPdroid (free, on the phone, no desktop): shows every connection with the owning app
# and, in the HTTP view, each request's method, path, status, content type and size —
# a filter there selects by method/status, and the result exports as HAR. It needs no
# root and no certificate as long as you only want hosts/SNI. Turning on its TLS
# decryption needs the mitm addon APK plus its CA in the system store, and only works in
# VPN capture mode, which collides with any other VPN. Its root capture mode explicitly
# cannot decrypt.
#
# HTTP Toolkit (free tier, desktop + Android app): automates exactly what `trust` does —
# ADB root detection, the same tmpfs + nsenter injection, and it side-loads its own APK
# from GitHub — then routes through a VPN app so per-app filtering and non-proxy-aware
# apps work. Same single-VPN-slot caveat. Its HAR export is Pro.
#
# When a VPN is up and the app ignores the proxy, the remaining lever is Frida
# (SSL_read/SSL_write hooks, no CA needed) — heavier, and it has to run as root on the
# phone.
