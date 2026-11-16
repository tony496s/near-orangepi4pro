# Kế hoạch: STT, TTS và wake word cho Near

> Ngày 2026-11-16. Trạng thái: **đã chốt mục 7, đang thử trên board**. B1, B2 đã xong (`017f60c` trên `feat/m1-day-strip`).
> B3 (STT cloud qua backend Harness), C1 (wake word KWS có sẵn) và phần wake của B6, B7 đã làm (PR #2). TTS (A2, B4,
> B5, B8 phần Piper, phần `say` của B6, B7) **tạm hoãn** theo người dùng.
> **A1 đã đo (16/11, `phase0/RESULTS.md` mục E4b):** qua Harness, tiếng Việt (nova-2) sai 23% so với 7% của Zipformer và
> chậm hơn khoảng 2 s; tiếng Anh (nova-3) sai 31%, tốt hơn Parakeet (47%). Người dùng chốt: **tiếng Việt chạy local
> (mặc định), tiếng Anh qua Harness**, chọn bằng nút VI/EN dưới mic. `listen` có thêm `lang`, `ready` có `langs`; app
> có parser lệnh tiếng Anh (`en_parser.dart`). `CloudFirstStt` (`--stt cloud`) vẫn giữ nhưng tắt trên board.
> Tham khảo: `harness/autonomous-harness/mobile` (voice input), `phase0/RESULTS.md` (E4 STT, E5 wake word),
> spec `docs/superpowers/specs/2026-11-16-near-demo-design.md` (mục 6, protocol voice).
> Kế hoạch này mở rộng **bước 12** của M1 (voice service) và thêm TTS, STT cloud tuỳ chọn, wake word thử nghiệm.

## 0. Lấy được gì từ harness/mobile

| Phần | Mobile có không | Mobile làm thế nào | Near dùng thế nào |
|---|---|---|---|
| STT | **Có** | Plugin `record` thu PCM 16 kHz mono, bọc WAV (`lib/phone/voice_wav.dart`), gửi `POST /api/voice/stt?lang=vi` lên backend Harness (bearer SSO). Backend gọi Deepgram: `nova-2` cho `vi`, `nova-3` cho `en` (`backend/src/lib/deepgramWav.ts`) | Lấy pattern, và làm thêm **engine cloud tuỳ chọn** gọi thẳng Deepgram. Không lấy plugin `record` (flutter-pi không có plugin), không đi qua backend Harness |
| TTS | **Không** | Cả repo harness không có TTS | Chọn mới: Piper `vi_VN` chạy bằng sherpa-onnx (`OfflineTts`), cùng package với STT |
| Wake word | **Không** | Cả repo harness chỉ nhắc tới trong mockup | Dựa vào số đo E5 |

**Pattern nên lấy:**

1. **WAV tự mô tả** (`wavFromPcm16`): header 44 byte ghi đúng sample rate. Deepgram đọc rate từ header, nên không gửi
   tham số `encoding`/`sample_rate`; gửi kèm thì header bị đọc thành audio.
2. **Model Deepgram theo ngôn ngữ đã đo** (ghi chú trong `deepgramWav.ts`): `nova-3` + `language=vi` trả chữ rỗng
   (confidence 0, không báo lỗi), `nova-2` + `vi` gần đúng hết; `nova-3` tốt hơn cho `en`; `language=multi` ra rác.
   Query: `punctuate=true&smart_format=false`, có timeout.
3. **Phân biệt "micro không nhận tiếng" với "không ai nói"**: mobile coi peak của cả take < 64 là micro không nhận tiếng.
   **Ngưỡng này không dùng được trên board:** micro trên viền màn có noise gate, phòng yên tĩnh vẫn đo được peak 24–47,
   nên micro tốt cũng bị báo nhầm. Near dùng ngưỡng 8, tức chỉ coi số 0 tuyệt đối là micro không nhận tiếng, cộng thêm
   watchdog đếm khung cho micro chết hoặc mất (`5ddeff6`).
4. **Mức âm cho thanh sóng**: RMS → dBFS, trải −55…−10 dBFS ra 0…1 (`pcm16Level`). Near đang gửi `db` thô, app tự quy đổi.
5. **Bỏ kết quả về muộn**: mobile tăng bộ đếm take mỗi lần huỷ. Near đã có `id` cho mỗi `listen` ở app; service cũng
   phải bỏ `final` của `id` đã `cancel`.
6. **Không log chữ ra ngoài**: backend chỉ log độ dài và ngôn ngữ. Near vẫn log chữ để sửa parser (spec mục 9), nhưng chỉ
   log local, không gửi đi đâu.

**Không lấy:**

- Hold-to-talk race của mobile (nhả tay trước khi micro mở xong): Near mở micro một lần lúc khởi động và giữ ring buffer,
  nên không có khe đó.
- Đi qua backend Harness: thiết bị phải giữ token SSO của tài khoản Harness, ăn quota voice của Harness, và ngược hướng
  "sản phẩm mới, không dính Harness".

## 1. Nguyên tắc

- Giữ kiến trúc của spec: audio chỉ nằm trong `near-voice` (Python). App chỉ nhận chữ và sự kiện, mọi logic sản phẩm
  vẫn ở Dart.
- Mỗi phần là một **engine sau interface**, chọn bằng cờ dòng lệnh và biến môi trường `NEAR_*` (như B1 đã làm trong
  `near_voice/__main__.py`), không có file config riêng.
- **Mặc định local:** STT Zipformer-vi, TTS Piper vi, wake word tắt. Cloud và wake word chỉ bật bằng config.
- **Half-duplex:** loa và micro cùng nằm trên màn và không có khử tiếng vọng, nên lúc đang phát thì không nghe và không
  bắt wake word.
- **Phụ thuộc:** chỉ `sherpa-onnx`, `numpy` và thư viện chuẩn (Deepgram gọi bằng `urllib`). Riêng openWakeWord cần thêm
  `onnxruntime`, phải hỏi trước (mục 7).
- Repo public, nên không đưa lên: key Deepgram, bản ghi giọng, model.

## 2. Kiến trúc near-voice sau khi gắn

```
micro (arecord / ffmpeg trên Mac) ─► Capture ─► khung 20 ms ─┬─► RingBuffer 0,5 s (chỉ RAM)
                                                             ├─► WakeEngine  off | sherpa-kws | openwakeword ─► ev wake
                                                             └─► Segmenter (Silero VAD, chỉ khi đang listen)
                                                                    └─► SttEngine  zipformer | deepgram ─► ev final
cmd say ─► TtsEngine (Piper vi, cache) ─► Player (aplay ra loa HDMI / afplay) ─► DuplexGate chặn khung micro lúc phát
```

```
voice/
  near_voice/
    __main__.py    cờ dòng lệnh + env NEAR_*                      (đã có, B1)
    protocol.py    encode/decode JSON lines                        (đã có)
    audio.py       Capture, RingBuffer 2 s (khung có index tuyệt đối,
                   since(index)), FrameHub, wav_bytes, level_db, peak (đã có)
    vad.py, segmenter.py  Silero VAD, cắt câu 0,6 s / tối đa 8 s / chờ 4 s (đã có)
    stt.py         SttEngine, ZipformerStt (đã có); DeepgramStt (B3)
    chime.py       chuông                                          (đã có)
    server.py      VoiceServer: begin_listen(id, from_index), before_listen hooks (đã có)
    tts.py         TtsEngine, PiperTts, PhraseCache                (B4)
    player.py      phát WAV, dừng giữa chừng                       (B4)
    duplex.py      DuplexGate, cắm vào FrameHub trước Segmenter    (B5)
    wake.py        WakeEngine, NoWake, SherpaKws, sau này OpenWakeWord (C1, C4)
  tests/
```

## 3. Protocol (bổ sung mục 6 của spec, tương thích ngược)

**Đã có (`5ddeff6`):**

- `{"cmd":"finish"}`: người dùng chạm lần nữa để gửi. Nếu đã chắc có người nói (≥ 0,25 s) thì service cắt câu ngay, gửi
  `processing` rồi `final`. Nếu chưa thì gửi ngay `timeout` (`no_speech` hoặc `no_audio`). Lúc không nghe (vd. STT đang
  chạy) thì bỏ qua.
  - Phía app: chạm vào lớp phủ lúc đang nghe thì gửi `finish` và chuyển sang "đang hiểu", chờ tối đa 10 s. Nhận `timeout`
    ở bước này thì đóng lớp phủ lặng lẽ, vì người dùng dừng mà không nói gì. Chạm ở bước khác thì đóng, như `cancelTalk`.
    `cancel` vẫn còn.
- `timeout.reason`: `no_audio` chỉ khi peak < 8 (toàn số 0) hoặc watchdog thấy micro giao chưa tới nửa số khung. Phòng yên
  tĩnh với micro tốt luôn ra `no_speech`.

**App gửi thêm:**

- `{"cmd":"say","id":"…","text":"…"}`: đọc một câu. Text đã là chữ đọc được (số và giờ đã viết thành chữ ở Dart).
- `{"cmd":"stop_say"}`
- `{"cmd":"wake","on":true|false}`: app tắt wake word lúc đêm và lúc đang tập trung.

**Service gửi thêm:**

- `ready` có thêm khả năng: `{"ev":"ready","model":"…","stt":"zipformer","tts":true,"wake":"off"}`. Các trường đã có từ
  `017f60c` (hiện luôn là `tts:false`, `wake:"off"`); B4 và C1 bật lên.
- `{"ev":"wake","score":0.82}`
- `{"ev":"speaking","id":"…"}`, `{"ev":"spoken","id":"…","ms":1400}`. Lỗi TTS gửi `{"ev":"error","msg":"tts: …"}`.
- `final` có thêm `"engine":"zipformer|deepgram"`. Trường đã có từ `017f60c`; B3 thêm giá trị `deepgram`.

**Luồng wake word:**

1. Service bắt được wake word, gửi `wake`, và đánh dấu điểm cắt ở **cuối** wake word.
2. App làm đúng như khi chạm mic: hiện `listening`, gửi `listen` với `id` mới. App vẫn là nơi duy nhất cấp `id`.
3. Service bắt đầu câu từ điểm cắt, **không** lùi thêm 0,5 s pre-roll. Lùi qua wake word thì STT sẽ ra
   "HAY NÀY ĐẶT HẸN GIỜ…".
4. Sau `wake` mà 1 giây không có `listen` (app đang ở màn không cho nói, đêm…) thì service bỏ qua.

## 4. Các bước

Mỗi bước có test riêng; chưa có test và chưa chạy test thì bước đó chưa xong. Test Python: `python3 -m unittest` trong
`voice/` (không cần model, dùng engine giả). Test Dart: `flutter test <files>` trong `app/`.

### A. Đo trước khi gắn (ở `phase0/`, không đụng app)

| # | Việc | Đạt khi | Test |
|---|---|---|---|
| A1 | ✅ 16/11, `phase0` E4b: VI 23,2% (Zipformer 7,1%), EN 31,2% (Parakeet 47%), trễ p95 3,0 s (vi) và 1,5 s (en). Không đạt ngưỡng EN ≤ 15%. Chạy qua Harness (`run_stt.py --model harness-vi\|harness-en`), không thử được nova-3/vi vì backend tự chọn model. **Deepgram trên bộ E4:** thêm `--engine deepgram` vào `phase0/stt/run_stt.py decode` (bọc WAV, `nova-2`/`vi`, `nova-3`/`en`, thử lại cả `nova-3`/`vi` vì có thể đã đổi). Chạy từ board qua Wi-Fi, ghi cả trễ mạng p50/p95. **Cần đồng ý gửi bản ghi giọng (mục 7)** | Có bảng WER cạnh Zipformer-vi và Parakeet. Đáng dùng nếu tiếng Anh ≤ 15% WER và trễ p95 ≤ 1,5 s | `test_run_stt.py`: client Deepgram gọi HTTP server giả (đúng query, header, timeout, lỗi 4xx/5xx) |
| A2 | ⏸ Hoãn (TTS chưa cần). **TTS Piper vi trên board:** tải 2–3 giọng `vi_VN` bản sherpa-onnx (kiểm lại tên trong release `tts-models`, vd. `vits-piper-vi_VN-vais1000-medium`). Đo RTF, RAM trên 1 nhân A76 và 1 nhân A55; phát 10 câu mẫu của Near qua loa HDMI cho người dùng nghe | Câu khoảng 2 s tổng hợp xong ≤ 0,5 s trên A76; người dùng chấp nhận giọng | `phase0/tts/test_run_tts.py`: chọn file model, ghi WAV, tính RTF |

### B. Gắn vào `near-orangepi4pro`

| # | Việc | File chính | Test |
|---|---|---|---|
| B1 | ✅ `017f60c` (session `orangepi4pro-f3`). Khung near-voice (bước 12 của M1), tách engine ngay từ đầu: protocol, `Capture`, `RingBuffer`, `FrameHub`, `Segmenter`, `ZipformerStt`, chuông, server. Trên board: nạp model 2,8 s; STT 113–220 ms cho câu 1,7 s; idle khoảng 0,35% một nhân; RSS 140 MB | `voice/near_voice/*` | 76 test pass trên board (có test engine thật), Mac 73 pass + 3 skip |
| B2 | ✅ `017f60c`. Pattern từ mobile: `wav_bytes`, `level_db`, `peak`; `timeout reason=no_speech\|no_audio` (`no_audio` khi peak < 8 (sửa ở `5ddeff6`, trước là 64), hoặc micro giao chưa tới nửa số khung sau `no_speech_s` + 1 s); lệnh `finish` (`5ddeff6`, mục 3); bỏ `final` của `id` đã huỷ hoặc bị thay; `ready` có `stt`, `tts`, `wake`; `final` có `engine`. Phía Dart chưa đọc các trường mới (để B6) | `audio.py`, `server.py`, `protocol.py` | như B1 |
| B3 | ✅ chưa commit. Làm khác bản nháp theo mục 7: không dùng key Deepgram riêng mà đi qua backend Harness (`POST /api/voice/stt?lang=vi`, giống app mobile; backend gọi Deepgram nova-2). Board có sign-in Harness riêng (`hna_`/`hnr_`), tạo một lần bằng `voice/tools/harness_login.py` trên Mac rồi chép vào `~/near/secrets/harness-auth.json` (0600, ngoài repo); `HarnessAuth` tự gia hạn token, đọc lại file khi file đổi. `CloudFirstStt`: cloud và Zipformer chạy song song, lấy chữ cloud nếu về trong 3 s và không rỗng, còn lại (chưa sign-in, mất mạng, 429, 5xx) dùng chữ local; `final` ghi `engine`. Cờ `--stt local\|cloud` (`NEAR_STT`), unit bật `cloud` | `harness.py`, `stt.py`, `__main__.py`, `tools/harness_login.py` | `test_harness.py` (gia hạn, refresh bị từ chối, 401 thử lại 1 lần, 429/5xx, HTTP server thật), `test_harness_login.py`, `test_stt.py` (`CloudFirstSttTest`), `test_main.py` |
| B4 | ⏸ Hoãn. `PiperTts` + `PhraseCache` + `Player`: `say` → tổng hợp (cache theo text, trong RAM và `/var/cache/near/tts`), phát qua `aplay -D plughw:CARD=allwinnerhdmi,DEV=0` (Mac `afplay`); `stop_say` dừng ngay; lỗi phát chỉ ghi log | `tts.py`, `player.py` | `test_tts.py`: engine giả, cache trúng/trượt, `stop_say` giữa chừng, player lỗi |
| B5 | ⏸ Hoãn (cần khi có TTS). `DuplexGate`: lúc phát và 300 ms sau đó bỏ khung micro cho `Segmenter` và `WakeEngine`; `listen` tới lúc đang nói thì dừng nói rồi nghe | `duplex.py` | `test_duplex.py`: chuỗi sự kiện giả lập theo thời gian |
| B6 | Phần wake ✅ chưa commit (`VoiceWake`, `VoiceReady.stt`/`wake`, `VoiceFinal.engine`, `setWake`); phần TTS hoãn. Dart `VoiceClient`: thêm `VoiceWake`, `VoiceSpeaking`, `VoiceSpoken`; `VoiceReady` có khả năng (`tts`, `wake`); `timeout` có `reason`; `VoiceLink` thêm `say`, `stopSay`, `setWake` | `app/lib/voice/voice_client.dart` | `test/voice/voice_client_test.dart` (decode sự kiện mới, gửi lệnh mới, JSON lạ vẫn bỏ qua) |
| B7 | Phần wake ✅ chưa commit (`wakeWanted = !night && !focusing`, gửi `wake` khi đổi và sau mỗi lần kết nối, `wake` → `talk()` trừ khi đang nghe); phần TTS hoãn. `AppController`: `wake` → `startListening()` (bỏ qua khi đang nghe, đang có alert, hoặc đêm); `setWake(false)` khi vào đêm hoặc phiên tập trung, bật lại khi ra; `no_audio` → "Micro không nhận tiếng"; cờ `speakReplies` → `say` chỉ cho "tiếp theo là gì", nhắc việc tới giờ, sắp họp, không nói lúc đêm hay đang tập trung; đọc số và giờ thành chữ (`viSpell`, chiều ngược với `vi_numbers.dart`) | `app/lib/app/app_controller.dart`, `app/lib/app/presenter.dart`, `app/lib/core/vi_format.dart` | `test/app/app_controller_test.dart`, `test/core/vi_format_test.dart` |
| B8 | Phần STT cloud và wake ✅ chưa commit (`fetch_models.sh` thêm model KWS, `setup.sh` tạo `~/near/secrets`, unit có `NEAR_STT=cloud`, `NEAR_WAKE=kws`); phần Piper hoãn. Deploy: script tải model thêm Piper vi; `voice.env` mẫu (không có key thật); unit `near-voice` đọc `EnvironmentFile`, `taskset -c 6,7` | `deploy/*` | `deploy/test_*.py` |
| B9 | Chạy trên board: kịch bản 1 và 2 bằng giọng thật, bật TTS. Đo: ngừng nói → màn đổi (≤ 1 s), thời gian từ lệnh tới lúc bắt đầu đọc, CPU lúc màn đứng yên, TTS có lọt vào micro không | — | Báo cáo trong PR |

### C. Wake word thử nghiệm (cờ, mặc định tắt)

| # | Việc | Đạt khi | Test |
|---|---|---|---|
| C1 | ✅ PR #2 (`wake.py`: `SherpaKws`, `WakeWorker` chạy luồng riêng; `keywords/hey-near-zhen.txt`; listen ngay sau wake bắt đầu từ khung sau wake word). `WakeEngine` + `SherpaKws` port từ `phase0/wake/run_kws.py` (zh-en 3M, ngưỡng 0,15, score 2), cooldown 2 s, tắt bật bằng `wake`. Mục đích: chạy thông đường ống từ đầu tới cuối. **Biết trước là bắt kém** (E5: 2/12) | Đường ống `wake → listen → final` chạy trên board | `test_wake.py`: engine giả, cooldown, gate, tắt/bật, điểm cắt cuối wake word |
| C2 | ✅ 16/11: người dùng **giữ "Hey Near"** dù đã biết rủi ro báo nhầm với "hay này", "thầy này" (E5). Rủi ro đó được xử lý bằng dữ liệu âm ở C3 | — | — |
| C3 | Đang làm (nhánh `feat/wake-train`, thư mục `wake/`; dữ liệu và môi trường ở `wake-data/` ngoài repo). openWakeWord: bộ phân loại nhỏ trên model melspectrogram và speech embedding đóng băng. **Mẫu dương:** giọng máy Piper chạy qua sherpa-onnx TTS (LibriTTS-R 904 giọng tiếng Anh với cách viết "hey near", "hey nia"…; các giọng `vi_VN` với "hây nia", "hây ni a"…, `near_wake.texts`), cộng bản ghi thật (`near_wake.record`, 10–20 lần mỗi người, gần, xa, nói nhỏ), thêm tiếng vang phòng và tiếng ồn nền. **Mẫu âm:** đặc trưng ACAV100M có sẵn của openWakeWord, khoảng 20 giờ tiếng Việt nói chuyện, và câu gần giống đọc bằng giọng máy ("hay này", "thầy này", "hay đấy à", "hey there"…). **Chấm** (`near_wake.evaluate`): tỉ lệ bắt trên 12 lần đọc E4 của người dùng và trên bản ghi của người không có trong tập train; số lần báo nhầm mỗi giờ trên ≥ 10 giờ tiếng Việt tách riêng (khác người nói với tập train). Giấy phép từng nguồn ghi ở `wake-data`: nguồn phi thương mại (CC BY-NC) chỉ dùng cho bản demo, bản v1 phải train lại bằng dữ liệu được phép dùng thương mại | Bắt ≥ 9/10 lần; báo nhầm ≤ 1 lần mỗi 8 giờ tiếng Việt | `wake/tests`: tool thu âm (máy thu giả), danh sách câu, sinh clip (TTS giả), chấm điểm (scorer giả) |
| C4 | Engine `OpenWakeWord` (cần `onnxruntime`), chạy 1 luồng, đo CPU | ≤ 10% một nhân. Nếu quá thì thử microWakeWord (rẻ hơn, cần `tflite-runtime`) | `test_wake.py` thêm case cho engine mới (model giả) |

## 5. Thứ tự và phụ thuộc

- **B1, B2 đã xong** (`017f60c`, session `orangepi4pro-f3`, trên `feat/m1-day-strip`). Đã có sẵn ba chỗ cắm cho các
  bước sau:
  - `VoiceServer.begin_listen(id, from_index)` dùng `ring.since(from_index)` thay cho pre-roll 0,5 s (C1 cắt ở cuối wake
    word);
  - `FrameHub` là điểm chia khung duy nhất (B5 `DuplexGate`, C1 `WakeEngine` cắm vào đây);
  - `VoiceServer.before_listen` là danh sách hook nhận `id` (B5 thêm "dừng loa đang phát"; hiện đã có `chimes.stop()`).
- **A2 → B4, B5.** **A1 → B3**, mà A1 cần người dùng đồng ý gửi giọng lên Deepgram.
- **B6, B7** sửa `voice_client.dart`, `app_controller.dart`, `presenter.dart`. Hiện có `app/lib/ui/` và
  `app/lib/app/presenter.dart` **chưa commit** (bước 11 đang làm dở), nên làm B6, B7 sau khi bước 11 đã commit, hoặc trên
  nhánh tách từ đó, để không đè lên nhau.
- **C** làm sau B; làm song song với M2 được. C3 tốn công nhất (thu giọng nhiều người).

## 6. Rủi ro

- **TTS lọt vào micro:** loa HDMI và micro cùng trên màn, không có AEC. Đo trên board (session `orangepi4pro-f3`): một câu
  1,3 s phát qua loa HDMI thì micro USB chỉ giữ lại khoảng 130 ms, vì gate hoặc bộ chặn tiếng của micro. Tiếng vọng phần
  lớn đã bị lọc, nhưng vẫn giữ half-duplex (B5) để TTS không tự kích wake word. Người dùng không ngắt lời được khi máy
  đang nói, nên câu đọc phải ngắn.
- **Không test bằng cách phát lại qua loa:** cũng vì micro chặn tiếng từ loa, phát bản ghi qua loa cho micro nghe là vô
  dụng. B5, B9, C1, C4 phải test bằng giọng người thật. C3 chấm điểm offline trên file WAV, không qua loa.
- **Noise gate của micro** có thể nuốt âm đầu câu nói liền sau wake word. Đo ở B9 và C1.
- **CPU:** wake word chạy suốt ngày. Silero VAD và STT chỉ chạy khi đang `listen`, kể cả khi wake bật.
- **Cloud STT phá hai cam kết của spec:** "local-first" và "ngoài lúc listen audio không đi đâu". Chỉ bật khi người dùng
  chọn; nếu bật thì nên có dấu hiệu nhỏ trên màn lúc audio đi lên mạng.
- **Giọng Piper vi:** đọc tên riêng và từ tiếng Anh xen vào ("sync", "design") có thể dở. Nếu A2 không đạt thì cân nhắc
  TTS cloud `vi-VN` (Google, Azure), cũng là cloud nên vướng như trên.

## 7. Cần người dùng chốt

> **Đã chốt 2026-11-16:** (1) có làm STT cloud, dùng tạm qua backend Harness bằng account Harness của người dùng; (2) TTS
> tạm thời chưa cần; (3) giữ "Hey Near", làm C1 với model KWS có sẵn; (4) đã giải thích `onnxruntime`, chỉ cần khi
> tới C4. Người dùng đồng ý gửi bản ghi E4 lên Deepgram để đo A1. Sau A1: tiếng Việt local, tiếng Anh qua Harness
> bằng nút VI/EN.

1. **STT cloud có làm không?** Nếu có: key Deepgram riêng cho Near (khuyên dùng) hay đi qua backend Harness? Và có đồng ý
   gửi bản ghi E4 (`phase0/data/e4/session1.wav`, giọng của bạn) lên Deepgram để đo A1 không?
2. **TTS dùng vào đâu ở demo?** Khuyên: chỉ đọc câu trả lời "tiếp theo là gì", nhắc việc tới giờ và sắp họp, mặc định
   bật được tắt bằng config. Hay đọc cả thẻ xác nhận?
3. **Wake word:** giữ "Hey Near" hay đổi tên trước khi thu dữ liệu (C2)? Có làm C1 (KWS có sẵn, biết trước là bắt kém)
   để demo đường ống không, hay để thẳng tới C3?
4. **Phụ thuộc mới:** đồng ý thêm `onnxruntime` cho openWakeWord ở C4 không (spec đang chốt chỉ `sherpa-onnx` và `numpy`)?
