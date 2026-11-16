"""Dev client: connects to near-voice, sends one command and prints events with timestamps.

    python3 tools/try_listen.py                 # listen once, print until final/timeout/error
    python3 tools/try_listen.py --chime soft    # play a chime
    python3 tools/try_listen.py --repeat 5      # listen 5 times in a row
"""

from __future__ import annotations

import argparse
import json
import socket
import sys
import time
import uuid


def main() -> int:
    a = argparse.ArgumentParser()
    a.add_argument("--host", default="127.0.0.1")
    a.add_argument("--port", type=int, default=8781)
    a.add_argument("--chime")
    a.add_argument("--repeat", type=int, default=1)
    a.add_argument("--levels", action="store_true", help="also print level events")
    args = a.parse_args()

    with socket.create_connection((args.host, args.port), timeout=20) as s:
        f = s.makefile("rwb")

        def send(obj: dict) -> None:
            f.write((json.dumps(obj) + "\n").encode())
            f.flush()

        def read() -> dict:
            line = f.readline()
            if not line:
                raise SystemExit("service closed the connection")
            return json.loads(line)

        print(read())  # ready
        if args.chime:
            send({"cmd": "chime", "name": args.chime})
            time.sleep(2)
            return 0
        for _ in range(args.repeat):
            id_ = uuid.uuid4().hex[:8]
            t0 = time.perf_counter()
            send({"cmd": "listen", "id": id_})
            t_processing = None
            while True:
                ev = read()
                ms = int((time.perf_counter() - t0) * 1000)
                if ev["ev"] == "processing":
                    t_processing = time.perf_counter()
                if ev["ev"] != "level" or args.levels:
                    print(f"{ms:6d} ms  {json.dumps(ev, ensure_ascii=False)}")
                if ev["ev"] in ("final", "timeout", "error"):
                    if ev["ev"] == "final" and t_processing is not None:
                        print(f"         processing -> final: {int((time.perf_counter() - t_processing) * 1000)} ms")
                    break
    return 0


if __name__ == "__main__":
    sys.exit(main())
