#!/usr/bin/env python3
"""One-time 3-legged OAuth 1.0a dance for the FatSecret Platform API.

Turns a Consumer Key/Secret into a long-lived Access Token/Secret tied to
your fatsecret.com account, so fs_log.py can read the food diary and create
entries.

Reads the environment first, then the env file (default ~/.config/fatsecret.env,
override with FS_ENV_FILE) for:
    FATSECRET_CONSUMER_KEY=...
    FATSECRET_CONSUMER_SECRET=...      (the OAuth 1.0 shared secret)

Appends to that file on success (mode 600):
    FATSECRET_ACCESS_TOKEN=...
    FATSECRET_ACCESS_SECRET=...

Nothing secret is ever printed: only the authorize URL (which is safe) and
a confirmation line. Run it from a real terminal; it prompts for the PIN.

    python3 fs_auth.py            # authorize
    python3 fs_auth.py --probe    # exit 0 iff the consumer key/secret work
"""

import hashlib
import hmac
import os
import secrets as pysecrets
import sys
import time
import urllib.parse
import urllib.request

ENV_FILE = os.path.expanduser(os.environ.get("FS_ENV_FILE", "~/.config/fatsecret.env"))
KEYS = ("FATSECRET_CONSUMER_KEY", "FATSECRET_CONSUMER_SECRET",
        "FATSECRET_ACCESS_TOKEN", "FATSECRET_ACCESS_SECRET")

AUTH_BASE = "https://authentication.fatsecret.com/oauth"
REQUEST_TOKEN_URL = AUTH_BASE + "/request_token"
AUTHORIZE_URL = AUTH_BASE + "/authorize"
ACCESS_TOKEN_URL = AUTH_BASE + "/access_token"


def quote(s):
    # OAuth 1.0a percent-encoding: unreserved set is ALPHA / DIGIT / '-' / '.' / '_' / '~'
    return urllib.parse.quote(str(s), safe="-._~")


def sign(method, url, params, consumer_secret, token_secret=""):
    """Return the HMAC-SHA1 oauth_signature for these params."""
    # RFC 5849 3.4.1.3.2: percent-encode first, THEN sort on the encoded pairs.
    normalized = "&".join(
        f"{k}={v}" for k, v in sorted((quote(k), quote(v)) for k, v in params.items())
    )
    base = "&".join([method.upper(), quote(url), quote(normalized)])
    key = f"{quote(consumer_secret)}&{quote(token_secret)}"
    digest = hmac.new(key.encode(), base.encode(), hashlib.sha1).digest()
    import base64
    return base64.b64encode(digest).decode()


def oauth_call(url, consumer_key, consumer_secret, token=None, token_secret="",
               extra=None, raw=False, raise_on_error=True):
    """Signed GET.

    Returns the parsed form-encoded body (the OAuth endpoints), or the raw
    response string when raw=True (the REST API, which answers JSON).
    """
    params = {
        "oauth_consumer_key": consumer_key,
        "oauth_nonce": pysecrets.token_hex(16),
        "oauth_signature_method": "HMAC-SHA1",
        "oauth_timestamp": str(int(time.time())),
        "oauth_version": "1.0",
    }
    if token:
        params["oauth_token"] = token
    if extra:
        params.update(extra)

    params["oauth_signature"] = sign("GET", url, params, consumer_secret, token_secret)
    full = url + "?" + urllib.parse.urlencode(params)

    try:
        with urllib.request.urlopen(full, timeout=30) as r:
            body = r.read().decode()
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        if not raise_on_error:
            return body
        sys.exit(f"HTTP {e.code} from {url}\n{body}\n\n"
                 "If this says the IP is invalid, add this machine's public IP to the\n"
                 "app's allowlist in the FatSecret Platform dashboard.")

    if raw:
        return body

    parsed = dict(urllib.parse.parse_qsl(body))
    if not parsed:
        sys.exit(f"Unexpected response from {url}:\n{body}")
    return parsed


def load_env():
    """Credentials from the env file, overridden by the process environment.

    Returns (env, env_file_path) so the caller knows where to append the
    access token.
    """
    env = {}
    if os.path.exists(ENV_FILE):
        with open(ENV_FILE) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                k = k.strip().removeprefix("export ").strip()
                env[k] = v.strip().strip('"').strip("'")
    for k in KEYS:
        if os.environ.get(k):
            env[k] = os.environ[k]

    if "FATSECRET_CONSUMER_KEY" not in env or "FATSECRET_CONSUMER_SECRET" not in env:
        sys.exit(
            "FatSecret consumer key/secret not found.\n\n"
            f"Set them in the environment or in {ENV_FILE} (values from the\n"
            "Platform dashboard; use the OAuth 1.0 shared secret):\n"
            "  FATSECRET_CONSUMER_KEY=...\n"
            "  FATSECRET_CONSUMER_SECRET=...\n"
        )
    return env, ENV_FILE


def ask_pin(url):
    """PIN prompt. On a TTY: stdin. Otherwise (agent shell, launcher): open the
    URL on the desktop and ask through a zenity dialog, so no separate terminal
    command is ever needed."""
    if sys.stdin.isatty():
        return input("paste the PIN / verifier shown after approving: ").strip()
    import subprocess
    env = dict(os.environ, DISPLAY=os.environ.get("DISPLAY") or ":0.0")
    subprocess.Popen(["xdg-open", url], env=env,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    r = subprocess.run(
        ["zenity", "--entry", "--title=FatSecret authorization",
         "--text=Approve the FatSecret page that just opened, then paste the PIN here:",
         "--width=420"],
        env=env, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("PIN dialog cancelled")
    return r.stdout.strip()


def main():
    env, env_path = load_env()
    ck = env["FATSECRET_CONSUMER_KEY"]
    cs = env["FATSECRET_CONSUMER_SECRET"]

    if "--probe" in sys.argv:
        # exit 0 iff FatSecret hands out a request token (no dance, nothing printed but a verdict)
        body = oauth_call(REQUEST_TOKEN_URL, ck, cs, extra={"oauth_callback": "oob"},
                          raw=True, raise_on_error=False)
        ok = "oauth_token=" in body
        print("probe:", "OK" if ok else body.strip()[:80])
        sys.exit(0 if ok else 1)

    if env.get("FATSECRET_ACCESS_TOKEN"):
        print("An access token is already stored. Delete the FATSECRET_ACCESS_TOKEN /")
        print(f"FATSECRET_ACCESS_SECRET lines from {env_path} to re-authorize.")
        return

    # 1. request token (oob = PIN flow, no callback server needed)
    print("[1/3] requesting a temporary token ...")
    rt = oauth_call(REQUEST_TOKEN_URL, ck, cs, extra={"oauth_callback": "oob"})
    req_token = rt["oauth_token"]
    req_secret = rt["oauth_token_secret"]

    # 2. user authorizes in a browser, gets a PIN back
    url = f"{AUTHORIZE_URL}?oauth_token={req_token}"
    print("\n[2/3] open this in a browser, log in as yourself, and approve:\n")
    print(f"    {url}\n")
    verifier = ask_pin(url)
    if not verifier:
        sys.exit("no PIN entered")

    # 3. exchange for the long-lived access token
    print("\n[3/3] exchanging for an access token ...")
    at = oauth_call(ACCESS_TOKEN_URL, ck, cs, token=req_token,
                    extra={"oauth_verifier": verifier}, token_secret=req_secret)

    os.makedirs(os.path.dirname(env_path), exist_ok=True)
    with open(env_path, "a") as f:
        f.write(f"\nFATSECRET_ACCESS_TOKEN={at['oauth_token']}\n")
        f.write(f"FATSECRET_ACCESS_SECRET={at['oauth_token_secret']}\n")
    os.chmod(env_path, 0o600)

    print(f"\nsaved access token + secret to {env_path} (mode 600)")
    print("nothing secret was printed. next: python3 fs_log.py day")


if __name__ == "__main__":
    main()
