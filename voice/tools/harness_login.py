"""Signs the Near board in to Harness, for cloud speech to text (near_voice/harness.py). Run it on a Mac:

    python3 tools/harness_login.py                       # browser sign-in, writes ~/.near/harness-auth.json
    scp ~/.near/harness-auth.json <board>:near/secrets/harness-auth.json

The same browser sign-in as `harness login` (backend `POST /api/auth/authorize-native`, a loopback callback, then
`POST /api/auth/exchange`), asking for a Harness session of its own ("computer" kind, labelled for Near). It never
reads or touches this computer's own Harness sign-in (~/.harness/auth), and it starts or stops nothing.

The file holds tokens: it is written readable by its owner only, and nothing here prints them.
"""

from __future__ import annotations

import argparse
import http.server
import json
import os
import sys
import threading
import time
import urllib.parse
import webbrowser
from typing import Callable, Optional, Tuple

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from near_voice.harness import DEFAULT_API, Post, http_post, write_private_json  # noqa: E402

DEFAULT_OUT = os.path.expanduser("~/.near/harness-auth.json")
DEFAULT_LABEL = "Near (Orange Pi)"
CLIENT_ID = "harness-cli"
LOGIN_TIMEOUT_S = 300.0

_DONE_PAGE = ("<!doctype html><meta charset=utf-8><title>Near</title>"
              "<body style='font-family:sans-serif;padding:40px'><h2>{}</h2><p>{}</p>")


class LoginError(Exception):
    pass


def _data(status: int, res: dict, what: str) -> dict:
    data = res.get("data")
    if status != 200 or not res.get("success") or not isinstance(data, dict):
        err = res.get("error") if isinstance(res.get("error"), dict) else {}
        raise LoginError(f"{what} failed: HTTP {status} {err.get('code', '')} {err.get('message', '')}".rstrip())
    return data


class _Callback:
    """A one-shot HTTP server on 127.0.0.1 that waits for the SSO redirect (?code=&state= or ?error=)."""

    def __init__(self) -> None:
        self.result: Optional[Tuple[str, str]] = None
        self.error: Optional[str] = None
        self.done = threading.Event()
        outer = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self) -> None:  # noqa: N802 - http.server API
                url = urllib.parse.urlparse(self.path)
                if url.path != "/callback":
                    self.send_response(404)
                    self.end_headers()
                    return
                q = urllib.parse.parse_qs(url.query)
                code, state, error = (q.get(k, [""])[0] for k in ("code", "state", "error"))
                ok = bool(code and state and not error)
                self.send_response(200 if ok else 400)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.end_headers()
                page = (_DONE_PAGE.format("Near đã đăng nhập", "Đóng tab này và quay lại terminal.") if ok else
                        _DONE_PAGE.format("Đăng nhập không thành công", "Xem thông báo trong terminal."))
                self.wfile.write(page.encode("utf-8"))
                if ok:
                    outer.result = (code, state)
                else:
                    outer.error = error or "the callback had no code"
                outer.done.set()

            def log_message(self, *args: object) -> None:  # the query string carries the one-time code
                pass

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.redirect_uri = f"http://127.0.0.1:{self.server.server_address[1]}/callback"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def wait(self, timeout_s: float) -> Tuple[str, str]:
        try:
            if not self.done.wait(timeout_s):
                raise LoginError(f"no sign-in within {int(timeout_s)} s")
            if self.error is not None:
                raise LoginError(f"sign-in failed: {self.error}")
            assert self.result is not None
            return self.result
        finally:
            self.server.shutdown()
            self.server.server_close()


def login(api: str = DEFAULT_API, out: str = DEFAULT_OUT, label: str = DEFAULT_LABEL, *, post: Post = http_post,
          open_url: Callable[[str], object] = webbrowser.open, say: Callable[[str], None] = print,
          now: Callable[[], float] = time.time, timeout_s: float = LOGIN_TIMEOUT_S) -> dict:
    """Runs the browser sign-in and writes [out]. Returns the session written."""
    api = api.rstrip("/")
    callback = _Callback()
    headers = {"Content-Type": "application/json"}
    try:
        start = _data(*post(api + "/api/auth/authorize-native", json.dumps({
            "redirectUri": callback.redirect_uri, "autonomousEnv": "prod", "entryPoint": "near", "clientId": CLIENT_ID,
        }).encode(), headers, 15.0), "starting the sign-in")
    except BaseException:
        callback.server.shutdown()
        callback.server.server_close()
        raise
    authorize_url, tx = start.get("authorizeUrl"), start.get("tx")
    if not isinstance(authorize_url, str) or not isinstance(tx, str):
        callback.server.shutdown()
        callback.server.server_close()
        raise LoginError("the backend gave no sign-in URL")
    say(f"\n  Sign in to Harness in your browser (the account Near should use):\n\n    {authorize_url}\n")
    open_url(authorize_url)
    code, state = callback.wait(timeout_s)
    tokens = _data(*post(api + "/api/auth/exchange", json.dumps({
        "code": code, "state": state, "tx": tx, "harnessSession": {"kind": "computer", "label": label},
    }).encode(), headers, 15.0), "finishing the sign-in")
    session = session_from(tokens, api, now())
    write_private_json(out, session)
    say(f"  Signed in. Saved to {out} (owner-only).\n"
        f"  Copy it to the board:  scp {out} <board>:near/secrets/harness-auth.json\n")
    return session


def session_from(tokens: dict, api: str, now_s: float) -> dict:
    """The auth file near-voice reads (field names as in the harness CLI's session.json)."""
    token, refresh = tokens.get("token"), tokens.get("refreshToken")
    if not isinstance(token, str) or not token or not isinstance(refresh, str) or not refresh:
        raise LoginError("the sign-in gave no access or refresh token")
    session = {"version": 1, "accessToken": token, "refreshToken": refresh,
               "autonomousEnv": tokens.get("autonomousEnv") or "prod", "clientId": CLIENT_ID, "api": api,
               "harnessSession": bool(tokens.get("harnessSession")), "updatedAt": int(now_s * 1000)}
    if isinstance(tokens.get("expiresIn"), (int, float)) and tokens["expiresIn"] > 0:
        session["expiresAt"] = int((now_s + tokens["expiresIn"]) * 1000)
    return session


def main(argv: Optional[list] = None) -> int:
    a = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    a.add_argument("--api", default=os.environ.get("NEAR_HARNESS_API", DEFAULT_API))
    a.add_argument("--out", default=DEFAULT_OUT)
    a.add_argument("--label", default=DEFAULT_LABEL, help="how this sign-in is named in the account's sign-ins")
    a.add_argument("--no-browser", action="store_true", help="only print the URL")
    args = a.parse_args(argv)
    try:
        login(args.api, args.out, args.label, open_url=(lambda _u: None) if args.no_browser else webbrowser.open)
    except LoginError as e:
        print(f"  ✗ {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
