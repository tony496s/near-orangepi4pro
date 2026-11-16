# Near: app demo chạy thật trên thanh màn (thiết kế)

> Ngày 2026-11-16. Trạng thái: **chờ duyệt**.
> Thiết bị: Orange Pi 4 Pro (2×A76 + 6×A55, GPU PowerVR) và màn cảm ứng Waveshare 11,9" 1480×320.
> Tham khảo: demo HTML `near-demo.html` (5 kịch bản) và số đo Phase 0 (E1–E6).

## 1. Mục tiêu

Làm **bản demo chạy thật trên board** để cho team và nhà đầu tư xem. Bản này cũng là **sườn của v1 cho khách hàng**: phần
nào v1 cần thay thì đã nằm sau một interface, còn lại giữ nguyên.

Demo đạt khi:

1. App boot thẳng từ lúc cắm điện, không cần bàn phím hay chuột, và tự lên lại sau khi mất điện.
2. Người trình bày đi hết các kịch bản trong khoảng 5 phút mà không phải chờ giờ thật, nhờ tua giờ (mục 8).
3. Lệnh giọng tiếng Việt chạy thật trên board: chạm nút mic, nói, rồi màn đổi trong **≤ 1 giây sau khi ngừng nói**.
   Theo E4: VAD chờ 0,6 s, STT mất 0,17–0,22 s.
4. Ít nhất 8/10 câu lệnh trong kịch bản chạy đúng bằng giọng thật. Câu nào STT nghe sai thì người trình bày bơm câu đúng
   từ điện thoại, để buổi demo không bị đứt.
5. UI giữ 57,7 FPS khi chuyển cảnh; lúc màn đứng yên tốn ≤ 0,5 nhân.
6. Dùng được hằng ngày ở chế độ thường (giờ thật): hẹn giờ, ghi nhanh, nhắc việc là thật và còn nguyên sau khi reboot.

## 2. Phạm vi

**Có trong demo**, xếp theo thứ tự làm:

| Mốc | Kịch bản (theo `near-demo.html`) | Dữ liệu |
|---|---|---|
| M1 | **1. Giữ nhịp buổi sáng:** dải ngày (đồng hồ, "tiếp theo", dòng thời gian 07–21h, nền trời đổi theo giờ), hẹn giờ và phiên tập trung, hỏi "tiếp theo là gì", hết giờ thì báo nhẹ kèm chuông, nhắc 5 phút trước cuộc họp | Lịch mẫu; timer thật |
| M1 | **2. Ghi nhanh tới cuối ngày:** ghi nhanh, nhắc việc theo giờ (ghim lên dòng thời gian), tới giờ thì báo và chạm "Xong" hoặc "Nhắc lại", tổng kết cuối ngày, vuốt lên xem ngày mai, đêm thì tắt màn, chạm để xem giờ | Ghi chú và nhắc việc thật |
| M2 | **4. Lịch tuần, lịch tháng:** "tuần này có gì", "thứ năm rảnh lúc nào", chạm cột để mở ngày, lịch tháng, "còn mấy ngày tới hạn …" | Lịch mẫu |
| M3 | **3. Chart giá vàng:** mở chart bằng giọng, rê tay xem từng mốc, so với hôm qua, đặt ngưỡng, thu chart về một góc, báo một lần khi giá vượt ngưỡng | Giá mẫu |

**Không có trong demo:**

- Kịch bản 5 (chia ba cột).
- Wake word: E5 cho thấy model có sẵn không dùng được, nên demo dùng chạm để nói.
- Lệnh tiếng Anh (STT tiếng Anh sai khoảng 47%).
- Google Calendar thật, giá vàng thật.
- Ghép điện thoại bằng QR, cài Wi-Fi, OTA, nhiều người dùng.
- Tắt hẳn đèn nền ban đêm (phải vá flutter-pi). Demo dùng màn đen: đèn nền vẫn sáng ở nấc người dùng đặt.

## 3. Ràng buộc phần cứng (đã đo ở Phase 0)

- **Màn:**
  - 1480×320, app quay 270°.
  - Touch chuẩn ở mọi vị trí.
  - Độ sáng chỉ chỉnh được bằng nút sau lưng màn; phần mềm chỉ tắt hẳn được màn bằng cách cắt HDMI.
- **UI:**
  - flutter-pi bản vá vsync, không cần X hay Wayland.
  - Cảnh dải ngày đầy đủ tốn 0,3 nhân, RAM 45 MB.
  - Nhiệt độ là ràng buộc thật: màn đứng yên là chính, chỉ có animation ở các khoảnh khắc chuyển cảnh.
- **Âm thanh:**
  - Micro USB trên viền màn (ALSA card 2, mono 48 kHz) có noise gate.
  - Loa của màn chạy qua HDMI (card 0).
- **STT:** Zipformer-vi 30M int8 (sherpa-onnx 2.0.1).
  - Sai 7,1% âm tiết; 0,17 s mỗi câu trên 2 nhân A76; 211 MB RAM.
  - Silero VAD để cắt câu.
- **Lưu trữ:**
  - Rootfs mount `commit=600`, nên mọi lần ghi phải fsync.
  - Board không có pin RTC, nên phải có mạng (NTP) thì giờ mới đúng.
- **Driver HDMI:** phải bật `hpd_mask=0x1100` mỗi lần boot, và gỡ fbcon trước khi chạy app. Wrapper boot của Phase 0 đã
  làm cả hai việc và có test.

## 4. Kiến trúc

Hai tiến trình trên board, nói chuyện với nhau qua localhost:

```
              điện thoại / laptop (chỉ khi demo)
                         │ HTTP :8780 (có token)
┌────────────────────────▼─────────────────────────┐
│ near_app  (Flutter, flutter-pi)                  │
│   UI ── AppController ── Clock                   │
│              │  ├── CalendarSource  (mẫu → Google ở v1)
│              │  ├── PriceSource     (mẫu → API thật ở v1)
│              │  └── LocalStore      (ghi chú, nhắc việc, timer)
│              │ Command ◄── IntentParser (Dart)   │
│              ▲ transcript                        │
└──────────────┼───────────────────────────────────┘
               │ JSON lines, TCP 127.0.0.1:8781
┌──────────────▼───────────────────────────────────┐
│ near-voice (Python, sherpa-onnx), ghim cpu 6–7   │
│   mic card 2 → buffer → VAD → Zipformer-vi → text│
│   chuông → loa card 0                            │
└──────────────────────────────────────────────────┘
```

Vì sao voice là **tiến trình riêng**:

- Stack Python + sherpa-onnx đã chạy và đã đo ở E4.
- Ghim riêng vào A76 được.
- Voice crash thì UI vẫn sống, và restart riêng được.
- flutter-pi không có plugin âm thanh.

Vì sao **hiểu lệnh bằng Dart, trong app**: voice service chỉ biến audio thành chữ, không biết gì về lịch hay timer. Toàn
bộ logic sản phẩm nằm trong một ngôn ngữ và test được bằng `flutter test`.

## 5. App Flutter (`app/`)

Mỗi thư mục làm một việc, và chỉ phụ thuộc vào thư mục nằm trên nó trong danh sách:

- **`core/`**
  - `Clock`: interface trả về `now()`.
  - `SystemClock`: giờ thật.
  - `DemoClock`: có `jumpTo(DateTime)` và tốc độ tua (×1, ×60).
  - Mọi logic theo giờ đều đọc từ `Clock`, không gọi thẳng `DateTime.now()`. Nhờ vậy vừa tua được khi demo, vừa test được.
- **`domain/`:** model thuần Dart, không phụ thuộc Flutter.
  - `CalendarEvent`, `FocusTimer`, `Note`, `Reminder`, `PriceSeries`, `PriceAlert`.
  - `DayPlan` trả lời các câu hỏi về lịch:
    - `nextEvent(now)`;
    - `freeSlots(day, workHours)`;
    - `daysUntil(query)`;
    - tổng giờ họp và giờ tập trung trong ngày (cho màn tổng kết).
- **`domain/intent/`:** `parseCommand(String) → Command?`.
  - Lệnh là một sealed class:
    - `StartTimer(minutes, focus)`, `CancelTimer`, `WhatsNext`;
    - `AddNote(text)`, `AddReminder(text, at | after)`;
    - `ShowWeek`, `FreeSlots(weekday)`, `ShowMonth`, `DaysUntil(query)`;
    - `ShowGold`, `CompareGoldYesterday`, `SetGoldAlert(price)`, `GoHome`.
  - Hiểu được chữ số, số đọc bằng chữ ("mười lăm", "hai mươi lăm", "bốn nghìn một trăm năm mươi") và giờ nói kiểu Việt
    ("ba giờ chiều", "tám giờ rưỡi", "sau 20 phút").
  - Chấp nhận output viết hoa không dấu câu của Zipformer, và các biến thể STT hay nghe nhầm, vd. "chart" có thể ra
    "chát". Câu thay thế: "mở biểu đồ vàng".
- **`data/`:**
  - `CalendarSource` và `PriceSource` là interface.
  - Bản demo dùng `SampleCalendarSource` (lịch ngày, tuần, tháng của `near-demo.html`, sinh theo ngày thật của tuần hiện
    tại) và `SampleGoldSource` (chuỗi giá có seed, mỗi lần chạy ra cùng một số).
  - `LocalStore` lưu ghi chú, nhắc việc, timer đang chạy và ngưỡng giá vào một file JSON:
    - ghi qua file tạm, `fsync`, rồi `rename`;
    - file hỏng thì đổi tên sang `.bad` và chạy tiếp với dữ liệu rỗng.
- **`app/`:**
  - `AppController` (ChangeNotifier) giữ màn đang hiện, các lớp phủ, và bộ lập lịch.
  - Mỗi giây, bộ lập lịch kiểm: timer hết giờ, tới giờ nhắc, còn 5 phút tới họp, đã tới giờ tổng kết, đã sang đêm, giá
    vượt ngưỡng.
  - `CommandRunner` chạy một `Command`: đổi state rồi hiện thẻ xác nhận 3–4 giây.
- **`voice/`:** `VoiceClient` nói chuyện với near-voice theo protocol ở mục 6. Mất kết nối thì 2 giây sau tự nối lại.
- **`ui/`:**
  - Token màu và chữ lấy từ demo HTML. Font Be Vietnam Pro (OFL) đóng gói cùng app.
  - Widget: `Timeline`, `Sky`, `Ring`, `LineChart` (CustomPainter), `ListeningOverlay`, `ConfirmCard`.
- **`control/`:** server HTTP cho người trình bày (mục 8). Chỉ bật khi có `NEAR_DEMO=1`.

## 6. Voice service (`voice/`)

- **Thu âm:** mở micro một lần lúc khởi động, giữ một ring buffer 0,5 s **chỉ trong RAM**. Khi app gọi `listen`, đoạn đệm
  này được ghép vào đầu câu, nên âm tiết đầu không bị mất nếu người dùng nói ngay lúc vừa chạm. Ngoài lúc `listen`, audio
  không đi đâu và không được ghi ra đĩa.
- **Cắt câu:**
  - Silero VAD; im lặng 0,6 s thì coi là hết câu.
  - Một câu dài tối đa 8 s.
  - Sau 4 s mà chưa ai nói thì trả `timeout`.
- **STT:** Zipformer-vi 30M int8, 2 luồng, `taskset -c 6,7`. Model nạp sẵn lúc khởi động, có chạy warm-up.
- **Protocol:** mỗi dòng là một JSON.
  - App gửi:
    - `{"cmd":"listen","id":"…"}`
    - `{"cmd":"cancel"}`
    - `{"cmd":"chime","name":"soft|alert"}`
  - Service gửi:
    - `{"ev":"ready","model":"…"}`
    - `{"ev":"listening","id":"…"}`
    - `{"ev":"level","db":-31.5}` (10 lần/giây, để vẽ thanh sóng)
    - `{"ev":"final","id":"…","text":"…","audio_ms":1800,"stt_ms":170}`
    - `{"ev":"timeout","id":"…"}`
    - `{"ev":"error","msg":"…"}`
  - Sau này có wake word thì service gửi thêm `{"ev":"wake"}`, app không phải đổi gì.
- **Phát chuông:** file WAV ngắn phát ra card 0. Phát lỗi thì chỉ ghi log.
- **Chạy trên Mac:** cùng code đó, dùng micro của Mac, để làm vòng lặp dev.

## 7. Màn hình và luồng

- **Màn nền** (mỗi lúc một màn): `ambient` (mặc định), `focus` (khi phiên tập trung đang chạy), `tomorrow`, `recap`,
  `week`, `month`, `day`, `gold`.
  - Không ai chạm trong 60 giây thì mọi màn trừ `focus` tự quay về `ambient`.
- **Lớp phủ** (chồng lên màn nền):
  - `listening`: thanh sóng, rồi "đang hiểu…".
  - `confirm`: thẻ xác nhận, tự tắt.
  - `alert`: hết giờ, tới giờ nhắc, sắp họp, giá vượt ngưỡng. Có nút chạm; không ai chạm thì 10 phút sau tự tắt.
- **Chế độ đêm:**
  - Từ 23:00 tới 06:30 (cấu hình được), màn chuyển đen.
  - Chạm thì hiện đồng hồ mờ 10 giây.
  - Riêng alert vẫn hiện được.
- **Cử chỉ:**
  - nút mic ở góc phải: nói;
  - vuốt lên: xem ngày mai;
  - vuốt xuống: quay về;
  - chạm vào sự kiện hay cột ngày: mở chi tiết;
  - rê trên chart: xem từng mốc.

Đường đi của một câu lệnh:

1. Người dùng chạm mic. App gửi `listen` và hiện `listening` ngay, không chờ service trả lời.
2. Service gửi `final`.
3. `parseCommand` dịch chữ ra lệnh, `CommandRunner` chạy lệnh, rồi hiện thẻ `confirm`.
4. Không hiểu lệnh thì hiện "Chưa hiểu: «…»" kèm 3 câu mẫu.

## 8. Chế độ demo (cho người trình bày)

Chạy với `NEAR_DEMO=1`, app dùng `DemoClock` và mở HTTP ở cổng 8780.

- Mọi request phải gửi kèm token.
- Token lấy từ `NEAR_DEMO_TOKEN`. Không đặt thì mỗi lần chạy app tự sinh một token ngẫu nhiên và ghi vào log.
- Khi đã đăng nhập, trang điều khiển nhớ token trong `localStorage` của điện thoại.

- `GET /`: trang điều khiển, mở được trên điện thoại. Có các nút nhảy tới từng bước của kịch bản, ô gõ câu lệnh, và
  hiện trạng thái.
- `POST /api/clock {"at":"09:20"}` hoặc `{"speed":60}`: tua giờ.
- `POST /api/say {"text":"hẹn giờ 25 phút để tập trung"}`: bơm một câu, đi y như câu nghe từ STT (dùng khi phòng ồn).
- `POST /api/reset`: đưa dữ liệu demo về ban đầu.
- `GET /api/state`: màn đang hiện, giờ trên app, câu nghe được gần nhất, độ trễ STT.

Danh sách bước của từng kịch bản để trong một file dữ liệu (`demo/scenarios.json`), cùng giờ và câu nói với
`near-demo.html`.

Ở v1, server này trở thành API để ghép điện thoại và chỉnh cài đặt. Khi đó phải có xác thực thật, và chế độ demo bị tắt.

## 9. Xử lý lỗi

| Lỗi | App làm gì |
|---|---|
| near-voice chưa chạy hoặc bị crash | Nút mic mờ đi và hiện "giọng nói đang khởi động". Mọi thứ khác vẫn dùng bằng chạm được. App tự nối lại; systemd restart service |
| STT ra chữ rỗng hoặc hết giờ chờ | Lớp phủ đổi thành "Không nghe rõ, chạm để nói lại" |
| Không dịch được ra lệnh | "Chưa hiểu: «…»" kèm câu mẫu. Chữ nghe được được ghi log để sửa parser |
| Lệnh thiếu thông tin ("nhắc anh gọi chị Lan") | Hỏi lại bằng chữ, kèm nút chọn nhanh: "Lúc nào? 15 phút · 1 giờ · 15:00" |
| Ghi file lỗi | Giữ trong RAM, hiện chấm cảnh báo nhỏ, 30 giây sau thử ghi lại |
| File state hỏng | Đổi tên sang `.bad`, chạy với dữ liệu rỗng, ghi log |
| Giờ hệ thống còn sai (chưa có NTP) | Hiện "đang chờ giờ chuẩn" thay cho đồng hồ, và hoãn các nhắc việc. Chế độ demo không bị ảnh hưởng |
| App crash | systemd restart. Nếu crash ngay lúc boot thì guard của wrapper bỏ qua UI một lần, như ở Phase 0 |

## 10. Test

- **Dart unit:**
  - `parseCommand` với khoảng 60 câu, gồm cả output thật của Zipformer ở E4 (vd. "ĐẶT HẸN GIỜ MƯỜI LĂM PHÚT").
  - Số và giờ nói bằng chữ.
  - Các câu hỏi của `DayPlan`.
  - Bộ lập lịch: timer, nhắc việc, sắp họp, đêm, ngưỡng giá. Dùng `DemoClock` nên không phải chờ.
  - `LocalStore`: ghi nguyên tử, file hỏng.
- **Widget test ở 1480×320:**
  - Mỗi màn vẽ không bị tràn chữ, kể cả với chuỗi tiếng Việt dài.
  - Cử chỉ chuyển đúng màn.
  - Các trạng thái của lớp phủ.
- **Python unit:**
  - Mã hoá và giải mã protocol.
  - State machine cắt câu, chạy với khung giả lập.
  - Ring buffer đệm đầu câu.
- **Trên board** (chạy tay, không đưa vào CI):
  - Chạy từng kịch bản qua `/api/say` và bằng giọng thật.
  - Đo thời gian từ lúc ngừng nói tới lúc màn đổi.
  - Đo FPS và CPU bằng công cụ của Phase 0.

## 11. Cấu trúc repo

```
app/        Flutter app (near_app)
voice/      near-voice: Python + sherpa-onnx, cùng test
deploy/     build (flutterpi_tool build --arch=arm64 --release), rsync lên board,
            unit systemd (near-app, near-voice), wrapper boot lấy từ Phase 0
demo/       scenarios.json, trang điều khiển
docs/       spec và kế hoạch
```

Repo để **public**, nên không đưa lên: bản ghi giọng, model (tải bằng script), IP và tên mạng của board, secret. Dữ liệu
Phase 0 vẫn để local.

## 12. Từ demo lên v1

- **Giữ nguyên:**
  - kiến trúc hai tiến trình và protocol voice;
  - `Clock`, `domain/`, `IntentParser`, `LocalStore`;
  - các màn hình;
  - wrapper boot và unit systemd.
- **Thay:**
  - `SampleCalendarSource` → `GoogleCalendarSource` (đăng nhập qua điện thoại);
  - `SampleGoldSource` → API giá thật;
  - server demo → API ghép điện thoại và cài đặt, có xác thực;
  - màn đen ban đêm → tắt hẳn đèn nền (vá flutter-pi);
  - chạm để nói → thêm wake word khi đã train được model riêng.
- **Thêm:** QR và cài Wi-Fi, OTA, splash lúc boot, cắt bớt service thừa để boot dưới 10 giây.

## 13. Cần chốt trước khi code

1. Phạm vi và thứ tự: M1 (kịch bản 1 và 2), M2 (lịch), M3 (giá vàng); bỏ kịch bản 5.
2. Có server điều khiển và bơm câu cho người trình bày (mục 8).
3. Nút mic cố định ở góc phải. Phương án khác: chạm giữ ở bất kỳ đâu.
