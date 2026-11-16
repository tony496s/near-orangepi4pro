"""Cloud speech to text through the Harness backend (`POST /api/voice/stt`), which calls Deepgram (nova-2 for vi).

The same endpoint the Harness phone app uses (harness/mobile `ApiClient.transcribeVoice`): one 16 kHz mono WAV in a
multipart `file` part, a bearer token, `{"success": true, "data": {"transcript": ..., "lang": ...}}` back.

The board holds a Harness sign-in of its own, made once by `tools/harness_login.py` on a Mac (a browser sign-in, like
`harness login`) and copied to the board. It is NOT a copy of a computer's `~/.harness/auth/session.json`: two clients
renewing one sign-in would trip over each other. The file holds a Harness session (`hna_` access token, 1 hour;
`hnr_` refresh token, which the backend keeps alive while it is used at least once every 90 days).

Neither the token nor the transcript is ever logged here. The backend bounds use per account: 10 clips a minute and
the plan's daily voice seconds; past that it answers 429 and near-voice falls back to the local model.
"""

from __future__ import annotations

import http.client
import json
import logging
import os
import secrets
import threading
import time
import urllib.error
import urllib.request
from typing import Callable, Dict, Optional, Tuple

from .audio import wav_bytes

log = logging.getLogger("near_voice.harness")

DEFAULT_API = "https://harness-api.autonomous.ai"
DEFAULT_AUTH_FILE = os.path.expanduser("~/near/secrets/harness-auth.json")
STT_PATH = "/api/voice/stt"
REFRESH_PATH = "/api/auth/refresh"
# A token this close to its expiry is renewed first (the CLI's REFRESH_SKEW_MS).
REFRESH_SKEW_S = 60.0
USER_AGENT = "near-voice/0.1"

# (status, parsed JSON body or {}) for a POST; status 0 when no HTTP answer came (network, timeout).
Post = Callable[[str, bytes, Dict[str, str], float], Tuple[int, dict]]


def http_post(url: str, body: bytes, headers: Dict[str, str], timeout: float) -> Tuple[int, dict]:
    req = urllib.request.Request(url, data=body, method="POST", headers={"User-Agent": USER_AGENT, **headers})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as res:
            return res.status, _json(res.read())
    except urllib.error.HTTPError as e:
        try:
            return e.code, _json(e.read())
        finally:
            e.close()
    except (urllib.error.URLError, OSError, ValueError, http.client.HTTPException) as e:
        # URLError wraps DNS and connection failures; a socket timeout is an OSError; a connection cut mid-body is an
        # HTTPException (IncompleteRead).
        log.warning("POST %s: %s", url.split("?")[0], type(e).__name__)
        return 0, {}


def _json(raw: bytes) -> dict:
    try:
        obj = json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return {}
    return obj if isinstance(obj, dict) else {}


def _error_code(body: dict) -> str:
    err = body.get("error")
    return str(err.get("code", "")) if isinstance(err, dict) else ""


class AuthError(Exception):
    """No usable sign-in. code: MISSING (no file), INVALID (refresh refused: sign in again), SIGN_IN_AGAIN (SSO has not
    confirmed the account for 7 days), UNAVAILABLE (backend unreachable or failing; try again later)."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


class HarnessAuth:
    """The board's Harness sign-in: hands out an access token, renewing it with the refresh token when it is about to
    expire. Thread safe. The file is read again whenever it changes, so a new sign-in needs no restart."""

    def __init__(self, path: str = DEFAULT_AUTH_FILE, api: str = DEFAULT_API, *, post: Post = http_post,
                 now: Callable[[], float] = time.time, timeout_s: float = 10.0) -> None:
        self.path = path
        self.api = api.rstrip("/")
        self._post = post
        self._now = now
        self._timeout = timeout_s
        self._lock = threading.Lock()
        self._session: Optional[dict] = None
        self._mtime: Optional[float] = None
        # The file version whose refresh token was refused: not tried again until the file is replaced.
        self._refused_mtime: Optional[float] = None

    def available(self) -> bool:
        return os.path.isfile(self.path)

    def token(self, force: bool = False) -> str:
        """A valid access token. [force] renews even when the current one looks valid (it was just refused)."""
        with self._lock:
            session = self._load()
            expires_at = session.get("expiresAt")
            fresh = isinstance(expires_at, (int, float)) and expires_at / 1000 > self._now() + REFRESH_SKEW_S
            if fresh and not force:
                return session["accessToken"]
            return self._refresh(session)

    def _load(self) -> dict:
        try:
            mtime = os.stat(self.path).st_mtime
        except OSError:
            self._session = None
            raise AuthError("MISSING", f"no Harness sign-in at {self.path}: run tools/harness_login.py") from None
        if self._refused_mtime == mtime:
            raise AuthError("INVALID", "the Harness sign-in was refused: run tools/harness_login.py again")
        if self._session is None or self._mtime != mtime:
            try:
                with open(self.path, encoding="utf-8") as f:
                    obj = json.load(f)
            except (OSError, ValueError) as e:
                raise AuthError("MISSING", f"cannot read {self.path}: {type(e).__name__}") from None
            if not isinstance(obj, dict) or not obj.get("accessToken") or not obj.get("refreshToken"):
                raise AuthError("MISSING", f"{self.path} has no accessToken/refreshToken")
            self._session, self._mtime = obj, mtime
        return self._session

    def _refresh(self, session: dict) -> str:
        body = {"refreshToken": session["refreshToken"], "autonomousEnv": session.get("autonomousEnv", "prod")}
        if session.get("clientId"):
            body["clientId"] = session["clientId"]
        status, res = self._post(self.api + REFRESH_PATH, json.dumps(body).encode(),
                                 {"Content-Type": "application/json"}, self._timeout)
        code = _error_code(res)
        if status == 401 or code == "REFRESH_TOKEN_INVALID":
            self._refused_mtime = self._mtime
            log.error("harness sign-in refused (HTTP %s): sign in again with tools/harness_login.py", status)
            raise AuthError("INVALID", "the Harness sign-in was refused: run tools/harness_login.py again")
        if code == "SIGN_IN_AGAIN":
            raise AuthError("SIGN_IN_AGAIN", "Harness asks to sign in again: run tools/harness_login.py")
        data = res.get("data") if isinstance(res.get("data"), dict) else {}
        token = data.get("token")
        if status != 200 or not res.get("success") or not isinstance(token, str) or not token:
            raise AuthError("UNAVAILABLE", f"token refresh failed (HTTP {status} {code})".rstrip())
        updated = dict(session, accessToken=token, updatedAt=int(self._now() * 1000))
        if isinstance(data.get("refreshToken"), str) and data["refreshToken"]:
            updated["refreshToken"] = data["refreshToken"]  # a rotated one must not be lost
        if isinstance(data.get("expiresIn"), (int, float)) and data["expiresIn"] > 0:
            updated["expiresAt"] = int((self._now() + data["expiresIn"]) * 1000)
        self._session = updated
        try:
            write_private_json(self.path, updated)
            self._mtime = os.stat(self.path).st_mtime
        except OSError as e:
            # Kept in RAM: this process stays signed in; the next start renews again from the file.
            log.error("cannot save the renewed sign-in to %s: %s", self.path, e)
        log.info("harness access token renewed")
        return token


def write_private_json(path: str, obj: dict) -> None:
    """Atomically writes [obj] readable by the owner only. fsyncs file and directory: the board's rootfs is mounted
    with commit=600, and a sign-in lost to a power cut would mean signing in again."""
    d = os.path.dirname(os.path.abspath(path))
    os.makedirs(d, mode=0o700, exist_ok=True)
    tmp = os.path.join(d, f".{os.path.basename(path)}.{os.getpid()}.tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(obj, f)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    dfd = os.open(d, os.O_RDONLY)
    try:
        os.fsync(dfd)
    finally:
        os.close(dfd)


def multipart_file(field: str, filename: str, content_type: str, data: bytes) -> Tuple[bytes, str]:
    """A multipart/form-data body with one file part, and its Content-Type header."""
    boundary = "near-" + secrets.token_hex(12)
    head = (f"--{boundary}\r\nContent-Disposition: form-data; name=\"{field}\"; filename=\"{filename}\"\r\n"
            f"Content-Type: {content_type}\r\n\r\n").encode()
    return head + data + f"\r\n--{boundary}--\r\n".encode(), f"multipart/form-data; boundary={boundary}"


class CloudSttError(Exception):
    pass


class HarnessStt:
    """SttEngine over the Harness backend. Raises on any failure; CloudFirstStt (stt.py) falls back to local."""

    name = "deepgram"

    def __init__(self, auth: HarnessAuth, api: str = DEFAULT_API, lang: str = "vi", *, timeout_s: float = 8.0,
                 post: Post = http_post) -> None:
        self.auth = auth
        self.url = f"{api.rstrip('/')}{STT_PATH}?lang={lang}"
        self.model = f"harness-stt-{lang}"
        self.timeout_s = timeout_s
        self._post = post

    def transcribe(self, pcm: bytes) -> str:
        body, content_type = multipart_file("file", "voice.wav", "audio/wav", wav_bytes(pcm))
        status, res = 0, {}
        for attempt in range(2):
            token = self.auth.token(force=attempt > 0)
            status, res = self._post(self.url, body, {"Authorization": f"Bearer {token}",
                                                      "Content-Type": content_type}, self.timeout_s)
            if status != 401:
                break
            log.warning("cloud stt: access token refused, renewing it once")
        data = res.get("data") if isinstance(res.get("data"), dict) else {}
        transcript = data.get("transcript")
        if status != 200 or not res.get("success") or not isinstance(transcript, str):
            raise CloudSttError(f"HTTP {status} {_error_code(res)}".rstrip())
        return transcript.strip()
