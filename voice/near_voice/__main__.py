"""Runs near-voice: python3 -m near_voice [options]. Settings come from flags, then environment, then defaults."""

from __future__ import annotations

import argparse
import asyncio
import logging
import os
import signal
import sys
import time
from typing import List, Optional

from .audio import Capture, FrameHub, WavSource, mic_command, read_wav
from .chime import Chimes
from .server import VoiceServer
from .stt import DEFAULT_MODEL, ZipformerStt
from .vad import SileroVad

log = logging.getLogger("near_voice")

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_SOUNDS = os.path.join(os.path.dirname(HERE), "sounds")


def parse_args(argv: Optional[List[str]] = None, env: Optional[dict] = None) -> argparse.Namespace:
    env = os.environ if env is None else env
    a = argparse.ArgumentParser(prog="near_voice", description=__doc__)
    a.add_argument("--host", default="127.0.0.1")
    a.add_argument("--port", type=int, default=int(env.get("NEAR_VOICE_PORT", "8781")))
    a.add_argument("--models", default=env.get("NEAR_MODELS", os.path.expanduser("~/near/models")),
                   help="directory holding silero_vad.onnx and the STT model directory")
    a.add_argument("--stt-model", default=env.get("NEAR_STT_MODEL", DEFAULT_MODEL))
    a.add_argument("--threads", type=int, default=2, help="STT threads")
    a.add_argument("--mic", default=env.get("NEAR_MIC"), help="ALSA device (board) or avfoundation input (Mac)")
    a.add_argument("--speaker", default=env.get("NEAR_SPEAKER"), help="ALSA device for chimes (board)")
    a.add_argument("--sounds", default=env.get("NEAR_SOUNDS", DEFAULT_SOUNDS))
    a.add_argument("--wav", help="dev: instead of the mic, play this 16 kHz mono WAV at each listen")
    a.add_argument("-v", "--verbose", action="store_true")
    return a.parse_args(argv)


async def serve(args: argparse.Namespace) -> None:
    t0 = time.perf_counter()
    vad = SileroVad(os.path.join(args.models, "silero_vad.onnx"))
    stt = ZipformerStt(os.path.join(args.models, args.stt_model), threads=args.threads)
    stt.warm_up()
    log.info("models loaded in %d ms: %s", (time.perf_counter() - t0) * 1000, stt.model)

    hub = FrameHub()
    server = VoiceServer(vad, stt, Chimes(args.sounds, args.speaker))
    hub.add(server.on_frame)
    if args.wav:
        source = WavSource(read_wav(args.wav), hub)
        server.before_listen.append(lambda _id: source.play())
    else:
        source = Capture(mic_command(args.mic), hub)
    if server.chimes is not None:
        server.before_listen.append(lambda _id: server.chimes.stop())  # do not record our own chime

    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, stop.set)

    await server.start(args.host, args.port)
    capture = asyncio.ensure_future(source.run())
    await stop.wait()
    log.info("stopping")
    source.stop()
    await server.close()
    capture.cancel()


def main(argv: Optional[List[str]] = None) -> int:
    args = parse_args(argv)
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO, stream=sys.stderr,
                        format="%(name)s %(levelname)s: %(message)s")
    asyncio.run(serve(args))
    return 0


if __name__ == "__main__":
    sys.exit(main())
