# Near trên ESP32: roadmap

> Ngày 2026-11-17. Trạng thái: **nháp, chưa code**.
> Thay cho hướng Orange Pi + Flutter. Bản đó đóng băng ở tag `demo/agent-console-v1` (demo agent console, gọi lại bằng lệnh
> `near-demo`), chỉ còn dùng làm mẫu giao diện.
> Nguồn: repo Harness (`autonomous-ai/openharness`, `origin/main` 3bde211, 17/11); wiki Waveshare và tài liệu Espressif
> (tra ngày 17/11).

## 1. Đã chốt và còn mở

Đã chốt:
- Near chạy trên ESP32.
- Màn: **Waveshare 8.8" 480×1920 MIPI-DSI** (team Hardware xác nhận 17/11).
- Dựng lại trên phần Device của Harness: núm `devices/harness-device` (ESP32-S3) và Harness Pro `devices/harness-pro`
  (ESP32-P4, 720×720). Pro gần Near nhất nên lấy làm gốc.

Còn mở (đề xuất ở mục 8): code đặt ở đâu, bản đầu nối USB hay Wi-Fi, có cho duyệt lệnh từ thanh không, board dùng ở mốc 0.

## 2. Near bản ESP32 làm gì

Thanh điều khiển cả đội agent ở mọi máy, đặt trên bàn:
- **Nhiều làn cạnh nhau**, mỗi agent một làn: máy, repo, việc, trạng thái, hoạt động gần nhất, thời gian chạy. Nhìn 1 giây
  biết agent nào đang làm, agent nào cần mình.
- **Thẻ quyết định một chạm**: trả lời câu hỏi, duyệt lệnh, xem việc xong.
- **Giao việc** bằng giọng nói hoặc chạm, chọn máy chạy.

Agent không chạy trong thanh. Agent chạy trên Mac, server hoặc cloud; thanh nói chuyện với chúng qua daemon Harness.

Khác núm và Harness Pro:
- màn dài hiện nhiều agent cùng lúc;
- trả lời và duyệt ngay trên thiết bị (hai thiết bị hiện chỉ hiện câu hỏi, trả lời phải làm trong app);
- tạo agent mới từ thiết bị (hiện chưa thiết bị nào làm được).

## 3. Phần cứng

### Màn Waveshare 8.8-DSI-TOUCH-A

| | |
|---|---|
| Độ phân giải | 480×1920, dùng nằm ngang thành 1920×480 |
| Giao tiếp | MIPI-DSI 2 lane |
| Driver IC | OTA7290B, có component `waveshare/esp_lcd_ota7290b` |
| Cảm ứng | GT9271, I2C, 10 điểm |
| Đã chạy với ESP32-P4 | Wiki Waveshare: "ESP32-P4-NANO drives the screen via MIPI 2-lane" |
| Giá lẻ | khoảng $60–80 |

Kích thước tính từ đường chéo 8,8" và tỉ lệ 4:1 (cần đo lại trên tấm thật): vùng hiển thị khoảng **217×54 mm**, mật độ
khoảng **225 ppi** (1 mm ≈ 8,9 px). Hệ quả cho giao diện:
- So với màn 11,9" của prototype (295×64 mm, 127 ppi), màn này ngắn hơn khoảng 1/4 nhưng nét gần gấp đôi. Bố cục demo
  (5 làn trên 1480×320) không chép 1:1 được: tính theo mm thì vừa **3 làn**.
- Mật độ gần Harness Pro (720×720 trên 3,95", khoảng 258 ppi), nên cỡ chữ và icon của Pro dùng lại gần như nguyên
  (nhân khoảng 0,9).
- Vùng chạm tối thiểu khoảng 9 mm, tức khoảng 80 px.

Bộ nhớ và băng thông:
- Một khung RGB565 1920×480 là 1,84 MB, gấp 1,8 lần khung 720×720 của Pro.
- Nếu xoay bằng PPA thì cần 3 khung, khoảng 5,5 MB: vừa trong 32 MB PSRAM.
- Quét màn 60 Hz đọc khoảng 110 MB/s từ PSRAM (Pro khoảng 62 MB/s). Đo thật ở mốc 0.

### Board

- ESP32-P4 **chip v3.2**, giống Harness Pro (module WT01P4C5-S1: P4 + C5, 16 MB flash, 32 MB PSRAM). Chip v1.3 đã EOL và
  không dùng chung firmware với v3.2 (Espressif PCN202600801, 20/05/2026). Dev board còn tồn kho có thể là v1.3: phải kiểm.
- Âm thanh theo Pro: 3 mic qua ES7210, loa qua ES8311 + NS4150B.
- USB-C cho nguồn và dữ liệu. Wi-Fi qua chip đi kèm (C5 trên module của Pro, C6 trên nhiều dev board), dùng từ mốc 4.

### Bản sản xuất (ước lượng)

Linh kiện chưa tính màn khoảng $14–18 ở 1.000 bộ (P4, chip Wi-Fi, flash, codec, mic, amp, USB-C, PCB). Màn rời 8,8" cần
báo giá số lượng.

## 4. Dùng lại gì từ Harness

| Mức | Thành phần |
|---|---|
| Dùng nguyên | Giao thức cáp (`cable_frame`, bộ vectors chung, `hello` + capabilities, `seq`/`resync`). Toàn bộ phía daemon (`cli/src/cable/*`, `hosts/*`, `fwPush.ts`, `deviceLink.ts`). Nhận giọng (`/api/voice/stt`, Deepgram, có tiếng Việt), route, quota. Luồng OTA (thêm khoá mới trong manifest). `cable/`, `sys/` và phần thu âm ES7210/ES8311 của Pro. Bộ sinh font có tiếng Việt |
| Sửa | Compositor habitat (tách rộng/cao, giới hạn run và vùng vẽ lại). Driver màn và cảm ứng. Chân board. Mô hình Pod và điều hướng (từ 1 agent sang nhiều làn). `board` mới trong `hello`, khoá OTA, job CI, test ảnh golden ở 1920×480 |
| Làm mới | Bố cục nhiều làn và các thẻ. Tạo agent, chọn máy và repo từ thiết bị. Luồng trả lời và duyệt. Kết nối Wi-Fi (mốc 4) |

Điểm cần biết trong code Harness:
- Firmware viết C11 trên ESP-IDF 5.5.4, **không dùng LVGL**. Hai thiết bị dùng compositor tự viết "habitat": vẽ theo dải
  24 dòng, hai buffer DMA, chỉ vẽ lại vùng thay đổi. Trên Pro, khung lâu nhất khoảng 25 ms khi đứng yên, khoảng 44,5 ms khi
  có pet chuyển động.
- Pro giả định màn vuông: code kiểm `PRO_DISPLAY_PX` cho cả hai chiều.
- Thiết bị chưa có nút trả lời, chưa tạo được agent. Duyệt quyền qua Wi-Fi bị chặn có chủ ý (`allowPermissions: false`).
  Không có wake word: chạm để nói.
- USB của P4 từng mất byte chiều host → thiết bị; Pro xử lý bằng `seq` và `resync`.
- Không có simulator; giao diện được kiểm bằng script render PNG (`pod_render.py`) và test golden trong CI.

## 5. Giao diện (khung)

Màn 1920×480 nằm ngang, chia theo mm:

```
┌─────────┬──────────────┬──────────────┬──────────────┬─────────┐
│ máy     │ làn agent 1  │ làn agent 2  │ làn agent 3  │ giao    │
│ Mac  2  │ máy · repo   │              │              │ việc    │
│ Server 1│ việc         │ cần người:   │              │ (mic)   │
│ Cloud 0 │ hoạt động    │ nở thành thẻ │              │         │
│         │ thời gian    │              │              │         │
└─────────┴──────────────┴──────────────┴──────────────┴─────────┘
```

- Thanh trái: các máy (Mac, server, cloud), số agent và trạng thái mỗi máy, số agent đang cần người.
- 3 làn cùng lúc. Nhiều agent hơn thì vuốt ngang; làn cần người được đưa lên đầu.
- Làn cần người nở thành thẻ (khoảng 110 mm), các làn khác thu nhỏ: thẻ câu hỏi (nút đáp án), thẻ duyệt lệnh (từ chối /
  cho phép), thẻ việc xong (tóm tắt, PR).
- Ô giao việc: chạm để nói; chọn máy bằng chạm hoặc nói "… trên laptop / server".
- Mẫu tham khảo: demo Orange Pi ở tag `demo/agent-console-v1` (các loại thẻ, nhịp nở/co, log).

## 6. Roadmap

Thời gian là ước lượng thô cho 1 dev làm cùng agent.

### Mốc 0: Phần cứng (1–2 tuần)

- Nối màn 8,8" vào board P4 v3.2: `esp_lcd_ota7290b`, DSI 2 lane, cảm ứng GT9271.
- Xác nhận hướng quét gốc của tấm; chọn cách xoay ngang: PPA (3 khung) hoặc để habitat vẽ thẳng theo chiều đã xoay.
- Chạy habitat ở 1920×480 (tách rộng/cao tạm). Đo: thời gian vẽ cả khung, vẽ một làn, RAM nội và PSRAM còn trống.
- Thu âm và phát chuông trên board đó.

Xong khi: thanh hiện ngang, chạm đúng chỗ, đã có số đo khung hình và bộ nhớ, đã chọn cách xoay.

### Mốc 1: Đưa Pro lên màn dài (2–3 tuần)

- Thiết bị mới cạnh Pro (tên tạm `harness-bar`), dùng lại `cable/`, `sys/`, `audio/` của Pro; habitat tách rộng/cao.
- `hello` báo `board` mới và capabilities; khoá OTA mới; CI chạy host test, build IDF, kiểm kích thước image, golden
  1920×480; script render PNG để sửa giao diện không cần board.
- Màn đầu tiên: agent thật hiện thành làn; chạm để nói gửi lời cho agent đang chọn.

Xong khi: cắm USB vào Mac đang chạy daemon Harness thì thanh hiện agent thật; nói một câu thì lời đến đúng agent; OTA cập
nhật được firmware.

### Mốc 2: Bàn điều khiển nhiều làn (3–4 tuần)

- Bố cục như mục 5: thanh máy, 3 làn, ô giao việc.
- Thẻ câu hỏi có nút trả lời, gửi qua lệnh `answer` của cáp (daemon đã nhận lệnh này).
- Thẻ duyệt lệnh cho agent do Harness quản lý (theo quyết định ở mục 8).
- Thẻ việc xong từ `turn_summary`; chuông theo mức alert / list / silent.

Xong khi: dùng hằng ngày được: trả lời và duyệt ngay trên thanh, không phải mở app.

### Mốc 3: Giao việc mới (2–3 tuần)

- Daemon: thêm lệnh cáp tạo agent (engine, máy, repo, prompt), dựa trên `agent_create` đã có ở local WebSocket.
- Thiết bị: chọn máy, chọn repo gần đây. Câu nói không nhắm agent nào thì thành agent mới; nhận cụm "trên laptop / server".

Xong khi: nói "thêm loading cho nút đăng nhập trên laptop" thì có agent mới chạy trên đúng máy.

### Mốc 4: Không cần cắm Mac (3–4 tuần)

- Wi-Fi qua chip đi kèm. Hai đường:
  - thiết bị nối thẳng backend `/api/device-ws`: cần token trên thiết bị, đăng nhập bằng QR từ điện thoại;
  - thiết bị nối daemon trong LAN theo giao thức thiết bị Autonomous OS (CPace, X25519): chưa ai thử trên ESP32.
- Duyệt quyền qua Wi-Fi đang bị chặn có chủ ý: cần thiết kế bảo mật riêng trước khi mở.

Xong khi: gập Mac, thanh vẫn hiện và điều khiển agent trên server/cloud.

### Mốc 5: Sản phẩm (song song từ mốc 2)

- Bo mạch riêng (module P4 + C5 như Pro, hoặc P4 + C6), màn rời 8,8", 3 mic, loa, USB-C, vỏ.
- Máy nạp firmware theo `flash-station.sh`; kênh OTA phát hành.
- Chứng nhận vô tuyến: dùng module đã có chứng nhận cho đỡ việc.

Xong khi: có mẫu đúng hình hài sản phẩm và BOM có báo giá.

Tổng khoảng 3 tháng tới hết mốc 4.

## 7. Rủi ro

| Rủi ro | Ảnh hưởng | Cách giảm |
|---|---|---|
| Vẽ 1920×480 chậm: gấp 1,8 lần số điểm của Pro | giật khi cuộn hoặc nở thẻ | chỉ vẽ lại làn thay đổi, ít animation; đo ở mốc 0 |
| Tấm màn quét dọc | xoay tốn bộ nhớ hoặc thời gian | PPA hoặc vẽ thẳng theo chiều xoay; chọn ở mốc 0 |
| Dev board là chip v1.3 | firmware không dùng chung với Pro | mua đúng v3.2; kiểm revision trước khi nạp như `flash.sh` của Pro |
| USB mất byte chiều host → thiết bị | mất lệnh | dùng lại `seq` / `resync` |
| Bản USB: gập Mac là thanh mất kết nối | mất câu chuyện "gập Mac vẫn chạy" | mốc 4 |
| Duyệt quyền từ thiết bị | rủi ro bảo mật | mốc 2 chỉ qua USB, chỉ agent do Harness quản lý; Wi-Fi chờ thiết kế |
| Giọng nói qua cloud có quota (10 câu/phút, theo gói) | giới hạn khi dùng nhiều | đủ cho bản đầu |
| Phần Device của Harness đang đổi hằng ngày | va chạm code | đặt chung repo, dùng chung CI (mục 8) |

## 8. Quyết định còn mở (kèm đề xuất)

1. **Code đặt ở đâu.** Đề xuất: trong repo Harness, `devices/` cạnh Pro, để dùng chung daemon, OTA, CI và vectors. Cần
   thống nhất với người giữ phần Device. Repo Near riêng thì phải chép code và sẽ lệch dần khỏi Pro.
2. **Bản đầu nối USB.** Đề xuất: có. Wi-Fi ở mốc 4.
3. **Duyệt lệnh từ thanh.** Đề xuất: mở qua USB cho agent do Harness quản lý ở mốc 2; Wi-Fi để sau khi có thiết kế bảo mật.
4. **Board cho mốc 0.** Đề xuất: hỏi team Hardware còn board Harness Pro dư không (cần cách nối màn 8,8"); không có thì mua
   dev board P4 v3.2 có cổng DSI 2 lane.
5. **Tên thiết bị** trong code và OTA (tạm `harness-bar`).

## 9. Bỏ gì so với bản Orange Pi

- Agent chạy trong hộp, cách ly, giọng nói chạy trên máy (zipformer), wake word "Hey Near", chuyển agent từ Mac sang hộp.
- Code Flutter, dịch vụ `near-voice`, image Debian của board.
- Giữ lại: demo đóng băng ở tag `demo/agent-console-v1` (lệnh `near-demo`), làm mẫu giao diện và để trình diễn ý tưởng.
