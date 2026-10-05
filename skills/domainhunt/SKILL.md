---
name: domainhunt
description: Check whether domains are available and sweep thousands of candidate names at once, without being fooled by a rate-limited checker. Use when the user says /domainhunt, "find a domain", "is that domain taken", "check if X.com is free", "what names are available", "sweep for names", "what else is available", "how much is that domain", "is that TLD expensive", or asks you to name a product or service. Also use before telling the user a domain is available or that a name is a good one.
---
<!-- needs: bash, curl, dig (dnsutils/bind-utils), python3 for run_bank.sh. No accounts, no hardware. -->
<!-- pricing lookups use Porkbun's public, unauthenticated pricing API. Registering is never automated. -->

# Domain hunting

Two jobs, and the second is the one that goes wrong: **find candidates**, and **not lie about
whether they are free**. Every instrument here fails toward *false available* when throttled,
so a sweep that reports thousands of free names is the expected output of a broken run.

Scripts live in `scripts/` next to this file. They need only `curl`, `dig` and bash.

## The instrument rule: this is the whole skill

**Test a known positive BEFORE and AFTER every batch.** Before-only is not enough: the
throttle arrives *during* the run.

- `./scripts/w.sh google.com` must say `TAKEN`; `./scripts/w.sh zzqxjfkdlqp123.com` must say `FREE`.
- `./scripts/ns2.sh google.com` must print **nothing**; the nonsense name must print.
- If the after-test fails, **the whole batch is void**. Do not salvage part of it.

What this caught, so it is not re-learned at cost:

- `dig` at `-P 40` over 95,000 names: the resolver throttled and returned **empty for
  everything**, which reads as *no nameservers* = available. All 95k were garbage.
- WHOIS run *concurrently with* a big `dig` sweep returned false `No match`. A 40-name random
  sample of "free" survivors was **40/40 actually registered**: `fluids.com`, `aussie.com`,
  `bourse.com`. Serial re-checks said `TAKEN`.
- Verisign RDAP at `-P 5` returned HTTP `000` for **every** name *including google.com*. **A
  registry block is indistinguishable from an outage.**
- `rdap.org` (the bootstrap aggregator) returned **404 for everything**, including `github.io`.
  Never use it. Go to the registry directly.

## Pipeline by size

| names | method |
|---|---|
| < 500 | WHOIS direct, `-P 3`, no prefilter. ~30 s. Safest |
| 500 – 25,000 | `dig NS` prefilter `-P 20` → WHOIS `-P 3` on survivors |
| > 25,000 | don't. Split it. The prefilter throttles and the run is void |

`./scripts/run_bank.sh <wordsfile> <prefix>` does the whole middle row: crosses the words
against a join list (`JOIN="fix hop desk"` in the environment; your product's short stems) in
both orders, dedupes against `allchecked.txt`, prefilters, confirms, and self-tests at both ends.
It **exits non-zero and prints VOID** when a self-test fails, so a script can gate on it. Keep a cumulative `allchecked.txt` of every
candidate ever generated: re-learning that `fixatom` is taken is pure waste.

## The instruments

- **`ns2.sh <domain>`**: prefilter. Prints the domain only if **no nameservers** on 1.1.1.1,
  then 8.8.8.8, then 9.9.9.9. An unregistered domain cannot have NS, so this has no false
  *negatives*: only false positives, which the confirm step catches.
- **`w.sh <domain>`**: WHOIS port 43 at whois.verisign-grs.com. **Bash's `/dev/tcp` does
  not reliably resolve hostnames**, so the script resolves the IP first with `getent` and
  connects to that. `.com`/`.net` only.
  `No match for` = FREE, `Domain Name:` = TAKEN, anything else = retry then UNKNOWN.
- **`conf.sh <domain>`**: RDAP at Verisign. `404` = FREE, `200` = TAKEN. Second instrument;
  blocks above `-P 4`.
- **`multi.sh <domain>`**: other TLDs, registry-direct endpoints. Refresh the table from
  `https://data.iana.org/rdap/dns.json`. `.us` = whois `whois.nic.us`, answers
  `No Data Found`. **`.co` has no working RDAP endpoint**: report it as unchecked, never guess.

**Two instruments before you recommend anything.** RDAP and WHOIS are independent; make both
say FREE, serially, on the day the user might buy.

## The five acceptance checks: run them BEFORE presenting a name

A free domain is not a usable name. In an industry scammers impersonate (remote IT support,
for example) a bad name is a liability.

1. **Reversal.** For `fixX`, check `Xfix`. Is it registered? Does it *serve* anything?
   `curl -sL` it and read the `<title>`.
2. **Live product with that name.** One WebSearch for the exact compound. This caught
   **WarpFix** (live, selling, $12/mo, warpfix.org), **Warpgate** (7.4k-star SSH/RDP bastion, the same
   category), **VoidFix** (live IT company), **CalmPC** (live PC health checker),
   **SteadyFix** (phone repair shop), **Hopgate** (indie-games platform), **Parsec** (remote
   desktop). All would have shipped without this check.
3. **`.net` / `.org` flanks**: cheap to know, and owning the pair kills the reversal problem.
4. **Typo-adjacency to a competitor.** Edit distance ≤2 to a competitor's name = **reject**.
   For remote desktop that list was anydesk, teamviewer, splashtop, hoptodesk, rustdesk,
   logmein, gotomypc, simplehelp, getscreen, quickassist.
   `jumptodesk`/`poptodesk` are free *because* they are HopToDesk lures.
5. **Is either half a household brand?** This is the one that kills good-looking names:
   `fixcalm`→Calm the app, `fixcomet`→Comet the scouring powder, `hereassist`→Here2Assist®
   (Takeda). Say the name out loud as *"go to ___ dot com"* and listen for the other brand.

## Pricing: measure, never estimate

Porkbun's pricing API is public and unauthenticated:
`curl -s -X POST https://api.porkbun.com/api/json/v3/pricing/get`

Measured 2026-09-22: **`.com` $11.08** reg and renew · `.io` **$28.12 then $51.80/yr** ·
`.co` $31.20 renew · `.tech` $50.98 · `.support` $22.14 · `.help`/`.live` $26.26 ·
`.app` $14.93 · `.dev` $12.87 · `.net` $12.52 · `.org` $11.84 · `.cc` $8.55 · `.link` $7.72 ·
`.us` $7.00 · `.fyi` $5.66.

**`.com` undercuts almost every alternative TLD's renewal**, so a longer `.com` beats a short
anything-else on both price and trust. Quote the **renewal**, not the first year. Per-domain
premium pricing needs a registrar API key: say so rather than guessing.

`.app`, `.dev` and `.page` are **HSTS-preloaded** (verify at
`https://hstspreload.org/api/v2/status?domain=app`): browsers refuse plain HTTP and **there is
no click-through on a bad cert**: which removes the safety net on a self-signed migration.

## Keep a record of what is exhausted

Keep `allchecked.txt` and a short list of **dead shapes** per project, so a later session does
not re-sweep them. From one 52,000-name, 18-sweep hunt for a remote-support product name
(September 2026), as an example of what that list looks like: single English words of 4–7
letters, two words ≤8 chars with any meaning, stem+suffix (`-ly` `-ify` `-io` …), letter or
number + word (`ifix`, `4fix`), and 8–9-letter single words (2 of 63 free) were all dead.
Still alive: `fix` + an uncommon concrete noun at 8–10 chars, verb + fault word, and **3-word
phrases** in the user's voice (944 of 1,243 free in one sweep).

## Never buy on an inferred go-ahead

Registering costs money and cannot be undone. Picking a favourite is not authorisation:
the user has to say *buy*.
