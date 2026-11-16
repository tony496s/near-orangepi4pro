"""Short sounds (soft, alert) played through the strip's HDMI speaker. A failure is only logged."""

from __future__ import annotations

import asyncio
import logging
import os
import sys
from typing import Callable, List, Optional

from .protocol import CHIMES

log = logging.getLogger("near_voice.chime")

BOARD_SPEAKER = "plughw:CARD=allwinnerhdmi,DEV=0"


def player_command(path: str, device: Optional[str] = None, platform: str = sys.platform) -> List[str]:
    if platform == "darwin":
        return ["afplay", path]
    return ["aplay", "-q", "-D", device or BOARD_SPEAKER, path]


class Chimes:
    """Plays one chime at a time: a new chime stops the one still playing (the HDMI device has no mixer)."""

    def __init__(self, sounds_dir: str, device: Optional[str] = None, platform: str = sys.platform,
                 player: Callable[[str, Optional[str], str], List[str]] = player_command) -> None:
        self.sounds_dir = sounds_dir
        self.device = device
        self.platform = platform
        self.player = player
        self._proc: Optional[asyncio.subprocess.Process] = None

    def path_of(self, name: str) -> str:
        return os.path.join(self.sounds_dir, f"{name}.wav")

    async def play(self, name: str) -> None:
        if name not in CHIMES:
            log.warning("chime: unknown name %r", name)
            return
        path = self.path_of(name)
        if not os.path.isfile(path):
            log.warning("chime: missing %s", path)
            return
        self.stop()
        cmd = self.player(path, self.device, self.platform)
        try:
            proc = await asyncio.create_subprocess_exec(
                *cmd, stdin=asyncio.subprocess.DEVNULL, stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.PIPE)
        except OSError as e:
            log.warning("chime: cannot run %s: %s", cmd[0], e)
            return
        self._proc = proc
        _, err = await proc.communicate()
        if self._proc is proc:
            self._proc = None
        if proc.returncode not in (0, -15):  # -15: stopped by a newer chime
            log.warning("chime: %s exited %s: %s", cmd[0], proc.returncode, err.decode(errors="replace").strip())

    def stop(self) -> None:
        if self._proc is not None and self._proc.returncode is None:
            try:
                self._proc.terminate()
            except ProcessLookupError:
                pass
