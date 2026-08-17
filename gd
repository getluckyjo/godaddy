#!/usr/bin/env python3
"""gd — a small GoDaddy domain CLI focused on transferring domains OUT.

Standard library only, so there is nothing to install. See README.md.

Credentials are read, in order of precedence, from:
  1. --key / --secret flags
  2. GODADDY_API_KEY / GODADDY_API_SECRET environment variables
  3. ./.env
  4. ~/.godaddy/credentials   (ini: [default] or [ote] section, key= / secret=)
"""

from __future__ import annotations

import argparse
import configparser
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone, timedelta
from pathlib import Path

PROD_HOST = "https://api.godaddy.com"
OTE_HOST = "https://api.ote-godaddy.com"

# GoDaddy documents 60 requests/minute for the domains API. Stay under it.
MIN_INTERVAL = 1.1

# ICANN locks that block a transfer away from the current registrar.
ICANN_LOCK_DAYS = 60


class ApiError(Exception):
    def __init__(self, status, body, url):
        self.status = status
        self.body = body
        self.url = url
        super().__init__(f"HTTP {status} for {url}: {body}")


# --------------------------------------------------------------------------
# credentials
# --------------------------------------------------------------------------


def _load_dotenv(path=Path(".env")):
    """Parse a .env file into a dict without overwriting the real environment."""
    values = {}
    if not path.is_file():
        return values
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        name, _, value = line.partition("=")
        value = value.strip().strip('"').strip("'")
        values[name.strip()] = value
    return values


def resolve_credentials(args):
    if args.key and args.secret:
        return args.key, args.secret, "flags"

    key = os.environ.get("GODADDY_API_KEY")
    secret = os.environ.get("GODADDY_API_SECRET")
    if key and secret:
        return key, secret, "environment"

    dotenv = _load_dotenv()
    key = dotenv.get("GODADDY_API_KEY")
    secret = dotenv.get("GODADDY_API_SECRET")
    if key and secret:
        return key, secret, "./.env"

    creds_file = Path.home() / ".godaddy" / "credentials"
    if creds_file.is_file():
        parser = configparser.ConfigParser()
        parser.read(creds_file)
        section = "ote" if args.ote else "default"
        if parser.has_section(section):
            key = parser.get(section, "key", fallback=None)
            secret = parser.get(section, "secret", fallback=None)
            if key and secret:
                return key, secret, f"{creds_file} [{section}]"

    die(
        "No API credentials found.\n\n"
        "Create a key at https://developer.godaddy.com/keys (choose Production),\n"
        "then either:\n"
        "    export GODADDY_API_KEY=...\n"
        "    export GODADDY_API_SECRET=...\n"
        "or write ~/.godaddy/credentials:\n"
        "    [default]\n"
        "    key = ...\n"
        "    secret = ...\n"
    )


# --------------------------------------------------------------------------
# http
# --------------------------------------------------------------------------


class Client:
    def __init__(self, key, secret, ote=False, shopper_id=None, verbose=False):
        self.base = OTE_HOST if ote else PROD_HOST
        self.key = key
        self.secret = secret
        self.shopper_id = shopper_id
        self.verbose = verbose
        self._last_call = 0.0

    def _throttle(self):
        elapsed = time.monotonic() - self._last_call
        if elapsed < MIN_INTERVAL:
            time.sleep(MIN_INTERVAL - elapsed)
        self._last_call = time.monotonic()

    def request(self, method, path, params=None, body=None):
        url = self.base + path
        if params:
            url += "?" + urllib.parse.urlencode(params, doseq=True)

        headers = {
            "Authorization": f"sso-key {self.key}:{self.secret}",
            "Accept": "application/json",
        }
        if self.shopper_id:
            headers["X-Shopper-Id"] = self.shopper_id

        data = None
        if body is not None:
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"

        if self.verbose:
            print(f"  → {method} {url}", file=sys.stderr)
            if body is not None:
                print(f"    {json.dumps(body)}", file=sys.stderr)

        req = urllib.request.Request(url, data=data, headers=headers, method=method)

        self._throttle()
        try:
            with urllib.request.urlopen(req, timeout=45) as resp:
                raw = resp.read().decode()
                if not raw:
                    return None
                return json.loads(raw)
        except urllib.error.HTTPError as exc:
            raw = exc.read().decode(errors="replace")
            # 429 is worth one automatic retry; everything else surfaces.
            if exc.code == 429:
                time.sleep(20)
                return self.request(method, path, params=params, body=body)
            raise ApiError(exc.code, raw.strip(), url) from None
        except urllib.error.URLError as exc:
            die(f"Could not reach {self.base}: {exc.reason}")

    # -- endpoints ---------------------------------------------------------

    def list_domains(self, statuses=None, include_nameservers=False):
        """GET /v1/domains, following the marker-based pagination."""
        out = []
        marker = None
        while True:
            params = {"limit": 100}
            if statuses:
                params["statuses"] = statuses
            if include_nameservers:
                params["includes"] = "nameServers"
            if marker:
                params["marker"] = marker
            page = self.request("GET", "/v1/domains", params=params) or []
            out.extend(page)
            if len(page) < 100:
                return out
            marker = page[-1].get("domain")
            if not marker:
                return out

    def get_domain(self, domain):
        return self.request("GET", f"/v1/domains/{urllib.parse.quote(domain)}")

    def patch_domain(self, domain, body):
        return self.request(
            "PATCH", f"/v1/domains/{urllib.parse.quote(domain)}", body=body
        )

    def get_records(self, domain):
        return self.request(
            "GET", f"/v1/domains/{urllib.parse.quote(domain)}/records"
        )


# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------


def die(message, code=1):
    print(f"error: {message}", file=sys.stderr)
    sys.exit(code)


def parse_ts(value):
    """GoDaddy returns ISO-8601 with a trailing Z or an explicit offset."""
    if not value:
        return None
    text = str(value).replace("Z", "+00:00")
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed


def days_until(when):
    if not when:
        return None
    return (when - datetime.now(timezone.utc)).days


def fmt_date(value):
    parsed = parse_ts(value)
    return parsed.strftime("%Y-%m-%d") if parsed else "-"


def yes_no(value):
    if value is True:
        return "yes"
    if value is False:
        return "no"
    return "?"


def print_table(rows, headers):
    if not rows:
        return
    widths = [len(h) for h in headers]
    for row in rows:
        for i, cell in enumerate(row):
            widths[i] = max(widths[i], len(str(cell)))
    line = "  ".join(h.ljust(widths[i]) for i, h in enumerate(headers))
    print(line)
    print("  ".join("-" * widths[i] for i in range(len(headers))))
    for row in rows:
        print("  ".join(str(c).ljust(widths[i]) for i, c in enumerate(row)))


def confirm(prompt, assume_yes):
    if assume_yes:
        return True
    try:
        answer = input(f"{prompt} [y/N] ").strip().lower()
    except EOFError:
        return False
    return answer in ("y", "yes")


# --------------------------------------------------------------------------
# commands
# --------------------------------------------------------------------------


def cmd_auth(client, args):
    """Cheapest authenticated call that proves the key works."""
    try:
        domains = client.list_domains()
    except ApiError as exc:
        if exc.status in (401, 403):
            print(f"Authentication FAILED against {client.base}")
            print(f"  HTTP {exc.status}: {exc.body}")
            print()
            print("Common causes:")
            print("  - Key was created for OTE but used against production")
            print("    (or vice versa) — try again with --ote")
            print("  - Key/secret pasted with a missing character")
            print("  - Account not eligible for the Domains API")
            return 1
        raise
    print(f"Authentication OK against {client.base}")
    print(f"  {len(domains)} domain(s) visible to this key")
    return 0


def cmd_list(client, args):
    domains = client.list_domains(
        statuses=args.status, include_nameservers=True
    )
    if not domains:
        print("No domains returned for this key.")
        return 0

    if args.json:
        print(json.dumps(domains, indent=2))
        return 0

    rows = []
    for d in sorted(domains, key=lambda x: x.get("domain", "")):
        rows.append(
            [
                d.get("domain", "?"),
                d.get("status", "?"),
                yes_no(d.get("locked")),
                yes_no(d.get("privacy")),
                fmt_date(d.get("expires")),
                yes_no(d.get("renewAuto")),
            ]
        )
    print_table(
        rows, ["DOMAIN", "STATUS", "LOCKED", "PRIVACY", "EXPIRES", "AUTORENEW"]
    )
    print(f"\n{len(rows)} domain(s)")
    return 0


def cmd_show(client, args):
    for domain in args.domains:
        detail = client.get_domain(domain)
        print(json.dumps(detail, indent=2))
    return 0


def evaluate(detail):
    """Return (verdict, blockers, warnings) for transferring this domain away.

    Blockers stop a transfer outright. Warnings are things that will bite
    during or after the transfer but do not prevent initiating it.
    """
    blockers = []
    warnings = []

    status = detail.get("status")
    if status and status != "ACTIVE":
        blockers.append(f"status is {status}, not ACTIVE")

    if detail.get("locked"):
        blockers.append("registrar lock is ON — unlock it (`gd unlock <domain>`)")

    if detail.get("transferProtected"):
        blockers.append("transferProtected is set (GoDaddy transfer lock)")

    if detail.get("holdRegistrar"):
        blockers.append("registrar HOLD is set — contact GoDaddy support")

    # GoDaddy exposes this field and it is authoritative when present:
    # it already accounts for the ICANN 60-day locks.
    eligible_at = parse_ts(detail.get("transferAwayEligibleAt"))
    if eligible_at:
        remaining = days_until(eligible_at)
        if remaining is not None and remaining > 0:
            blockers.append(
                f"not transfer-eligible until {eligible_at:%Y-%m-%d} "
                f"({remaining} day(s) away)"
            )
    else:
        # Fall back to the ICANN 60-day-after-registration rule.
        created = parse_ts(detail.get("createdAt"))
        if created:
            age = (datetime.now(timezone.utc) - created).days
            if age < ICANN_LOCK_DAYS:
                blockers.append(
                    f"registered {age} day(s) ago; ICANN blocks transfers for "
                    f"{ICANN_LOCK_DAYS} days"
                )

    expires = parse_ts(detail.get("expires"))
    if expires:
        remaining = days_until(expires)
        if remaining is not None:
            if remaining < 0:
                blockers.append(f"expired {abs(remaining)} day(s) ago")
            elif remaining < 10:
                warnings.append(
                    f"expires in {remaining} day(s) — renew before transferring, "
                    "a transfer can fail this close to expiry"
                )

    if detail.get("privacy"):
        warnings.append(
            "domain privacy is ON — the auth-code email goes to the privacy "
            "forwarding address; turn privacy off if you do not receive it"
        )

    registrant = detail.get("contactRegistrant") or {}
    email = registrant.get("email")
    if email:
        warnings.append(f"auth code will be emailed to registrant: {email}")
    else:
        warnings.append("no registrant email visible on this key — verify in the UI")

    nameservers = detail.get("nameServers") or []
    if nameservers:
        warnings.append(
            "back up DNS before transferring (`gd records "
            f"{detail.get('domain')}`) — NS: {', '.join(nameservers[:4])}"
        )

    verdict = "BLOCKED" if blockers else "READY"
    return verdict, blockers, warnings


def cmd_preflight(client, args):
    """The main event: is each domain actually transferable right now?"""
    domains = args.domains
    if not domains:
        print("No domains given, checking every domain on the account...\n")
        domains = [d["domain"] for d in client.list_domains() if d.get("domain")]
        if not domains:
            print("No domains found.")
            return 0

    results = []
    for domain in domains:
        try:
            detail = client.get_domain(domain)
        except ApiError as exc:
            if exc.status == 404:
                print(f"{domain}: NOT FOUND on this account\n")
                results.append((domain, "NOT FOUND"))
                continue
            raise

        verdict, blockers, warnings = evaluate(detail)
        results.append((domain, verdict))

        marker = "✓" if verdict == "READY" else "✗"
        print(f"{marker} {domain} — {verdict}")
        print(
            f"    status={detail.get('status')} "
            f"locked={yes_no(detail.get('locked'))} "
            f"privacy={yes_no(detail.get('privacy'))} "
            f"expires={fmt_date(detail.get('expires'))}"
        )
        if detail.get("transferAwayEligibleAt"):
            print(
                "    transferAwayEligibleAt="
                f"{fmt_date(detail.get('transferAwayEligibleAt'))}"
            )
        # Report, rather than assume, whether this account's API exposes the code.
        if detail.get("authCode"):
            print("    authCode: PRESENT in the API response (see `gd authcode`)")
        for blocker in blockers:
            print(f"    BLOCKER: {blocker}")
        for warning in warnings:
            print(f"    note:    {warning}")
        print()

    ready = [d for d, v in results if v == "READY"]
    blocked = [d for d, v in results if v != "READY"]
    print(f"Summary: {len(ready)} ready, {len(blocked)} blocked")
    if blocked:
        print(f"  blocked: {', '.join(blocked)}")
    return 0


def cmd_unlock(client, args):
    return _set_lock(client, args, locked=False)


def cmd_lock(client, args):
    return _set_lock(client, args, locked=True)


def _set_lock(client, args, locked):
    verb = "Lock" if locked else "Unlock"
    print(f"{verb} the following domain(s) on {client.base}:")
    for domain in args.domains:
        print(f"  - {domain}")
    if not confirm(f"{verb} {len(args.domains)} domain(s)?", args.yes):
        print("Aborted.")
        return 1

    failures = 0
    for domain in args.domains:
        try:
            client.patch_domain(domain, {"locked": locked})
        except ApiError as exc:
            failures += 1
            print(f"  {domain}: FAILED — HTTP {exc.status}: {exc.body}")
            continue
        detail = client.get_domain(domain)
        actual = detail.get("locked")
        if actual is locked:
            print(f"  {domain}: locked={yes_no(actual)} ✓")
        else:
            failures += 1
            print(
                f"  {domain}: request accepted but locked={yes_no(actual)} "
                "— GoDaddy may still be applying the change, re-check shortly"
            )
    return 1 if failures else 0


def cmd_authcode(client, args):
    """GoDaddy's public API does not document an auth-code endpoint.

    Rather than guess, read the domain detail and report what is actually
    there for this account.
    """
    any_found = False
    for domain in args.domains:
        detail = client.get_domain(domain)
        code = detail.get("authCode")
        if code:
            any_found = True
            print(f"{domain}: {code}")
        else:
            print(f"{domain}: no authCode field in the API response")

    if not any_found:
        print()
        print("The API did not return an auth code. Get it from the web UI:")
        print("  1. https://dcc.godaddy.com/control/portfolio")
        print("  2. Select the domain → Domain Settings")
        print("  3. Additional Settings → Transfer domain away from GoDaddy")
        print("  4. 'Get authorization code' — it is emailed to the registrant")
        print()
        print("Unlock first (`gd unlock <domain>`); the option is hidden while locked.")
        return 2
    return 0


def cmd_records(client, args):
    """Snapshot DNS before transferring — records are easy to lose."""
    for domain in args.domains:
        try:
            records = client.get_records(domain)
        except ApiError as exc:
            if exc.status in (404, 422):
                print(
                    f"{domain}: no GoDaddy-hosted zone "
                    f"(HTTP {exc.status}) — DNS is likely hosted elsewhere; "
                    "check the nameservers in `gd show`"
                )
                continue
            raise

        if args.out:
            out_dir = Path(args.out)
            out_dir.mkdir(parents=True, exist_ok=True)
            path = out_dir / f"{domain}.records.json"
            path.write_text(json.dumps(records, indent=2) + "\n")
            print(f"{domain}: {len(records)} record(s) → {path}")
            continue

        if args.json:
            print(json.dumps(records, indent=2))
            continue

        print(f"\n{domain} — {len(records)} record(s)")
        rows = [
            [
                r.get("type", "?"),
                r.get("name", "?"),
                str(r.get("data", ""))[:60],
                r.get("ttl", "-"),
                r.get("priority", "-") if r.get("priority") is not None else "-",
            ]
            for r in records
        ]
        print_table(rows, ["TYPE", "NAME", "DATA", "TTL", "PRIO"])
    return 0


def cmd_backup(client, args):
    """One command to run before you start: everything, saved to disk."""
    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    domains = args.domains
    if not domains:
        domains = [d["domain"] for d in client.list_domains() if d.get("domain")]

    manifest = []
    for domain in domains:
        entry = {"domain": domain}
        try:
            entry["detail"] = client.get_domain(domain)
        except ApiError as exc:
            entry["detail_error"] = f"HTTP {exc.status}: {exc.body}"
        try:
            entry["records"] = client.get_records(domain)
        except ApiError as exc:
            entry["records_error"] = f"HTTP {exc.status}: {exc.body}"

        path = out_dir / f"{domain}.json"
        path.write_text(json.dumps(entry, indent=2) + "\n")
        records = entry.get("records") or []
        print(f"  {domain}: saved ({len(records)} DNS record(s)) → {path}")
        manifest.append(domain)

    index = out_dir / "index.json"
    index.write_text(
        json.dumps(
            {
                "host": client.base,
                "saved_at": datetime.now(timezone.utc).isoformat(),
                "domains": manifest,
            },
            indent=2,
        )
        + "\n"
    )
    print(f"\n{len(manifest)} domain(s) backed up to {out_dir}/")
    print("Keep this until the transfer completes and DNS is verified at the new host.")
    return 0


# --------------------------------------------------------------------------
# cli
# --------------------------------------------------------------------------


def build_parser():
    parser = argparse.ArgumentParser(
        prog="gd",
        description="GoDaddy domain CLI, focused on transferring domains out.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "typical transfer-out run:\n"
            "  gd auth                      # confirm the key works\n"
            "  gd list                      # see what is on the account\n"
            "  gd backup -o ./backup        # snapshot details + DNS first\n"
            "  gd preflight a.com b.com     # what blocks each transfer\n"
            "  gd unlock a.com b.com        # clear the registrar lock\n"
            "  gd authcode a.com            # try the API, else UI steps\n"
        ),
    )
    parser.add_argument("--key", help="API key (overrides env/files)")
    parser.add_argument("--secret", help="API secret (overrides env/files)")
    parser.add_argument(
        "--ote",
        action="store_true",
        help="use the OTE test environment instead of production",
    )
    parser.add_argument(
        "--shopper-id", help="X-Shopper-Id header, for reseller/subaccounts"
    )
    parser.add_argument(
        "-v", "--verbose", action="store_true", help="log each HTTP request"
    )
    parser.add_argument(
        "-y", "--yes", action="store_true", help="skip confirmation prompts"
    )

    subs = parser.add_subparsers(dest="command", required=True)

    sub = subs.add_parser("auth", help="verify credentials")
    sub.set_defaults(func=cmd_auth)

    sub = subs.add_parser("list", help="list domains on the account")
    sub.add_argument("--status", help="filter by status, e.g. ACTIVE")
    sub.add_argument("--json", action="store_true", help="raw JSON output")
    sub.set_defaults(func=cmd_list)

    sub = subs.add_parser("show", help="full API detail for a domain")
    sub.add_argument("domains", nargs="+")
    sub.set_defaults(func=cmd_show)

    sub = subs.add_parser(
        "preflight", help="check what blocks a transfer away (default: all domains)"
    )
    sub.add_argument("domains", nargs="*")
    sub.set_defaults(func=cmd_preflight)

    sub = subs.add_parser("unlock", help="turn the registrar lock OFF")
    sub.add_argument("domains", nargs="+")
    sub.set_defaults(func=cmd_unlock)

    sub = subs.add_parser("lock", help="turn the registrar lock ON")
    sub.add_argument("domains", nargs="+")
    sub.set_defaults(func=cmd_lock)

    sub = subs.add_parser("authcode", help="attempt to read the EPP/auth code")
    sub.add_argument("domains", nargs="+")
    sub.set_defaults(func=cmd_authcode)

    sub = subs.add_parser("records", help="show or save DNS records")
    sub.add_argument("domains", nargs="+")
    sub.add_argument("--json", action="store_true", help="raw JSON output")
    sub.add_argument("-o", "--out", help="write <domain>.records.json into this dir")
    sub.set_defaults(func=cmd_records)

    sub = subs.add_parser(
        "backup", help="save domain details + DNS for every domain (do this first)"
    )
    sub.add_argument("domains", nargs="*")
    sub.add_argument("-o", "--out", default="./godaddy-backup", help="output directory")
    sub.set_defaults(func=cmd_backup)

    return parser


def main(argv=None):
    args = build_parser().parse_args(argv)
    key, secret, source = resolve_credentials(args)
    if args.verbose:
        print(f"  credentials from {source}", file=sys.stderr)

    client = Client(
        key,
        secret,
        ote=args.ote,
        shopper_id=args.shopper_id,
        verbose=args.verbose,
    )
    try:
        return args.func(client, args)
    except ApiError as exc:
        die(f"HTTP {exc.status} from {exc.url}\n       {exc.body}")
    except KeyboardInterrupt:
        print("\nInterrupted.", file=sys.stderr)
        return 130


if __name__ == "__main__":
    sys.exit(main() or 0)
