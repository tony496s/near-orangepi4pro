"""JSON-lines protocol between near_app and near-voice (spec section 6).

One JSON object per line, UTF-8. The app sends commands ({"cmd": ...}); the service sends events ({"ev": ...}).
Unknown commands are ignored rather than rejected, so a newer app can talk to an older service.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Optional, Union

CHIMES = ("soft", "alert")


@dataclass(frozen=True)
class Listen:
    id: str


@dataclass(frozen=True)
class Cancel:
    pass


@dataclass(frozen=True)
class Finish:
    """The user is done talking (tapped again): transcribe what was said so far."""


@dataclass(frozen=True)
class Chime:
    name: str


Command = Union[Listen, Cancel, Finish, Chime]


class ProtocolError(ValueError):
    """A line that is not a valid command (bad JSON, missing field)."""


def decode_command(line: Union[str, bytes]) -> Optional[Command]:
    """Parses one line. Returns None for a well-formed but unknown command; raises ProtocolError when malformed."""
    try:
        obj = json.loads(line)
    except (ValueError, UnicodeDecodeError) as e:
        raise ProtocolError(f"bad json: {e}") from None
    if not isinstance(obj, dict):
        raise ProtocolError("not an object")
    cmd = obj.get("cmd")
    if cmd == "listen":
        id_ = obj.get("id")
        if not isinstance(id_, str) or not id_:
            raise ProtocolError("listen needs a non-empty string id")
        return Listen(id_)
    if cmd == "cancel":
        return Cancel()
    if cmd == "finish":
        return Finish()
    if cmd == "chime":
        name = obj.get("name")
        if not isinstance(name, str):
            raise ProtocolError("chime needs a name")
        return Chime(name)
    if not isinstance(cmd, str):
        raise ProtocolError("missing cmd")
    return None


def encode_event(ev: str, **fields: object) -> bytes:
    """One event line, compact, non-ASCII kept as is (Vietnamese text stays readable in logs and `nc`)."""
    return (json.dumps({"ev": ev, **fields}, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")


def ready(model: str, stt: str, tts: bool = False, wake: str = "off") -> bytes:
    return encode_event("ready", model=model, stt=stt, tts=tts, wake=wake)


def listening(id_: str) -> bytes:
    return encode_event("listening", id=id_)


def level(db: float) -> bytes:
    return encode_event("level", db=round(db, 1))


def processing(id_: str) -> bytes:
    return encode_event("processing", id=id_)


def final(id_: str, text: str, audio_ms: int, stt_ms: int, engine: str) -> bytes:
    return encode_event("final", id=id_, text=text, audio_ms=audio_ms, stt_ms=stt_ms, engine=engine)


NO_SPEECH = "no_speech"
NO_AUDIO = "no_audio"


def timeout(id_: str, reason: str) -> bytes:
    """reason: "no_speech" (the mic works, nobody spoke) or "no_audio" (the mic delivered silence or nothing)."""
    return encode_event("timeout", id=id_, reason=reason)


def error(msg: str) -> bytes:
    return encode_event("error", msg=msg)
