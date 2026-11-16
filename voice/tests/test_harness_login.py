import json
import os
import stat
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tools"))

import harness_login  # noqa: E402

API = "https://api.example.test"
NOW = 1_800_000_000.0


class Backend:
    """Fake backend for authorize-native and exchange; records what was posted."""

    def __init__(self, exchange=None):
        self.posts = []
        self.exchange = exchange or (200, {"success": True, "data": {
            "token": "hna_secret_access", "refreshToken": "hnr_secret_refresh", "expiresIn": 3600,
            "kind": "computer", "autonomousEnv": "prod", "harnessSession": True}})

    def __call__(self, url, body, headers, timeout):
        self.posts.append((url, json.loads(body)))
        if url.endswith("/api/auth/authorize-native"):
            return 200, {"success": True, "data": {"authorizeUrl": "https://sso.example.test/authorize?x=1",
                                                   "tx": "tx-1"}}
        if url.endswith("/api/auth/exchange"):
            return self.exchange
        return 404, {}


class Browser:
    """Stands in for the person signing in: once the URL is opened, the SSO redirects to the loopback callback."""

    def __init__(self, backend, query="code=c-1&state=s-1"):
        self.backend = backend
        self.query = query
        self.opened = []
        self.status = None

    def __call__(self, url):
        self.opened.append(url)
        redirect = self.backend.posts[0][1]["redirectUri"]

        def visit():
            try:
                with urllib.request.urlopen(f"{redirect}?{self.query}", timeout=5) as res:
                    self.status = res.status
            except urllib.error.HTTPError as e:
                self.status = e.code
                e.close()

        threading.Thread(target=visit, daemon=True).start()


class LoginTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.out = os.path.join(self.dir.name, "near", "harness-auth.json")
        self.said = []

    def tearDown(self):
        self.dir.cleanup()

    def login(self, backend, browser, **kw):
        return harness_login.login(API + "/", self.out, "Near test", post=backend, open_url=browser,
                                   say=self.said.append, now=lambda: NOW, timeout_s=kw.get("timeout_s", 5.0))

    def test_browser_sign_in_writes_an_owner_only_session(self):
        backend = Backend()
        browser = Browser(backend)
        session = self.login(backend, browser)
        (start_url, start), (exchange_url, exchange) = backend.posts
        self.assertEqual(start_url, API + "/api/auth/authorize-native")
        redirect = urllib.parse.urlparse(start["redirectUri"])
        self.assertEqual((redirect.scheme, redirect.hostname, redirect.path), ("http", "127.0.0.1", "/callback"))
        self.assertEqual((start["autonomousEnv"], start["clientId"], start["entryPoint"]), ("prod", "harness-cli", "near"))
        self.assertEqual(browser.opened, ["https://sso.example.test/authorize?x=1"])
        self.assertEqual(exchange_url, API + "/api/auth/exchange")
        self.assertEqual(exchange, {"code": "c-1", "state": "s-1", "tx": "tx-1",
                                    "harnessSession": {"kind": "computer", "label": "Near test"}})
        self.assertEqual(browser.status, 200)
        with open(self.out) as f:
            saved = json.load(f)
        self.assertEqual(saved, session)
        self.assertEqual((saved["accessToken"], saved["refreshToken"], saved["clientId"]),
                         ("hna_secret_access", "hnr_secret_refresh", "harness-cli"))
        self.assertEqual(saved["expiresAt"], int((NOW + 3600) * 1000))
        self.assertEqual(stat.S_IMODE(os.stat(self.out).st_mode), 0o600)
        printed = "\n".join(self.said)
        self.assertNotIn("hna_secret_access", printed)
        self.assertNotIn("hnr_secret_refresh", printed)

    def test_an_sso_error_is_reported_and_nothing_is_written(self):
        backend = Backend()
        with self.assertRaises(harness_login.LoginError) as ctx:
            self.login(backend, Browser(backend, query="error=access_denied"))
        self.assertIn("access_denied", str(ctx.exception))
        self.assertEqual(len(backend.posts), 1)  # no exchange
        self.assertFalse(os.path.exists(self.out))

    def test_a_failed_exchange_is_reported(self):
        backend = Backend(exchange=(400, {"success": False, "error": {"code": "INVALID_TX", "message": "expired"}}))
        with self.assertRaises(harness_login.LoginError) as ctx:
            self.login(backend, Browser(backend))
        self.assertIn("INVALID_TX", str(ctx.exception))
        self.assertFalse(os.path.exists(self.out))

    def test_no_sign_in_in_time(self):
        backend = Backend()
        with self.assertRaises(harness_login.LoginError):
            self.login(backend, lambda url: None, timeout_s=0.2)

    def test_session_needs_both_tokens(self):
        with self.assertRaises(harness_login.LoginError):
            harness_login.session_from({"token": "hna_x"}, API, NOW)


if __name__ == "__main__":
    unittest.main()
