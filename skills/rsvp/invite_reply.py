#!/usr/bin/env python3
"""Answer a calendar invite AS the address that was invited, so the organiser sees "accepted"
from that address - not from a Gmail account the mail was forwarded to, which is what Gmail's
RSVP buttons send.

Reads invites straight out of the invited mailbox's INBOX (it keeps a copy of everything it
forwards), builds an iTIP METHOD:REPLY and sends it over SMTP SSL (465).

  invite_reply.py list [--days 30]            invites in the inbox, newest first
  invite_reply.py show N [--decline|--tentative]   the invite + the exact REPLY it would send
  invite_reply.py send N --expect "words from title" --yes [--decline|--tentative] [--note "text"]

Sending is OUTWARD-FACING: only on the user's explicit word for THAT invite. `send` without
--yes only prints. Creds: INVITE_REPLY_USER/_PASS/_IMAP/_SMTP/_NAME from the environment or
~/.config/invite-reply.env (override with INVITE_REPLY_ENV), parsed here, never sourced or put
in argv; any library error is re-raised by type only (an exception message is a second channel).
"""
import argparse
import datetime as dt
import email
import email.policy
import os
import imaplib
import re
import smtplib
import ssl
import sys
import uuid
from email.message import EmailMessage
from email.utils import formataddr, make_msgid, parseaddr
from pathlib import Path

ENV = Path(os.path.expanduser(os.environ.get("INVITE_REPLY_ENV", "~/.config/invite-reply.env")))
NEED = ["INVITE_REPLY_USER", "INVITE_REPLY_PASS", "INVITE_REPLY_IMAP", "INVITE_REPLY_SMTP"]
ME_NAME = ""  # set from INVITE_REPLY_NAME in main()
PARTSTAT = {"accept": ("ACCEPTED", "Accepted"), "decline": ("DECLINED", "Declined"),
            "tentative": ("TENTATIVE", "Tentative")}


class Fail(Exception):
    pass


def safe(what, fn, *a, **kw):
    try:
        return fn(*a, **kw)
    except Exception as e:  # noqa: BLE001 - deliberately opaque, may carry creds
        raise Fail(f"{what}: {type(e).__name__}") from None


def creds():
    env = {}
    if ENV.exists():
        for line in ENV.read_text().splitlines():
            m = re.match(r"\s*(?:export\s+)?([A-Z_]+)=(.*)", line)
            if m:
                env[m.group(1)] = m.group(2).strip().strip("'\"")
    for k in NEED + ["INVITE_REPLY_NAME"]:
        if os.environ.get(k):
            env[k] = os.environ[k]
    missing = [k for k in NEED if not env.get(k)]
    if missing:
        raise Fail(f"missing {missing} (environment or {ENV})")
    return env


def hostport(v, default):
    h, _, p = v.partition(":")
    return h, int(p) if p else default


# ── iCalendar, just enough of it ──────────────────────────────────────────────

def unfold(text):
    return re.sub(r"\r?\n[ \t]", "", text).splitlines()


def prop(line):
    """'DTSTART;TZID=X:2026...' -> ('DTSTART', {'TZID': 'X'}, '2026...')"""
    m = re.match(r'([A-Za-z0-9-]+)((?:;[^:;]+=(?:"[^"]*"|[^:;]*))*):(.*)', line)
    if not m:
        return None, {}, line
    params = {}
    for p in re.findall(r';([^=;]+)=("[^"]*"|[^:;]*)', m.group(2)):
        params[p[0].upper()] = p[1].strip('"')
    return m.group(1).upper(), params, m.group(3)


def parse_ics(text):
    lines = unfold(text)
    cal = {"method": "", "vtimezones": [], "events": []}
    stack, cur, tz = [], None, None
    for ln in lines:
        if ln.startswith("BEGIN:"):
            stack.append(ln[6:].upper())
            if stack[-1] == "VEVENT" and len(stack) == 2:
                cur = {"raw": []}
            if stack[-1] == "VTIMEZONE":
                tz = []
        if tz is not None:
            tz.append(ln)
        if cur is not None and len(stack) == 2 and stack[-1] == "VEVENT" and not ln.startswith(("BEGIN:", "END:")):
            cur["raw"].append(ln)
        if ln.startswith("END:"):
            top = stack.pop() if stack else ""
            if top == "VEVENT" and cur is not None and len(stack) == 1:
                cal["events"].append(cur)
                cur = None
            if top == "VTIMEZONE" and tz is not None:
                cal["vtimezones"].append(tz)
                tz = None
        elif len(stack) == 1 and ln.upper().startswith("METHOD:"):
            cal["method"] = ln.split(":", 1)[1].strip().upper()
    return cal


def first(ev, name):
    for ln in ev["raw"]:
        n, params, val = prop(ln)
        if n == name:
            return ln, params, val
    return None, {}, ""


def attendees(ev):
    out = []
    for ln in ev["raw"]:
        n, params, val = prop(ln)
        if n == "ATTENDEE":
            out.append((val.split(":", 1)[-1].lower() if val.lower().startswith("mailto:") else val.lower(), params))
    return out


def untext(v):
    """iCalendar TEXT unescape, for display and the mail Subject only (the .ics keeps the raw line)."""
    return re.sub(r"\\([,;\\nN])", lambda m: "\n" if m.group(1) in "nN" else m.group(1), v).strip()


def fold(line):
    b = line.encode()
    if len(b) <= 75:
        return line
    out, chunk = [], b""
    for ch in line:
        cb = ch.encode()
        if len(chunk) + len(cb) > (75 if not out else 74):
            out.append(chunk.decode())
            chunk = b""
        chunk += cb
    out.append(chunk.decode())
    return "\r\n ".join(out)


def build_reply(cal, ev, me, status):
    partstat = PARTSTAT[status][0]
    keep = ("UID", "SEQUENCE", "RECURRENCE-ID", "DTSTART", "DTEND", "DURATION", "SUMMARY", "ORGANIZER")
    body = ["BEGIN:VCALENDAR", "PRODID:-//claude-code-skills//invite-reply//EN", "VERSION:2.0", "METHOD:REPLY"]
    for tz in cal["vtimezones"]:
        body += tz
    body += ["BEGIN:VEVENT"]
    seen = set()
    for ln in ev["raw"]:
        n = prop(ln)[0]
        if n in keep and n not in seen:
            body.append(ln)
            seen.add(n)
    if "SEQUENCE" not in seen:
        body.append("SEQUENCE:0")
    body.append("DTSTAMP:" + dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ"))
    body.append(f'ATTENDEE;PARTSTAT={partstat};CN="{ME_NAME}":mailto:{me}')
    body += ["END:VEVENT", "END:VCALENDAR"]
    return "\r\n".join(fold(l) for l in body) + "\r\n"


# ── mailbox ───────────────────────────────────────────────────────────────────

def imap_login(env):
    m = safe("imap connect", imaplib.IMAP4_SSL, *hostport(env["INVITE_REPLY_IMAP"], 993),
             ssl_context=ssl.create_default_context())
    safe("imap login", m.login, env["INVITE_REPLY_USER"], env["INVITE_REPLY_PASS"])
    return m


def calendar_parts(msg):
    for part in msg.walk():
        ct = part.get_content_type()
        fn = (part.get_filename() or "").lower()
        if ct in ("text/calendar", "application/ics") or fn.endswith(".ics"):
            payload = part.get_payload(decode=True) or b""
            yield payload.decode(part.get_content_charset() or "utf-8", "replace")


def invites(env, days):
    m = imap_login(env)
    try:
        safe("select", m.select, "INBOX", readonly=True)
        since = (dt.date.today() - dt.timedelta(days=days)).strftime("%d-%b-%Y")
        typ, data = safe("search", m.uid, "SEARCH", None, "SINCE", since)
        uids = data[0].split()
        if not uids:
            return []
        typ, bs = safe("bodystructure", m.uid, "FETCH", b",".join(uids), "(UID BODYSTRUCTURE)")
        cand = []
        for item in bs:
            s = item if isinstance(item, bytes) else b"".join(x for x in item if isinstance(x, bytes))
            if re.search(rb'"calendar"|\.ics"|"ics"', s, re.I):
                u = re.search(rb"UID (\d+)", s)
                if u:
                    cand.append(u.group(1))
        out = []
        for u in cand:
            typ, d = safe("fetch", m.uid, "FETCH", u, "(BODY.PEEK[])")
            raw = next((x[1] for x in d if isinstance(x, tuple)), None)
            if not raw:
                continue
            msg = email.message_from_bytes(raw, policy=email.policy.default)
            for ics in calendar_parts(msg):
                cal = parse_ics(ics)
                if cal["method"] == "REQUEST" and cal["events"]:
                    out.append({"uid": u.decode(), "msg": msg, "cal": cal})
                    break
        out.sort(key=lambda x: email.utils.parsedate_to_datetime(x["msg"]["Date"]) if x["msg"]["Date"] else dt.datetime.min.replace(tzinfo=dt.timezone.utc), reverse=True)
        return out
    finally:
        try:
            m.logout()
        except Exception:  # noqa: BLE001
            pass


def seq_of(inv):
    v = first(inv["cal"]["events"][0], "SEQUENCE")[2]
    return int(v) if v.strip().isdigit() else 0


def describe(i, inv, me, newest_seq=None):
    ev = inv["cal"]["events"][0]
    summary = untext(first(ev, "SUMMARY")[2])
    dts, p, dtv = first(ev, "DTSTART")
    past = dtv[:8] < dt.date.today().strftime("%Y%m%d")
    _, _, org = first(ev, "ORGANIZER")
    _, _, seq = first(ev, "SEQUENCE")
    att = [a for a, _ in attendees(ev)]
    mine = me.lower() in att
    when = f"{dtv} {p.get('TZID', 'UTC' if dtv.endswith('Z') else 'floating')}"
    return (f"[{i}] {inv['msg']['Date']}\n    {summary}\n    start {when}  seq {seq or 0}"
            f"  events {len(inv['cal']['events'])}{'  (PAST)' if past else ''}"
            f"{f'  SUPERSEDED by seq {newest_seq}' if newest_seq is not None and newest_seq > seq_of(inv) else ''}\n    organiser {org.split(':', 1)[-1]}"
            f"\n    {me} on attendee list: {'YES' if mine else 'NO'}  ({len(att)} attendees)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["list", "show", "send"])
    ap.add_argument("n", nargs="?", type=int)
    ap.add_argument("--days", type=int, default=30)
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--decline", action="store_true")
    g.add_argument("--tentative", action="store_true")
    ap.add_argument("--note", default="")
    ap.add_argument("--expect", default="", help="refuse unless the SUMMARY contains this (guards N shifting)")
    ap.add_argument("--yes", action="store_true", help="actually send (the user's explicit word, per invite)")
    a = ap.parse_args()
    status = "decline" if a.decline else "tentative" if a.tentative else "accept"

    try:
        env = creds()
        global ME_NAME
        me = env["INVITE_REPLY_USER"].lower()
        ME_NAME = env.get("INVITE_REPLY_NAME") or me
        inv = invites(env, a.days)
        # a reschedule bumps SEQUENCE; the newest MAIL is not always the highest SEQUENCE
        top = {}
        for x in inv:
            u = first(x["cal"]["events"][0], "UID")[2]
            top[u] = max(top.get(u, 0), seq_of(x))
        newest = lambda x: top[first(x["cal"]["events"][0], "UID")[2]]  # noqa: E731
        if a.cmd == "list":
            for i, x in enumerate(inv, 1):
                print(describe(i, x, me, newest(x)))
            print(f"{len(inv)} invite(s) in the last {a.days} days")
            return
        if not a.n or not 1 <= a.n <= len(inv):
            sys.exit(f"pick N from `list` (1..{len(inv)})")
        x = inv[a.n - 1]
        ev = x["cal"]["events"][0]
        print(describe(a.n, x, me, newest(x)))
        if newest(x) > seq_of(x):
            sys.exit("REFUSING: a newer version (higher SEQUENCE) of this invite exists - answer that one")
        if me not in [att for att, _ in attendees(ev)]:
            sys.exit(f"REFUSING: {me} is not an attendee on this invite - a REPLY from it would be "
                     "ignored or added as a stranger")
        if len(x["cal"]["events"]) > 1:
            print("NOTE: invite carries several VEVENTs (recurrence overrides); replying to the first")
        _, _, org = first(ev, "ORGANIZER")
        org_addr = org.split(":", 1)[-1] if org.lower().startswith("mailto:") else org
        summary = untext(first(ev, "SUMMARY")[2])
        if a.expect and a.expect.lower() not in summary.lower():
            sys.exit(f"REFUSING: #{a.n} is {summary!r}, not --expect {a.expect!r} (list order shifted?)")
        ics = build_reply(x["cal"], ev, me, status)

        out = EmailMessage()
        out["From"] = formataddr((ME_NAME, me))
        out["To"] = org_addr
        out["Subject"] = f"{PARTSTAT[status][1]}: {summary}"
        out["Message-ID"] = make_msgid(domain=me.split("@")[1])
        if x["msg"]["Message-ID"]:
            out["In-Reply-To"] = x["msg"]["Message-ID"]
            out["References"] = x["msg"]["Message-ID"]
        verb = {"accept": "accepted", "decline": "declined", "tentative": "tentatively accepted"}[status]
        out.set_content((a.note + "\n\n" if a.note else "") + f"{ME_NAME} has {verb} this invitation.\n")
        out.add_alternative(ics, subtype="calendar", params={"method": "REPLY"})

        print(f"\n--- would send ---\nFrom: {out['From']}\nTo: {out['To']}\nSubject: {out['Subject']}\n"
              f"In-Reply-To: {out['In-Reply-To']}\n\n{ics}")
        if a.cmd == "show" or not a.yes:
            print("NOT SENT" + ("" if a.cmd == "show" else " (needs --yes, on the user's word for this invite)"))
            return
        s = safe("smtp connect", smtplib.SMTP_SSL, *hostport(env["INVITE_REPLY_SMTP"], 465),
                 context=ssl.create_default_context(), timeout=30)
        try:
            safe("smtp login", s.login, env["INVITE_REPLY_USER"], env["INVITE_REPLY_PASS"])
            refused = safe("smtp send", s.send_message, out)
        finally:
            try:
                s.quit()
            except Exception:  # noqa: BLE001
                pass
        if refused:
            sys.exit(f"SMTP refused: {list(refused)}")
        # keep a copy in Sent so the mailbox shows what went out
        m = imap_login(env)
        try:
            safe("append Sent", m.append, "Sent", r"(\Seen)", imaplib.Time2Internaldate(dt.datetime.now().astimezone()), out.as_bytes())
        except Fail as e:
            print(f"sent, but no Sent copy ({e})")
        finally:
            m.logout()
        print(f"SENT {PARTSTAT[status][1]} to {org_addr}")
    except Fail as e:
        sys.exit(f"ERROR {e}")


if __name__ == "__main__":
    main()
