import http.server
import json
import os
import stat
import tempfile
import threading
import unittest

from near_voice.audio import wav_bytes
from near_voice.harness import (AuthError, CloudSttError, HarnessAuth, HarnessStt, http_post, multipart_file,
                                write_private_json)

API = "https://api.example.test"
NOW = 1_800_000_000.0


class FakePost:
    """Answers POSTs from a list of (status, body), and records each request."""

    def __init__(self, *answers):
        self.answers = list(answers)
        self.calls = []

    def __call__(self, url, body, headers, timeout):
        self.calls.append({"url": url, "body": body, "headers": headers, "timeout": timeout})
        return self.answers.pop(0)


def ok(**data):
    return 200, {"success": True, "data": data}


def fail(status, code):
    return status, {"success": False, "error": {"code": code, "message": "nope"}}


class AuthTestBase(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.dir.name, "secrets", "harness-auth.json")
        self.now = NOW

    def tearDown(self):
        self.dir.cleanup()

    def write(self, **fields):
        session = {"version": 1, "accessToken": "hna_old", "refreshToken": "hnr_1", "autonomousEnv": "prod",
                   "clientId": "harness-cli", "expiresAt": int((self.now + 3600) * 1000), **fields}
        write_private_json(self.path, session)
        # A new file version for HarnessAuth (mtime granularity can hide a rewrite within the same tick).
        st = os.stat(self.path)
        os.utime(self.path, (st.st_atime, st.st_mtime + len(self.dir.name) + fields.get("_bump", 0)))

    def auth(self, post):
        return HarnessAuth(self.path, API, post=post, now=lambda: self.now)

    def saved(self):
        with open(self.path) as f:
            return json.load(f)


class HarnessAuthTest(AuthTestBase):
    def test_a_fresh_token_is_used_without_asking_the_backend(self):
        self.write()
        post = FakePost()
        self.assertEqual(self.auth(post).token(), "hna_old")
        self.assertEqual(post.calls, [])

    def test_a_token_about_to_expire_is_renewed_and_saved_owner_only(self):
        self.write(expiresAt=int((self.now + 30) * 1000))
        post = FakePost(ok(token="hna_new", expiresIn=3600))
        self.assertEqual(self.auth(post).token(), "hna_new")
        call = post.calls[0]
        self.assertEqual(call["url"], API + "/api/auth/refresh")
        self.assertEqual(json.loads(call["body"]),
                         {"refreshToken": "hnr_1", "autonomousEnv": "prod", "clientId": "harness-cli"})
        saved = self.saved()
        self.assertEqual((saved["accessToken"], saved["refreshToken"]), ("hna_new", "hnr_1"))
        self.assertEqual(saved["expiresAt"], int((self.now + 3600) * 1000))
        self.assertEqual(stat.S_IMODE(os.stat(self.path).st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(os.stat(os.path.dirname(self.path)).st_mode), 0o700)

    def test_a_rotated_refresh_token_is_kept(self):
        self.write(expiresAt=0)
        self.auth(FakePost(ok(token="hna_new", refreshToken="hnr_2", expiresIn=3600))).token()
        self.assertEqual(self.saved()["refreshToken"], "hnr_2")

    def test_the_renewed_token_is_reused_until_it_expires(self):
        self.write(expiresAt=0)
        post = FakePost(ok(token="hna_new", expiresIn=3600))
        auth = self.auth(post)
        auth.token()
        self.assertEqual(auth.token(), "hna_new")
        self.assertEqual(len(post.calls), 1)

    def test_force_renews_a_token_that_looks_valid(self):
        self.write()
        post = FakePost(ok(token="hna_new", expiresIn=3600))
        self.assertEqual(self.auth(post).token(force=True), "hna_new")

    def test_no_file_is_missing(self):
        with self.assertRaises(AuthError) as ctx:
            self.auth(FakePost()).token()
        self.assertEqual(ctx.exception.code, "MISSING")
        self.assertFalse(self.auth(FakePost()).available())

    def test_a_file_without_tokens_is_missing(self):
        os.makedirs(os.path.dirname(self.path))
        with open(self.path, "w") as f:
            f.write('{"accessToken": ""}')
        with self.assertRaises(AuthError) as ctx:
            self.auth(FakePost()).token()
        self.assertEqual(ctx.exception.code, "MISSING")

    def test_a_refused_refresh_is_not_retried_until_the_file_is_replaced(self):
        self.write(expiresAt=0)
        post = FakePost(fail(401, "REFRESH_TOKEN_INVALID"))
        auth = self.auth(post)
        for _ in range(3):
            with self.assertRaises(AuthError) as ctx:
                auth.token()
            self.assertEqual(ctx.exception.code, "INVALID")
        self.assertEqual(len(post.calls), 1)
        self.write(accessToken="hna_signed_in_again", _bump=5)  # tools/harness_login.py ran again
        self.assertEqual(auth.token(), "hna_signed_in_again")

    def test_sign_in_again_and_outages_have_their_own_codes(self):
        for answer, code in [(fail(403, "SIGN_IN_AGAIN"), "SIGN_IN_AGAIN"),
                             (fail(503, "AUTH_SERVICE_UNAVAILABLE"), "UNAVAILABLE"), ((0, {}), "UNAVAILABLE"),
                             ((200, {"success": True, "data": {}}), "UNAVAILABLE")]:
            with self.subTest(code=code, answer=answer):
                self.write(expiresAt=0)
                with self.assertRaises(AuthError) as ctx:
                    self.auth(FakePost(answer)).token()
                self.assertEqual(ctx.exception.code, code)
                self.assertEqual(self.saved()["accessToken"], "hna_old")  # an outage never wipes the sign-in


class HarnessSttTest(AuthTestBase):
    def setUp(self):
        super().setUp()
        self.write()

    def stt(self, post, auth_post=None):
        return HarnessStt(self.auth(auth_post or FakePost()), API + "/", "vi", timeout_s=4.0, post=post)

    def test_uploads_one_wav_and_returns_the_transcript(self):
        post = FakePost(ok(transcript=" Đặt hẹn giờ 15 phút. ", lang="vi"))
        pcm = b"\x01\x00" * 1600
        self.assertEqual(self.stt(post).transcribe(pcm), "Đặt hẹn giờ 15 phút.")
        call = post.calls[0]
        self.assertEqual(call["url"], API + "/api/voice/stt?lang=vi")
        self.assertEqual(call["headers"]["Authorization"], "Bearer hna_old")
        self.assertTrue(call["headers"]["Content-Type"].startswith("multipart/form-data; boundary="))
        self.assertIn(b'name="file"; filename="voice.wav"', call["body"])
        self.assertIn(b"Content-Type: audio/wav", call["body"])
        self.assertIn(wav_bytes(pcm), call["body"])
        self.assertEqual(call["timeout"], 4.0)

    def test_a_refused_access_token_is_renewed_once(self):
        post = FakePost(fail(401, "UNAUTHORIZED"), ok(transcript="tiếp theo là gì"))
        auth_post = FakePost(ok(token="hna_new", expiresIn=3600))
        self.assertEqual(self.stt(post, auth_post).transcribe(b"\0\0"), "tiếp theo là gì")
        self.assertEqual([c["headers"]["Authorization"] for c in post.calls], ["Bearer hna_old", "Bearer hna_new"])

    def test_refused_twice_is_an_error(self):
        post = FakePost(fail(401, "UNAUTHORIZED"), fail(401, "UNAUTHORIZED"))
        with self.assertRaises(CloudSttError):
            self.stt(post, FakePost(ok(token="hna_new", expiresIn=3600))).transcribe(b"\0\0")
        self.assertEqual(len(post.calls), 2)

    def test_quota_rate_limit_and_failures_are_errors(self):
        for answer in [fail(429, "VOICE_QUOTA_EXCEEDED"), fail(429, "RATE_LIMITED"), fail(502, "STT_FAILED"),
                       (0, {}), (200, {"success": True, "data": {}})]:
            with self.subTest(answer=answer):
                with self.assertRaises(CloudSttError):
                    self.stt(FakePost(answer)).transcribe(b"\0\0")

    def test_available_follows_the_sign_in_file(self):
        stt = self.stt(FakePost())
        self.assertTrue(stt.available())
        os.remove(self.path)
        self.assertFalse(stt.available())

    def test_english_asks_for_en(self):
        stt = HarnessStt(self.auth(FakePost()), API, "en", post=FakePost())
        self.assertEqual((stt.url, stt.model), (API + "/api/voice/stt?lang=en", "harness-stt-en"))

    def test_an_empty_transcript_is_returned_as_empty(self):
        self.assertEqual(self.stt(FakePost(ok(transcript=""))).transcribe(b"\0\0"), "")


class MultipartTest(unittest.TestCase):
    def test_one_file_part_with_a_closing_boundary(self):
        body, content_type = multipart_file("file", "voice.wav", "audio/wav", b"RIFFdata")
        boundary = content_type.split("boundary=")[1]
        self.assertTrue(body.startswith(f"--{boundary}\r\n".encode()))
        self.assertTrue(body.endswith(f"\r\n\r\nRIFFdata\r\n--{boundary}--\r\n".encode()))
        self.assertNotEqual(multipart_file("f", "a", "t", b"")[1], content_type)  # a fresh boundary each time


class HttpPostTest(unittest.TestCase):
    """http_post against a real local HTTP server."""

    def setUp(self):
        test = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):  # noqa: N802
                length = int(self.headers["Content-Length"])
                test.received = (self.path, self.headers.get("X-Test"), self.headers.get("User-Agent"),
                                 self.rfile.read(length))
                status, body = test.reply
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args):
                pass

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"

    def tearDown(self):
        if self.server is not None:
            self.server.shutdown()
            self.server.server_close()

    def test_success_and_error_bodies_are_parsed(self):
        self.reply = (200, b'{"success": true, "data": {"x": 1}}')
        self.assertEqual(http_post(self.url + "/a?b=c", b"hi", {"X-Test": "1"}, 2.0),
                         (200, {"success": True, "data": {"x": 1}}))
        self.assertEqual(self.received[0], "/a?b=c")
        self.assertEqual(self.received[1:3], ("1", "near-voice/0.1"))
        self.assertEqual(self.received[3], b"hi")
        self.reply = (429, b'{"success": false, "error": {"code": "RATE_LIMITED"}}')
        self.assertEqual(http_post(self.url, b"", {}, 2.0)[0], 429)
        self.reply = (502, b"<html>bad gateway</html>")
        self.assertEqual(http_post(self.url, b"", {}, 2.0), (502, {}))

    def test_a_body_cut_short_is_status_zero(self):
        self.reply = (200, b'{"success": true')  # sent with a Content-Length longer than this
        test = self

        class Short(http.server.BaseHTTPRequestHandler):
            def do_POST(self):  # noqa: N802
                self.rfile.read(int(self.headers["Content-Length"]))
                self.send_response(200)
                self.send_header("Content-Length", "100")
                self.end_headers()
                self.wfile.write(test.reply[1])
                self.close_connection = True

            def log_message(self, *args):
                pass

        self.server.RequestHandlerClass = Short
        self.assertEqual(http_post(self.url, b"x", {}, 2.0), (0, {}))

    def test_no_server_is_status_zero(self):
        self.server.shutdown()
        self.server.server_close()
        self.server = None
        self.assertEqual(http_post(self.url, b"", {}, 1.0), (0, {}))


if __name__ == "__main__":
    unittest.main()
