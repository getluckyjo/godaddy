# gd — GoDaddy transfer-out CLI

A single-file Python CLI for auditing GoDaddy domains and clearing the blockers
that stop them transferring to another registrar. Standard library only —
nothing to install.

```
gd auth                      # confirm the key works
gd list                      # what's on the account
gd backup -o ./backup        # snapshot details + DNS  ← do this first
gd preflight a.com b.com     # what blocks each transfer
gd unlock a.com b.com        # clear the registrar lock
gd authcode a.com            # try the API, else print the UI steps
gd records a.com             # DNS records, so you can rebuild the zone
```

> **Transferring a `.co.za`?** Skip the unlock and auth-code steps entirely —
> `.za` runs on a registry email vote instead. See
> [.co.za and other .za domains](#coza-and-other-za-domains--a-different-process).

## Setup

**1. Create an API key** at <https://developer.godaddy.com/keys>.

Choose **Production**, not OTE. OTE is a sandbox with its own fake data — a key
from one environment returns 401/403 against the other. (`gd --ote` targets the
sandbox if you want to rehearse.)

As of April 2026 GoDaddy lowered the Domains API threshold to **1 domain** in
the account; it used to require 10+ domains or a Discount Domain Club Premier
plan. If you get a 403 saying you're not eligible, that's the gate — check
<https://www.godaddy.com/help/how-do-i-access-domain-related-apis-42424>.

**2. Give the CLI the credentials.** Either environment variables:

```bash
export GODADDY_API_KEY=...
export GODADDY_API_SECRET=...
```

or `~/.godaddy/credentials`, which keeps them out of your shell history:

```ini
[default]
key = ...
secret = ...

[ote]
key = ...
secret = ...
```

or copy `.env.example` to `.env` (gitignored).

**3. Verify:**

```bash
./gd auth
```

## Transfer-out runbook

The thing most people get wrong: **you do not start a transfer at GoDaddy.**
You start it at the registrar you're moving *to*, and GoDaddy's only job is to
release the domain. GoDaddy's API covers the release side (lock, DNS, status);
it does not initiate transfers.

### Before you touch anything

```bash
./gd backup -o ./backup
```

This saves each domain's full API detail plus its DNS records. Transferring the
registration does **not** carry your DNS zone with it — if GoDaddy is currently
answering DNS for the domain, those records stop existing once the domain
leaves. Keep this backup until the new host is serving DNS correctly.

### 1. Check eligibility

```bash
./gd preflight              # all domains
./gd preflight a.com b.com  # or just these
```

`preflight` reports a `READY`/`BLOCKED` verdict per domain and separates hard
blockers from things that will bite you later. It checks:

| Check | Why it blocks |
| --- | --- |
| `status != ACTIVE` | expired, pending delete, or in redemption |
| registrar lock on | the standard transfer lock |
| `transferProtected` | GoDaddy's own transfer lock |
| `holdRegistrar` | registrar hold — needs GoDaddy support |
| `transferAwayEligibleAt` in the future | ICANN 60-day locks (see below) |
| expired | can't transfer an expired domain |

ICANN imposes a **60-day lock** after a new registration, after a previous
transfer, and after a change of registrant contact. GoDaddy exposes
`transferAwayEligibleAt`, which already accounts for these, so `gd preflight`
trusts that field when it's present and falls back to computing 60 days from
`createdAt` when it isn't.

Near-expiry is reported as a warning, not a blocker: a transfer usually adds a
year at the new registrar, but starting one within a few days of expiry risks
the transfer failing *and* the domain lapsing. Renew first if you're inside ~10
days.

### 2. Move DNS before you move the registration

If the domain uses GoDaddy nameservers and you care about uptime, do this in
order — not after the transfer:

```bash
./gd records a.com            # read the current zone
```

1. Recreate those records at the new DNS provider.
2. Point the domain's nameservers at the new provider and confirm resolution.
3. Only then start the registrar transfer.

Watch for records that are really *services*: `MX` records for GoDaddy-hosted
or Microsoft 365 email bought through GoDaddy, and any `TXT` records for SPF,
DKIM, or domain verification. Email tied to the GoDaddy account doesn't move
with the domain — plan that separately or you'll drop mail.

### 3. Unlock

```bash
./gd unlock a.com b.com
```

This `PATCH`es `{"locked": false}` and then re-reads the domain to confirm it
actually took. It prompts before changing anything; `-y` skips the prompt.

### 4. Get the auth code (EPP code)

```bash
./gd authcode a.com
```

GoDaddy's public API does not document an auth-code endpoint. Rather than
guessing, `gd authcode` reads the domain detail, prints an `authCode` if your
account's API returns one, and otherwise prints the UI steps:

1. <https://dcc.godaddy.com/control/portfolio>
2. Select the domain → **Domain Settings**
3. **Additional Settings** → **Transfer domain away from GoDaddy**
4. **Get authorization code** — GoDaddy emails it to the registrant

Unlock first; the option is hidden while the domain is locked. If domain privacy
is on, the email goes to the privacy forwarding address — `gd preflight` flags
this, and turning privacy off is the fix if it doesn't arrive.

### 5. Start the transfer at the new registrar

Enter the domain and auth code at the gaining registrar and pay for the
transfer year. Then, back at GoDaddy, approve the outbound transfer to skip the
wait — ICANN otherwise allows the losing registrar up to **5 days** before the
transfer auto-completes.

### 6. Verify

```bash
./gd list                     # the domain should disappear once it's gone
dig +short a.com NS           # nameservers answering from the new provider
```

Compare live DNS against `./backup/a.com.json` record by record before you
consider it done.

## .co.za and other .za domains — a different process

**Everything in the runbook above about unlocking and auth codes does not apply
to `.co.za`, `.net.za`, or `.org.za`.** These are run by ZACR under South
African policy, not ICANN gTLD policy, and the transfer works on a registry
email vote instead:

| | gTLD (`.com`) | `.za` |
| --- | --- | --- |
| Registrar unlock | required | not required |
| Auth / EPP code | required | **not used** |
| 60-day lock after registration or transfer | yes | disputed — see below |
| How it's authorised | auth code at the gaining registrar | registry emails the WHOIS contacts an approve/deny link |
| Timeline | up to 5 days, or approve to speed it up | immediate on approval; **fails** after 5 days with no reply |

The process:

1. Start the transfer at the **gaining registrar**. Nothing to prepare at
   GoDaddy — no unlock, no code.
2. ZACR emails an approve/deny link to the domain's WHOIS contacts (owner,
   admin, tech, billing).
3. One **APPROVE** processes the transfer immediately. Any **DENY** fails it.
   **No response fails it after 5 days.**

Two consequences worth taking seriously:

- **The contact email addresses are the whole mechanism.** A stale address means
  the vote email goes nowhere and the transfer silently fails after 5 days.
  Check and fix them in GoDaddy *before* starting.
- **Never leave the registrant email on the domain being moved.** If it's
  `you@yourdomain.co.za` and mail breaks during the DNS migration, you can't
  approve the transfer. `gd preflight` flags this explicitly.

### The 60-day question

Sources genuinely conflict here, so treat it as unresolved rather than settled.
Registry-side documentation (ZARC, and registrars publishing .ZA policy such as
OpenSRS) states there is **no** 60-day lock after registration or transfer for
`.za`. But some registrars' own knowledge bases — including Domains.co.za's —
state a domain must have been registered for at least 60 days before they will
accept a transfer in.

Two separate things are probably being conflated: ICANN's 60-day gTLD lock,
which does not apply to `.za`, and individual registrars' own intake policies,
which do. Separately, Domains.co.za launched an **optional** registrar-level
Domain Transfer Lock for `.co.za` in April 2025 — an opt-in security feature,
not a registry-imposed waiting period.

Practical takeaway: if the domain was registered, transferred, or had its
registrant contact changed in the last 60 days, confirm with the *gaining*
registrar before relying on it. Otherwise the question is moot. `gd preflight`
does not apply an ICANN-style 60-day block to `.za`, but it still respects
GoDaddy's own `transferAwayEligibleAt` when that field is set.

### Exceptions

If the gaining registrar is **Hexonet (1API GmbH)** or one of their resellers,
they do want an auth code, which you have to request from GoDaddy support — it
isn't in the self-service UI. Registrars that are directly ZACR-accredited
(Domains.co.za, xneelo, Afrihost) go through the email vote with no code.

Also check your destination registrar actually supports `.za` before you start.
Many international registrars don't. Cloudflare Registrar is the notable one —
`.co.za` is not on its supported list and the feature request has sat open since
2024, so plan on a ZACR-accredited or South African registrar instead.

`gd preflight` applies all of this automatically for any `.za` domain: the
registrar lock drops to a warning, the ICANN 60-day check is skipped, and the
email-vote requirements are surfaced instead.

## Command reference

| Command | Purpose |
| --- | --- |
| `gd auth` | verify credentials, report a 401/403 with likely causes |
| `gd list [--status ACTIVE] [--json]` | domains with status, lock, privacy, expiry |
| `gd show <domain>...` | raw API detail as JSON |
| `gd preflight [<domain>...]` | transfer-out readiness (gTLD and `.za` rules); all domains by default |
| `gd unlock <domain>...` | registrar lock off (confirms, then verifies) |
| `gd lock <domain>...` | registrar lock on |
| `gd authcode <domain>...` | read the auth code if exposed, else UI steps |
| `gd records <domain>... [-o dir]` | DNS records, printed or saved as JSON |
| `gd backup [<domain>...] [-o dir]` | full detail + DNS for every domain |

Global flags: `--ote` (sandbox), `--shopper-id` (reseller/subaccounts),
`-v` (log every HTTP request), `-y` (skip confirmations),
`--key`/`--secret` (override credential lookup).

Requests are throttled to stay under GoDaddy's documented 60 requests/minute,
and a 429 is retried once after a pause.

## Tests

```bash
python3 test_gd.py
```

36 tests. The eligibility logic is tested directly against synthetic API
payloads, and the HTTP layer (auth header, marker pagination, `PATCH`, error
mapping, backup output) runs against a local stub server — so the suite needs
no credentials and no network.

## Note on this repo's origin

This CLI was written in a sandboxed environment whose egress policy **403s
`api.godaddy.com`, `api.ote-godaddy.com`, and `developer.godaddy.com`**. Nothing
here has been run against the live API. The endpoints used are the stable,
long-documented v1 ones, and the code is deliberately built to *report* what
the API returns rather than assume it — `gd authcode` and the `authCode` line in
`gd preflight` exist precisely because auth-code availability could not be
verified from here. Run `gd auth` then `gd preflight` on your machine first;
`-v` will show you every request.
