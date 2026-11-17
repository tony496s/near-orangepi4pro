# Near: hộp chạy agent có sẵn bàn điều khiển (demo agent console)

> Ngày 2026-11-17. Trạng thái: **đã làm xong, đang chạy trên board** (nhánh `feat/agent-console`). Cập nhật 17/11 trưa:
> thêm điều khiển agent trên máy khác (MacBook, server build) và cảnh chuyển agent từ Mac đang ngủ vào hộp.
> Thiết bị: Orange Pi 4 Pro và màn cảm ứng Waveshare 11,9" 1480×320.
> Bối cảnh và lý do chọn hướng: `research/product-research.vi.md`, mục 15 (repo nghiên cứu, ngoài repo này).

## 1. Thông điệp

Các thiết bị điều khiển agent hiện có đều chỉ là **remote cho một chiếc laptop đang mở**: núm và Pro của Harness, SlashVibe,
MX Keypad, Remote Control trên điện thoại. Gập laptop lại là agent dừng.

Near tự là một máy tính, nên có thể làm **cái hộp chạy agent, có sẵn bàn điều khiển**:

1. **Agent chạy trong hộp.** Gập Mac, agent vẫn chạy. Mỗi Claude Code tốn khoảng 340 MB RAM (đo trên Mac), nên board 6 GB
   chứa được 8–10 agent.
2. **Cách ly.** Agent chạy full-auto trong hộp riêng, không chạm file, khoá ký hay token của máy chính. Lệnh an toàn thì hộp
   tự cho qua; chỉ lệnh nguy hiểm mới phải hỏi người.
3. **Giọng nói chạy trên board**: tiếng Việt nhận ngay trên board (khoảng 0,2 giây một câu), không lên cloud, không quota.
4. **Vẫn điều khiển được agent trên máy khác**, như núm và điện thoại đã làm (qua Harness): agent trên MacBook, trên server
   build. Khác ở chỗ khi MacBook ngủ, agent đang dở việc trên đó **chuyển vào hộp** chạy tiếp. Việc board không làm được
   (build iOS) thì hộp giao cho server build: hộp là chỗ điều phối, không phải chỗ làm hết.

Câu chốt: *điều khiển cả đội agent, ở máy nào cũng được, mà không cần mở laptop.*

## 2. Cái gì thật, cái gì dựng sẵn

| Phần | Trong demo |
|---|---|
| App trên màn bar, cảm ứng, chạy thẳng khi cắm điện | **Thật** (Flutter trên flutter-pi, như app Near) |
| Giọng nói: chạm ô "Giao việc" hoặc nói "Hey Near", rồi nói việc cần giao | **Thật**: tiếng Việt qua mô hình zipformer trên board, tiếng Anh qua Harness (nút VI/EN). Câu nghe được thành tên làn agent mới |
| Wake word "Hey Near" | Thật nhưng **chưa nhạy** (bắt khoảng 1/6 lần ở Phase 0): khi demo nên chạm |
| Các agent, log, câu hỏi, lệnh nguy hiểm, PR, CI, TestFlight | **Dựng sẵn** theo kịch bản (`app/lib/agents/console_script.dart`). Không có Claude Code nào chạy thật |
| MacBook, server build, việc chuyển agent giữa máy | **Dựng sẵn**. Board không tự biết Mac đã gập: người demo chạm dòng "MacBook" trên thanh trái lúc gập máy. Bản thật sẽ đi qua Harness (daemon trên từng máy, như núm Harness đang dùng) |
| Số trên thanh trái (số agent mỗi máy, lệnh tự cho qua) | Dựng sẵn |

## 3. Màn hình (1480×320)

```
┌─────────────┬──────────────┬──────────────┬──────────────┬─────────────────────────────┬────────┐
│ NEAR        │ TRONG HỘP    │ TRONG HỘP    │ TRÊN MACBOOK │ TRONG HỘP         (làn mới) │  (mic) │
│ 4 agent     │ ● harness-   │ ● near-app   │ ● harness-web│ ● harness-mobile            │ Giao   │
│ ● Hộp Near  │   backend    │   Codex      │ task         │   khi cần người: làn nở ra  │ việc   │
│ ● MacBook   │ log chạy…    │ log chạy…    │ log chạy…    │   thành thẻ hỏi / thẻ đỏ /  │        │
│ ● Server    │ ▬▬▬▬ 6:22    │ ▬▬▬▬ 11:50   │ ▬▬▬ 3:40     │   thẻ duyệt / chuyển / ship │  VI    │
└─────────────┴──────────────┴──────────────┴──────────────┴─────────────────────────────┴────────┘
```

- **Thanh trái:** tổng số agent và **danh sách máy**: Hộp Near (luôn bật), MacBook (đang mở / đã ngủ), Server build (rảnh /
  đang build), mỗi máy kèm số agent. Dòng MacBook bấm được: chạm để cho Mac ngủ hoặc thức.
- **Mỗi cột là một agent** chạy song song: máy nó đang chạy (TRONG HỘP / TRÊN MACBOOK / TRÊN SERVER), repo, engine
  (Claude/Codex), việc, log 6–8 dòng cuối (lệnh bằng font mono), thanh tiến độ, trạng thái, thời gian chạy. Tối đa 5 cột.
- **Cột nào cần người thì nở rộng** (560–700 px), các cột khác co lại. Năm loại thẻ:
  - *Mac vừa ngủ*: agent trên MacBook đang dở việc; [★ Chuyển vào hộp] [Để đó]. Chuyển thì cột đổi nhãn sang TRONG HỘP và
    chạy tiếp; để đó thì cột mờ đi, chờ Mac thức.
  - *Agent hỏi*: câu hỏi và các nút trả lời; nút đề xuất có ★.
  - *Lệnh nguy hiểm* (viền đỏ, chuông báo): hiện trọn lệnh `git push --force origin main` và hậu quả; [Từ chối] [Cho phép].
  - *Xong, chờ duyệt*: màn trước/sau (nút đăng nhập có spinner), test 42/42, diff; [Duyệt & tạo PR] [Làm lại].
  - *Ship*: Build iOS → Ký app → Upload → Apple xử lý. Ba chặng đầu ghi rõ chạy **trên Server build** (board ARM không
    build được iOS, hộp giao việc cho máy build). Xong thì chuông báo "Bản 0.1.71 đã lên TestFlight".
- **Ô "Giao việc"** (mép phải): mic. Đang nghe thì ô nở ra với cột sóng âm; đang chép lời thì ghi "chạy ngay trên board,
  không lên cloud".
- **Màn so sánh** "Vì sao là Near": Near / núm và Pro Harness / SlashVibe, MX Keypad / Remote trên điện thoại / Mac mini,
  theo các cột chạy agent ở đâu, gập laptop thì sao, cách ly, điều khiển agent máy khác, điều khiển, giá.

## 4. Kịch bản demo (khoảng 2 phút)

| # | Người demo làm | Thanh hiện |
|---|---|---|
| 1 | Chỉ vào thanh, MacBook vẫn mở trên bàn | 3 agent: 2 trong hộp, 1 trên MacBook. Thanh trái liệt kê 3 máy |
| 2 | **Gập MacBook**, rồi chạm dòng **MacBook** trên thanh trái | Cột harness-web dừng, nở thành thẻ "MacBook vừa ngủ". Các cột trong hộp vẫn chạy |
| 3 | Chạm **★ Chuyển vào hộp** | Cột đổi nhãn sang TRONG HỘP, kéo nhánh và phiên làm việc rồi chạy tiếp |
| 4 | Chạm ô **Giao việc**, nói: *"Thêm hiệu ứng chờ cho nút đăng nhập"*, chạm lần nữa (hoặc ngừng nói, máy tự dừng) | Cột mới mở ra, tên đúng câu vừa nói |
| 5 | Khoảng 6 giây sau agent hỏi; chạm **★ Trong nút** | Cột mới nở thành thẻ hỏi, trả lời xong co lại chạy tiếp |
| 6 | Khoảng 6 giây sau, agent backend muốn `git push --force`; chạm **Từ chối** | Thẻ đỏ, chuông báo. Agent tự chuyển sang tạo nhánh và PR #129 |
| 7 | Agent ở cột mới xong; chạm **Duyệt & tạo PR** | Thẻ trước/sau, test 42/42 → "PR #128 · CI ✓", hiện nút **Ship bản test** |
| 8 | Chạm **Ship bản test** (hoặc nói *"ship bản test"*) | Build iOS, ký, upload chạy **trên Server build**; Server build trên thanh trái chuyển "đang build". Xong có chuông báo và dòng "đã lên TestFlight" |
| 9 | Khoảng 8 giây sau màn so sánh tự hiện; chạm để đóng | "Gập laptop, đội agent vẫn chạy." |

**Giao việc cho máy khác bằng giọng:** thêm *"… trên laptop"* hoặc *"… trên server"* vào cuối câu, ví dụ *"chạy test giao
diện trên server"*. Cột mới mở trên máy đó, và cụm "trên …" được bỏ khỏi tên việc. Không nói máy thì việc chạy trong hộp.
MacBook đang ngủ thì việc giao cho MacBook chạy trong hộp. Đo trên board: "laptop" và "server" được nhận đúng; "macbook" có
lúc thành "ma quốc", "máy chủ" thành "mái chủ" (app hiểu cả các dạng này), nên khi demo **nói "laptop" và "server"**.

**Câu nói nên dùng:** câu thuần Việt được nhận đúng hoàn toàn. Đo trên board ngày 17/11 với giọng đọc máy: "thêm hiệu ứng
chờ cho nút đăng nhập" nhận đúng 100%. Từ tiếng Anh thì bị nghe thành âm Việt ("loading" thành "leo đình", "login" thành
"lou in", "ship" thành "syp"), nên app có bảng sửa các từ dev hay gặp (`app/lib/agents/dev_words.dart`). Muốn nói tiếng Anh cả
câu thì chạm nút **VI** để chuyển sang **EN** (đi qua Harness, cần mạng).

## 5. Điều khiển ẩn cho người demo

| Thao tác | Tác dụng |
|---|---|
| Chạm thanh trái | Mở màn so sánh |
| Chạm dòng **MacBook** trên thanh trái | Cho Mac ngủ (cột trên Mac dừng, hỏi chuyển vào hộp) hoặc thức lại |
| **Chạm đúp** thanh trái | Bật/tắt **tự chạy**: Mac tự ngủ và agent tự chuyển vào hộp, hộp tự giao việc, tự trả lời thẻ (chọn phương án an toàn), tự ship, hiện màn so sánh rồi lặp lại. Thanh trái ghi "NEAR · TỰ CHẠY". Dùng khi để máy cho người khác xem một mình |
| **Chạm giữ** thanh trái | Về cảnh mở đầu (3 agent, Mac thức) |
| **Chạm giữ** ô Giao việc | Giao việc mẫu "Thêm loading cho nút đăng nhập" mà không cần nói (phòng ồn quá). Đang nghe thì chạm giữ để huỷ |
| `kill -USR1 $(pidof flutter-pi)` | Bắt đầu nghe, như chạm ô Giao việc |
| `kill -USR2 $(pidof flutter-pi)` | Về cảnh mở đầu |

## 6. Chạy trên board

Bundle nằm ở `~/near/app-agents`, tách khỏi app Near cũ ở `~/near/app`. Một drop-in systemd chuyển `near-app` sang bundle
này:

```
# /etc/systemd/system/near-app.service.d/agents.conf
[Service]
Environment=NEAR_BUNDLE=/home/orangepi/near/app-agents
Environment=NEAR_MODE=agents
# thêm dòng sau nếu muốn khởi động là tự chạy luôn:
# Environment=NEAR_AGENTS_AUTOPLAY=1
```

- Cập nhật: `deploy/build.sh`, rồi `rsync -a --delete --exclude flutter-pi app/build/flutter-pi/aarch64-generic/
  <board>:near/app-agents/`, rồi `sudo systemctl restart near-app`. Lần đầu thì chép `~/near/app/flutter-pi` (bản vá vsync)
  vào `~/near/app-agents/`.
- Quay về app Near cũ: `sudo rm /etc/systemd/system/near-app.service.d/agents.conf && sudo systemctl daemon-reload &&
  sudo systemctl restart near-app`.
- `near-voice` dùng chung, không đổi gì.

## 7. Code

Tất cả nằm trong `app/lib/agents/`; app Near cũ không bị đổi gì, chỉ `main.dart` rẽ nhánh khi `NEAR_MODE=agents`.

- `console_model.dart`: máy (`Machine`), làn (`Lane`), thẻ (`QuestionCard`, `DangerCard`, `ReviewCard`, `HandoffCard`,
  `ShipCard`), các bước kịch bản (`Say`, `Ask`, `Wait`, `Raise`, `MoveTo`, `ShipStage`, `Finish`).
- `console_script.dart`: kịch bản từng agent. Các làn phối hợp qua cờ: backend chờ `asked` mới đòi push --force; làn giao bằng
  giọng chờ `danger-done` mới xin duyệt; harness-web chờ `approved`. Trong lúc chờ, làn vẫn in log nhàn rỗi nên trông vẫn
  đang chạy.
- `agent_console.dart`: controller (tick 200 ms, giọng nói, chọn thẻ, Mac ngủ/thức và chuyển agent vào hộp, ship, tự chạy).
- `dev_words.dart`: sửa từ dev bị nghe nhầm, và nhận cụm chỉ máy ("trên laptop", "trên server").
- `console_layout.dart`: chia bề ngang cho các cột (cột có thẻ được nở, cột khác tối thiểu 125 px).
- `console_app.dart`, `why_screen.dart`: giao diện.
- Font log: DejaVu Sans Mono (`fonts/DejaVu-LICENSE.txt`), cũng là font dự phòng cho ✓ ✗ ★. Dòng log có chữ Việt thì dùng Be
  Vietnam Pro, vì font mono xếp dấu chồng (ỗ, ữ) sai.

Test: `flutter test test/agents/` (controller, kịch bản đủ một vòng, tự chạy, sửa từ, chia cột, giao diện từng cảnh ở
1480×320). `NEAR_SHOTS=<thư mục> flutter test test/agents/console_app_test.dart` chụp PNG từng cảnh.
