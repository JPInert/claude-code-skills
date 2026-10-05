---
name: sshhost
description: Make a new or rebuilt Linux box reachable as `ssh <name>` like your others - an ssh config entry that names the IP too, your key on the box, and a key-only test. Use when the user says /sshhost, "add the box to ssh", "so I can just ssh in", "make ssh X work", "why does ssh X ask for a password / say permission denied", and AUTOMATICALLY as the last step whenever a session creates, reimages or re-IPs a Linux box (cloud VM, Pi, laptop, container host).
---
<!-- needs: OpenSSH client with an ed25519 key (~/.ssh/id_ed25519), password or console access to the new box once. -->
<!-- no accounts or hardware. Works best if your ~/.ssh/config ends with a strict `Host *` block like the one below. -->

# Add a box to your ssh list

A box is "on the list" when all of these hold. Do every one, then run the test.

| # | What | Where |
|---|---|---|
| 1 | `Host <name> <ip>` entry (the IP too, so a bare `ssh user@<ip>` also finds the key): `HostName`, `User`, `IdentityFile ~/.ssh/id_ed25519` | `~/.ssh/config`, **above `Host *`** |
| 2 | Your public key in the box's `~/.ssh/authorized_keys` | cloud: pass the `.pub` at launch; existing box: `ssh-copy-id -i ~/.ssh/id_ed25519.pub user@ip` |
| 3 | The box's own aliases load in a login shell | Ubuntu/Debian `.profile` sources `.bashrc`, so put aliases in `~/.bashrc` |

**Why the IP belongs on the `Host` line.** A strict tail like

```
Host *
    IdentitiesOnly yes
    IdentityFile none
```

stops ssh offering every key it knows to every server (which trips `MaxAuthTries` and leaks which
keys you hold). The cost: a bare `ssh user@ip` offers NO key and gets
`Permission denied (publickey)` unless that IP is on a `Host` line with an `IdentityFile`.

## Rules

- **`ssh-copy-id` reads the password from `/dev/tty`, not stdin.** From an agent's shell (no TTY)
  it hangs or fails; run it in a pty, or have the user type it once. If `SSH_ASKPASS` and
  `DISPLAY` are set, ssh may pop a GUI dialog nobody sees; unset them for a terminal prompt.
- A cloud box's public IP can change after a stop/start: update `HostName` AND the IP on the
  `Host` line, and say so.
- If your `~/.ssh/config` is a symlink into a dotfiles repo, edit the repo copy and commit it,
  or the next machine will not have the entry.
- After a reimage, the host key changed: `ssh-keygen -R <name>` and `ssh-keygen -R <ip>`, then
  accept the new key once, deliberately. Never turn off `StrictHostKeyChecking` globally to make
  the warning go away.

## Test (every time)

```
ssh -o BatchMode=yes <name> hostname        # key auth by name, no prompt
ssh -o BatchMode=yes <user>@<ip> hostname   # key auth by bare IP, proves step 1's IP
```

Both must print the hostname. Then tell the user the exact command they type: `ssh <name>`.
