# near-voice

Speech-to-text for the Near app: local Zipformer-vi, optionally behind cloud STT through the Harness backend, and an
optional "Hey Near" wake word trial. Python 3.9+ (the board runs 3.11), sherpa-onnx and numpy only (HTTP is stdlib).
Protocol and behaviour: spec section 6 (`docs/superpowers/specs/2026-11-16-near-demo-design.md`).

```
mic (arecord / ffmpeg) -> Capture -> FrameHub -+-> RingBuffer (last 2 s, RAM only)
                                               +-> VoiceServer.on_frame -> Silero VAD -> Segmenter -> Zipformer-vi
                                                       (VAD and STT run only while a listen is open)
app <-- JSON lines, TCP 127.0.0.1:8781 --> VoiceServer
```

| Module | What it does |
|---|---|
| `protocol.py` | Decode commands (`listen`, `cancel`, `chime`), encode events. Unknown commands are ignored |
| `audio.py` | 32 ms frames, `RingBuffer`, `FrameHub` (single fan-out point), `Capture` (restarts the recorder), `WavSource` (dev), `level_db`, `peak`, `wav_bytes` |
| `segmenter.py` | Pure state machine: 0.25 s to confirm speech, 0.6 s silence ends it, 8 s max, 4 s with no speech |
| `vad.py`, `stt.py` | Silero VAD and Zipformer-vi behind small interfaces |
| `chime.py` | `soft` / `alert` through `aplay` on the HDMI card (Mac: `afplay`); failures are only logged |
| `server.py` | One listen at a time; drops the `final` of a cancelled or superseded listen; `no_audio` watchdog; `wake` events and the `wake` on/off command |
| `harness.py` | Cloud STT: `HarnessAuth` (the board's own Harness sign-in, renewed by itself) and `HarnessStt` (`POST /api/voice/stt`, Deepgram nova-2 for vi) |
| `stt.py` `CloudFirstStt` | Cloud and local run at once; the cloud words when they come within `--cloud-timeout` (3 s), the local ones otherwise (no sign-in, offline, 429 quota, 5xx). Both transcripts go to the local log |
| `wake.py` | "Hey Near" with sherpa-onnx keyword spotting (zh-en 3M, `keywords/hey-near-zhen.txt`) in its own thread; fed only while an app wants it and no listen is open. Phase 0 E5: catches about 2 in 12, so a trial of the path, not a finished wake word |

Extension points for wake word and TTS: `VoiceServer.begin_listen(id, from_index=...)` starts the utterance at a
given frame instead of the 0.5 s pre-roll; `VoiceServer.before_listen` hooks run before each listen (the chime is
stopped there); extra consumers can be added to the `FrameHub`.

## Run

Models are not in the repo. On the board they are in `~/phase0/stt/models` (from Phase 0, E4):

```
cd voice
taskset -c 6,7 ~/phase0/stt/venv/bin/python -m near_voice --models ~/phase0/stt/models
python3 tools/try_listen.py            # listen once and print events
python3 tools/try_listen.py --chime soft
```

`--wav file.wav` replaces the mic with a 16 kHz mono WAV played at each listen (latency checks without speaking).
Settings also come from the environment: `NEAR_VOICE_PORT`, `NEAR_MODELS`, `NEAR_STT_MODEL`, `NEAR_MIC`,
`NEAR_SPEAKER`, `NEAR_SOUNDS`, and for the options below `NEAR_STT`, `NEAR_STT_LANG`, `NEAR_STT_EN`, `NEAR_CLOUD_TIMEOUT`,
`NEAR_HARNESS_API`, `NEAR_HARNESS_AUTH`, `NEAR_WAKE`, `NEAR_WAKE_MODEL`, `NEAR_WAKE_KEYWORDS`, `NEAR_WAKE_THRESHOLD`,
`NEAR_WAKE_SCORE`.

### English through Harness (`--stt-en harness`), cloud speech to text (`--stt cloud`)

A `listen` may name its language: `{"cmd":"listen","id":"l1","lang":"en"}` (no `lang`: Vietnamese). With
`--stt-en harness`, English goes to Harness `/api/voice/stt?lang=en` (Deepgram nova-3) with no local fallback (the
local model is Vietnamese); a failure is an `error`. `ready` lists the languages on offer (`"langs":["vi","en"]`), English
only while there is a sign-in; the app shows its VI/EN switch then. Measured on the E4 set (phase0 RESULTS.md, E4b):
nova-3 31% English WER, p95 1.5 s; for Vietnamese, nova-2 did worse than Zipformer (23% against 7%), so `--stt cloud`
(cloud words first for the default language) stays off on the board.

The board signs in to Harness once, with its own sign-in (never a copy of a computer's `~/.harness/auth`):

```
python3 tools/harness_login.py           # on a Mac: browser sign-in, writes ~/.near/harness-auth.json (owner only)
scp ~/.near/harness-auth.json <board>:near/secrets/harness-auth.json
```

near-voice renews the access token (1 hour) with the refresh token and rewrites the file; the sign-in stays alive
while it is used at least once every 90 days. A new file is picked up without a restart. With `--stt cloud`, each
utterance (and only that) is uploaded; the account's voice limits apply (10 clips a minute, the plan's daily seconds).

### Wake word (`--wake kws`)

Needs `sherpa-onnx-kws-zipformer-zh-en-3M-2025-12-20` in `--models` (`deploy/board/fetch_models.sh` copies it from
Phase 0 or downloads it). The app turns spotting off at night and during focus with `{"cmd":"wake","on":false}`.
Tune with `--wake-threshold` (lower catches more and errs more) and `--wake-keywords keywords/hey-near-zhen-accent.txt`
(Vietnamese-accented variants; E5 found them no better).

On a Mac: a venv with `pip install sherpa-onnx numpy`, the same models copied locally, and `ffmpeg` (the mic is
`avfoundation` input `:0`, override with `--mic`).

## Test

```
cd voice
python3 -m unittest                    # no model needed
NEAR_MODELS=~/phase0/stt/models ~/phase0/stt/venv/bin/python -m unittest   # on the board: also the real engines
```

`sounds/*.wav` are generated by `tools/make_chimes.py` (a test checks the committed files match it).
