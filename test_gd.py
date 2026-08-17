#!/usr/bin/env python3
"""Tests for gd.

The GoDaddy API is not reachable from CI, so the HTTP layer is exercised
against a local stub server that mimics the endpoints gd uses. Run with:

    python3 test_gd.py
"""

import importlib.util
import json
import threading
import unittest
import urllib.parse
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

# gd has no .py extension, so load it by path.
_spec = importlib.util.spec_from_loader(
    "gd",
    importlib.machinery.SourceFileLoader("gd", str(Path(__file__).parent / "gd")),
)
gd = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(gd)

# Keep the tests fast; the throttle only matters against the real API.
gd.MIN_INTERVAL = 0


def iso(days_from_now):
    when = datetime.now(timezone.utc) + timedelta(days=days_from_now)
    return when.strftime("%Y-%m-%dT%H:%M:%SZ")


class TestTimeParsing(unittest.TestCase):
    def test_parses_trailing_z(self):
        parsed = gd.parse_ts("2026-03-04T05:06:07Z")
        self.assertEqual(parsed.year, 2026)
        self.assertEqual(parsed.tzinfo, timezone.utc)

    def test_parses_explicit_offset(self):
        self.assertIsNotNone(gd.parse_ts("2026-03-04T05:06:07+02:00"))

    def test_handles_junk_and_empty(self):
        self.assertIsNone(gd.parse_ts(None))
        self.assertIsNone(gd.parse_ts(""))
        self.assertIsNone(gd.parse_ts("not a date"))


class TestEvaluate(unittest.TestCase):
    """evaluate() decides whether a domain can leave GoDaddy today."""

    def base_domain(self, **overrides):
        detail = {
            "domain": "example.com",
            "status": "ACTIVE",
            "locked": False,
            "privacy": False,
            "createdAt": iso(-400),
            "expires": iso(200),
            "transferAwayEligibleAt": iso(-1),
            "contactRegistrant": {"email": "owner@example.com"},
            "nameServers": ["ns1.godaddy.com"],
        }
        detail.update(overrides)
        return detail

    def test_clean_domain_is_ready(self):
        verdict, blockers, _ = gd.evaluate(self.base_domain())
        self.assertEqual(verdict, "READY")
        self.assertEqual(blockers, [])

    def test_registrar_lock_blocks(self):
        verdict, blockers, _ = gd.evaluate(self.base_domain(locked=True))
        self.assertEqual(verdict, "BLOCKED")
        self.assertTrue(any("lock" in b for b in blockers))

    def test_future_eligibility_blocks(self):
        verdict, blockers, _ = gd.evaluate(
            self.base_domain(transferAwayEligibleAt=iso(30))
        )
        self.assertEqual(verdict, "BLOCKED")
        self.assertTrue(any("transfer-eligible" in b for b in blockers))

    def test_new_registration_blocks_when_field_absent(self):
        """Without transferAwayEligibleAt, fall back to the ICANN 60-day rule."""
        detail = self.base_domain(createdAt=iso(-10))
        detail.pop("transferAwayEligibleAt")
        verdict, blockers, _ = gd.evaluate(detail)
        self.assertEqual(verdict, "BLOCKED")
        self.assertTrue(any("ICANN" in b for b in blockers))

    def test_old_registration_passes_when_field_absent(self):
        detail = self.base_domain(createdAt=iso(-400))
        detail.pop("transferAwayEligibleAt")
        verdict, blockers, _ = gd.evaluate(detail)
        self.assertEqual(verdict, "READY")
        self.assertEqual(blockers, [])

    def test_non_active_status_blocks(self):
        _, blockers, _ = gd.evaluate(self.base_domain(status="PENDING_DELETE"))
        self.assertTrue(any("PENDING_DELETE" in b for b in blockers))

    def test_expired_domain_blocks(self):
        _, blockers, _ = gd.evaluate(self.base_domain(expires=iso(-5)))
        self.assertTrue(any("expired" in b for b in blockers))

    def test_near_expiry_warns_but_does_not_block(self):
        verdict, blockers, warnings = gd.evaluate(self.base_domain(expires=iso(3)))
        self.assertEqual(verdict, "READY")
        self.assertEqual(blockers, [])
        self.assertTrue(any("expires in" in w for w in warnings))

    def test_transfer_protected_and_hold_block(self):
        _, blockers, _ = gd.evaluate(
            self.base_domain(transferProtected=True, holdRegistrar=True)
        )
        self.assertTrue(any("transferProtected" in b for b in blockers))
        self.assertTrue(any("HOLD" in b for b in blockers))

    def test_privacy_warns(self):
        _, _, warnings = gd.evaluate(self.base_domain(privacy=True))
        self.assertTrue(any("privacy" in w for w in warnings))

    def test_registrant_email_surfaced(self):
        _, _, warnings = gd.evaluate(self.base_domain())
        self.assertTrue(any("owner@example.com" in w for w in warnings))

    def test_missing_fields_do_not_crash(self):
        verdict, _, _ = gd.evaluate({"domain": "sparse.com"})
        self.assertIn(verdict, ("READY", "BLOCKED"))


class TestZaDomains(unittest.TestCase):
    """.za follows ZACR policy: no unlock, no auth code, no 60-day lock."""

    def base_za(self, domain="example.co.za", **overrides):
        detail = {
            "domain": domain,
            "status": "ACTIVE",
            "locked": False,
            "privacy": False,
            "createdAt": iso(-400),
            "expires": iso(200),
            "contactRegistrant": {"email": "owner@elsewhere.com"},
        }
        detail.update(overrides)
        return detail

    def test_suffix_detection(self):
        for name in ("a.co.za", "a.net.za", "a.org.za", "A.CO.ZA", "a.co.za."):
            self.assertTrue(gd.is_za(name), name)
        for name in ("a.com", "a.za.com", "coza.com", ""):
            self.assertFalse(gd.is_za(name), name)

    def test_lock_is_a_warning_not_a_blocker(self):
        verdict, blockers, warnings = gd.evaluate(self.base_za(locked=True))
        self.assertEqual(verdict, "READY")
        self.assertEqual(blockers, [])
        self.assertTrue(any("do not require an unlock" in w for w in warnings))

    def test_lock_still_blocks_a_gtld(self):
        """Guard against the .za carve-out leaking into gTLD handling."""
        _, blockers, _ = gd.evaluate(
            {"domain": "example.com", "status": "ACTIVE", "locked": True}
        )
        self.assertTrue(any("unlock it" in b for b in blockers))

    def test_no_icann_lock_for_new_za_registration(self):
        detail = self.base_za(createdAt=iso(-3))
        verdict, blockers, _ = gd.evaluate(detail)
        self.assertEqual(verdict, "READY")
        self.assertEqual(blockers, [])

    def test_icann_lock_still_applies_to_new_gtld(self):
        _, blockers, _ = gd.evaluate(
            {"domain": "example.com", "status": "ACTIVE", "createdAt": iso(-3)}
        )
        self.assertTrue(any("ICANN" in b for b in blockers))

    def test_explains_the_email_vote(self):
        _, _, warnings = gd.evaluate(self.base_za())
        self.assertTrue(any("no auth code" in w for w in warnings))
        self.assertTrue(any("5 days" in w for w in warnings))

    def test_flags_registrant_email_on_the_domain_itself(self):
        detail = self.base_za(
            contactRegistrant={"email": "admin@example.co.za"}
        )
        _, _, warnings = gd.evaluate(detail)
        self.assertTrue(any("at example.co.za itself" in w for w in warnings))

    def test_off_domain_registrant_email_not_flagged(self):
        _, _, warnings = gd.evaluate(self.base_za())
        self.assertFalse(any("itself" in w for w in warnings))

    def test_missing_registrant_email_warns(self):
        detail = self.base_za()
        detail.pop("contactRegistrant")
        _, _, warnings = gd.evaluate(detail)
        self.assertTrue(any("silently fails" in w for w in warnings))

    def test_real_blockers_still_apply_to_za(self):
        _, blockers, _ = gd.evaluate(
            self.base_za(status="PENDING_DELETE", expires=iso(-5), holdRegistrar=True)
        )
        self.assertTrue(any("PENDING_DELETE" in b for b in blockers))
        self.assertTrue(any("expired" in b for b in blockers))
        self.assertTrue(any("HOLD" in b for b in blockers))

    def test_godaddy_eligibility_date_still_respected_for_za(self):
        _, blockers, _ = gd.evaluate(
            self.base_za(transferAwayEligibleAt=iso(20))
        )
        self.assertTrue(any("transfer-eligible" in b for b in blockers))


# ---------------------------------------------------------------------------
# stub server, to exercise the HTTP layer
# ---------------------------------------------------------------------------

STATE = {}


class StubHandler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def _send(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        STATE.setdefault("auth_headers", []).append(
            self.headers.get("Authorization")
        )
        STATE.setdefault("shopper_headers", []).append(
            self.headers.get("X-Shopper-Id")
        )
        parsed = urllib.parse.urlparse(self.path)
        query = urllib.parse.parse_qs(parsed.query)

        if parsed.path == "/v1/domains":
            # Two pages of 100 to prove pagination works.
            marker = query.get("marker", [None])[0]
            if marker is None:
                page = [
                    {"domain": f"d{i:03d}.com", "status": "ACTIVE", "locked": False}
                    for i in range(100)
                ]
            elif marker == "d099.com":
                page = [{"domain": "last.com", "status": "ACTIVE", "locked": False}]
            else:
                page = []
            STATE.setdefault("markers", []).append(marker)
            return self._send(200, page)

        if parsed.path == "/v1/domains/locked.com":
            return self._send(
                200,
                {
                    "domain": "locked.com",
                    "status": "ACTIVE",
                    "locked": STATE.get("locked.com_locked", True),
                    "expires": iso(300),
                    "createdAt": iso(-500),
                    "transferAwayEligibleAt": iso(-2),
                },
            )

        if parsed.path == "/v1/domains/missing.com":
            return self._send(404, {"code": "NOT_FOUND"})

        if parsed.path == "/v1/domains/locked.com/records":
            return self._send(
                200,
                [
                    {"type": "A", "name": "@", "data": "1.2.3.4", "ttl": 600},
                    {
                        "type": "MX",
                        "name": "@",
                        "data": "mail.example.com",
                        "ttl": 3600,
                        "priority": 10,
                    },
                ],
            )

        return self._send(404, {"code": "UNKNOWN_PATH", "path": parsed.path})

    def do_PATCH(self):
        length = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(length) or "{}")
        STATE.setdefault("patches", []).append((self.path, body))
        if self.path == "/v1/domains/locked.com":
            STATE["locked.com_locked"] = body.get("locked", True)
        self.send_response(200)
        self.send_header("Content-Length", "0")
        self.end_headers()


class TestHttpLayer(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = HTTPServer(("127.0.0.1", 0), StubHandler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.base = f"http://127.0.0.1:{cls.server.server_port}"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def setUp(self):
        STATE.clear()
        self.client = gd.Client("KEY", "SECRET")
        self.client.base = self.base

    def test_sends_sso_key_auth_header(self):
        self.client.get_domain("locked.com")
        self.assertEqual(STATE["auth_headers"][0], "sso-key KEY:SECRET")

    def test_shopper_id_header_sent_when_set(self):
        self.client.shopper_id = "12345"
        self.client.get_domain("locked.com")
        self.assertEqual(STATE["shopper_headers"][0], "12345")

    def test_shopper_id_omitted_when_unset(self):
        self.client.get_domain("locked.com")
        self.assertIsNone(STATE["shopper_headers"][0])

    def test_pagination_follows_marker(self):
        domains = self.client.list_domains()
        self.assertEqual(len(domains), 101)
        self.assertEqual(domains[-1]["domain"], "last.com")
        self.assertEqual(STATE["markers"], [None, "d099.com"])

    def test_patch_unlock_sends_locked_false(self):
        self.client.patch_domain("locked.com", {"locked": False})
        path, body = STATE["patches"][0]
        self.assertEqual(path, "/v1/domains/locked.com")
        self.assertEqual(body, {"locked": False})

    def test_unlock_then_read_reflects_new_state(self):
        self.assertTrue(self.client.get_domain("locked.com")["locked"])
        self.client.patch_domain("locked.com", {"locked": False})
        self.assertFalse(self.client.get_domain("locked.com")["locked"])

    def test_404_raises_api_error_with_status(self):
        with self.assertRaises(gd.ApiError) as ctx:
            self.client.get_domain("missing.com")
        self.assertEqual(ctx.exception.status, 404)

    def test_records_parsed(self):
        records = self.client.get_records("locked.com")
        self.assertEqual(len(records), 2)
        self.assertEqual(records[1]["priority"], 10)

    def test_preflight_reports_lock_as_blocker(self):
        detail = self.client.get_domain("locked.com")
        verdict, blockers, _ = gd.evaluate(detail)
        self.assertEqual(verdict, "BLOCKED")
        self.assertTrue(any("lock" in b for b in blockers))

    def test_backup_writes_files(self):
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            args = type("A", (), {"domains": ["locked.com"], "out": tmp})()
            gd.cmd_backup(self.client, args)
            saved = json.loads((Path(tmp) / "locked.com.json").read_text())
            self.assertEqual(saved["domain"], "locked.com")
            self.assertEqual(len(saved["records"]), 2)
            index = json.loads((Path(tmp) / "index.json").read_text())
            self.assertEqual(index["domains"], ["locked.com"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
