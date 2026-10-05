---
name: sniff
description: Watch the HTTP(S) an app on your Android phone actually sends (method, URL, status and bodies) decrypted on the desktop, using mitmproxy plus a system-store CA injected the Android 14+ way. Use when the user says /sniff, "sniff this app", "what is it calling", "capture its traffic", "show the POSTs", "which endpoints does <app> use", "what request is the phone making", or asks why an app is slow or failing on the network.
---
<!-- needs: a ROOTED Android phone (Magisk/KernelSU; `su -c` must work), reachable by adb (wireless debugging) or by ssh into Termux; -->
<!-- mitmproxy on the desktop (pipx install mitmproxy), openssl. Tested on Android 16. Set PHONE_SSH_HOST if your ssh alias is not "phone". -->

# Sniffing an app's network calls

Run this FIRST, before promising anything:

```bash
~/.claude/skills/sniff/phone_mitm.sh status
```

It reports which transport (adb or ssh), the phone's current proxy value, and whether the CA is
trusted on the device. If the phone is unreachable, fix that first; it is a separate problem.

## The sequence

```bash
phone_mitm.sh trust     # once per phone boot, see below
phone_mitm.sh proxy on  # point the phone's global HTTP proxy at this desktop
phone_mitm.sh watch     # leave running; one line per request + its status
# ... use the app, read ...
phone_mitm.sh off       # proxy off on the phone AND stop the local capture
```

- `watch '~m POST'`: only POSTs. `watch --flow-detail 3`: include bodies (2 = headers).
  `watch -w /tmp/phone.mitm`: save the whole capture. `web`: the mitmweb GUI (use the
  `?token=…` URL it prints; without the token it returns 403).
- **The proxy must never outlive the capture.** An app pointed at a proxy that is not
  listening loses its network. `off` refuses to pretend it worked if the phone is unreachable.
- The desktop firewall must allow the proxy port (default 8080) from the phone's network.

## Why `trust` is the hard part (Android 14+)

Since Android 7 apps ignore user-installed CAs, so the mitmproxy CA must go in the **system**
store. Android 14 moved that store into the Conscrypt APEX, and `/apex` is mounted PRIVATE, so a
tmpfs over `/system/etc/security/cacerts` is invisible to apps until it is bind-mounted into each
app's mount namespace: the zygote (for apps started later) and every running app (via `nsenter`).
That is what `trust` does. Technique from HTTP Toolkit's write-up on Android 14 system CAs.

- **The mounts are wiped by a reboot.** Re-run `trust` after one.
- `trust` took about 48 s over ssh on the test phone, because it re-binds every app namespace.
  Do not run it with a short timeout.
- It verifies by reading the cert back out of the system store and comparing SHA-256
  fingerprints, not by trusting its own exit code.
- Cert file name comes from `openssl x509 -subject_hash_old`.

**Over ssh into Termux, plain `su -c` is not enough.** `su` there inherits Termux's own mount
namespace, which cannot see the real `/data` (and anything mounted from it is invisible to apps).
Commands run as `su -c "nsenter --mount=/proc/1/ns/mnt -- …"` to land in PID 1's namespace.
Files are staged in Termux's `$HOME`, the only place writable without root that PID 1 can read.

## Say this before the user asks why something is missing

| Not captured | Why |
|---|---|
| Firefox | own root store; `security.enterprise_roots.enabled=true` is the documented fix (unverified) |
| Chrome | rejected the system-store CA in testing; no easy lever |
| Apps ignoring the system proxy | Flutter/`dart:io`, anything with its own stack: needs PCAPdroid or HTTP Toolkit |
| Pinned apps (banking) | needs Frida unpinning |
| QUIC/UDP, BLE, raw sockets | not HTTP; this tool cannot see them |

Platform-store apps (Play Store, Google Play services, most ordinary apps) decrypt fine.

**If the phone reaches the desktop through a VPN**, the client address mitmproxy logs is the VPN
gateway's (it NATs), not the phone's.

**mitmproxy logging `mitmproxy has crashed!` (`OpenSSL.SSL.Error: []`)** when a client aborts
mid-handshake is per-connection noise on some mitmproxy/OpenSSL combinations; the proxy keeps
serving.

**Why not PCAPdroid:** its root capture has no SOCKS5 proxy, so TLS decryption is unavailable in
that mode; decrypting needs its VPN capture mode, and Android has exactly one VPN slot. If a
WireGuard tunnel holds it, PCAPdroid cannot decrypt. It is still the right tool for "which app
talks to which host" with no setup.

Machinery and flags: `phone_mitm.sh help`.
