---
name: rsvp
description: Accept, decline or tentatively accept a calendar invite AS the exact address that was invited, so the organiser sees a real answer instead of a reply from a forwarding Gmail account or no response at all - reads the invite from that mailbox over IMAP and sends an iTIP REPLY with invite_reply.py. Use when the user says /rsvp, "accept the invite", "decline that meeting", "mark it tentative", "RSVP to <organiser>", "say yes to the invite", "did I accept that", or when an invite arrives and the next step is answering it. Also use before clicking Gmail's Yes/No/Maybe buttons on an invite that was sent to a different (forwarded) address.
---
<!-- needs: an IMAP + SMTP mailbox for the invited address (any host with SSL on 993/465), Python 3 stdlib only. -->
<!-- set INVITE_REPLY_USER / _PASS / _IMAP / _SMTP / _NAME in the env or ~/.config/invite-reply.env (mode 600). No hardware. -->

# RSVP as the invited address

**The problem this solves.** If mail for a custom-domain address is forwarded into Gmail, Gmail's
RSVP buttons answer as the *Gmail* address. An Exchange or Outlook organiser then sees the invited
attendee as *no response*, and a stranger accepted. `invite_reply.py` answers from the address that
was actually invited, by reading the original invite out of that mailbox and sending a standard
iTIP `METHOD:REPLY`. Proven end to end with a self-invite: `send` was followed by the organiser's
calendar showing `accepted` in about a minute.

## Setup

Put these in the environment or in `~/.config/invite-reply.env` (`INVITE_REPLY_ENV` overrides the
path). The file is parsed, never sourced, and no value is ever printed:

```
INVITE_REPLY_USER=...      # the invited address; also the IMAP/SMTP login
INVITE_REPLY_PASS=...
INVITE_REPLY_IMAP=...      # host[:port], default port 993
INVITE_REPLY_SMTP=...      # host[:port], default port 465
INVITE_REPLY_NAME=...      # display name on the reply, e.g. "Alex Doe"
```

The mailbox must keep a copy of what it forwards (most hosts do by default), or there is nothing
to read the invite from.

## Rules

- **Every `send --yes` is outward-facing: the user's explicit word for THAT invite.** "Accept the
  Tuesday one" is a yes for that invite only. Picking a time is not a yes to RSVP.
- Always `show N` first and quote it back: organiser, title, start time + zone, accept/decline.
- Always pass `--expect "words from the title"` on `send`: N is a position in a live inbox list
  and shifts when new mail lands.
- `--note` text goes out in the user's voice; usually no note at all.

## Commands

| | |
|---|---|
| `invite_reply.py list [--days 30]` | REQUEST invites in the INBOX, newest mail first. Marks `(PAST)`, `SUPERSEDED by seq N`, and whether the invited address is an attendee |
| `invite_reply.py show N` | the invite + the exact mail and REPLY `.ics`. Sends nothing |
| `invite_reply.py send N --expect "title words" --yes` | accept. Add `--decline` or `--tentative`; `--note "text"` |

## How it behaves

- **Refuses** when: your address is not on the ATTENDEE list (the reply would be ignored or added
  as a stranger); a higher-SEQUENCE copy of the same UID exists (answer that one, `list` shows it);
  `--expect` does not match.
- **Highest SEQUENCE wins, not newest Date.** A rescheduled invite once arrived where the
  *later* mail carried sequence 0; answering by date would have replied to the stale version.
- Sends over SMTP SSL, `In-Reply-To` the invite, then APPENDs a copy to `Sent`.
  "sent, but no Sent copy" = the mail went out; only the record failed.
- Library errors are re-raised **by exception type only**. A Python exception message can embed
  arguments, including a password, and is a second channel next to stdout.
- Several VEVENTs (recurrence overrides): replies to the first and prints a NOTE. Recurring series
  are not tested.

## After sending

- The REPLY updates only the **organiser's** calendar. The user's own calendar still needs the
  event added separately (without attendees, so adding it sends nobody anything).
- Verify if it matters: ask the organiser, or for a Google organiser read the event. There is no
  read-back for an Exchange organiser.
- Some applicant-tracking systems send invites with their own accept page link. Use that instead
  when it exists.

## Testing without bothering anyone

From any calendar you control, create an event with the invited address as the only attendee and
`availability: free`. Wait for it in `list`, `send N --expect "<title>" --yes`, check that the
event now shows `accepted`, then delete it without notifying. It is still mail leaving the box:
ask first.
