import 'package:flutter_test/flutter_test.dart';
import 'package:near_app/domain/intent/commands.dart';
import 'package:near_app/domain/intent/parser.dart';
import 'package:near_app/domain/strip_layout.dart';

void main() {
  final now = DateTime(2026, 11, 16, 14, 12);
  Command? p(String s) => parseCommand(s, now);

  group('cloud (Deepgram nova-2 vi) style: sentence case, punctuation, digits', () {
    test('the same commands as the Zipformer ones', () {
      expect(p('Đặt hẹn giờ 15 phút.'), const StartTimer(Duration(minutes: 15), focus: false));
      expect(p('Hẹn giờ 25 phút để tập trung.'), const StartTimer(Duration(minutes: 25), focus: true));
      expect(p('Hủy hẹn giờ.'), isA<CancelTimer>());
      expect(p('Tiếp theo là gì?'), isA<WhatsNext>());
      expect(p('Nhắc anh gọi cho chị Lan lúc 3 giờ chiều.'), AddReminder('Gọi cho chị Lan', DateTime(2026, 11, 16, 15)));
      expect(p('Ghi lại mua sữa và trứng trên đường về.'), const AddNote('Mua sữa và trứng trên đường về'));
      expect(p('Tắt màn hình đi.'), isA<ScreenOff>());
    });

    test('a wake word left at the start is dropped', () {
      expect(p('Hey Near, tiếp theo là gì?'), isA<WhatsNext>());
    });
  });

  group('real Zipformer-vi 30M transcripts from Phase 0 E4', () {
    test('timers', () {
      expect(p('ĐẶT HẸN GIỜ MƯỜI LĂM PHÚT'), const StartTimer(Duration(minutes: 15), focus: false));
      expect(p('HẸN GIỜ HAI MƯƠI LĂM PHÚT ĐỂ TẬP TRUNG'), const StartTimer(Duration(minutes: 25), focus: true));
      expect(p('BẬT CHẾ ĐỘ TẬP TRUNG TRONG MỘT TIẾNG'), const StartTimer(Duration(hours: 1), focus: true));
      expect(p('CÒN BAO NHIÊU PHÚT NỮA'), isA<TimeLeft>());
      expect(p('HỦY HẸN GIỜ'), isA<CancelTimer>());
    });

    test('"hẹn giờ" misheard as "hiện giờ" (seen on the board 16/11) is a timer only next to a duration or a stop verb', () {
      expect(p('HIỆN GIỜ HAI MƯƠI LĂM PHÚT ĐỂ TẬP TRUNG'), const StartTimer(Duration(minutes: 25), focus: true));
      expect(p('HIỆN GIỜ MƯỜI PHÚT'), const StartTimer(Duration(minutes: 10), focus: false));
      expect(p('ĐẶT HIỆN GIỜ MƯỜI LĂM PHÚT'), const StartTimer(Duration(minutes: 15), focus: false));
      expect(p('DỪNG HIỆN GIỜ'), isA<CancelTimer>());
      expect(p('HỦY HIỆN GIỜ'), isA<CancelTimer>());
      // "hiện giờ" also means "right now": those sentences must keep their meaning.
      expect(p('HIỆN GIỜ LÀ MẤY GIỜ'), isA<WhatTime>());
      expect(p('HIỆN GIỜ CÒN BAO NHIÊU PHÚT'), isA<TimeLeft>());
      expect(p('HIỆN GIỜ TÔI CÓ MƯỜI PHÚT RẢNH'), isNull);
      expect(p('HIỆN GIỜ TẮT MÀN HÌNH ĐI'), isA<ScreenOff>());
    });

    test('reminder that lost "chiều" still lands at 15:00', () {
      expect(p('NHẮC ANH GỌI CHO CHỊ LAN LÚC BA GIỜ'), AddReminder('Gọi cho chị Lan', DateTime(2026, 11, 16, 15)));
    });

    test('notes', () {
      expect(p('GHI LẠI MUA SỮA VÀ TRỨNG TRÊN ĐƯỜNG VỀ'), const AddNote('Mua sữa và trứng trên đường về'));
      expect(p('GHI CHÚ GỬI BÁO CÁO CHO KHÁCH TRƯỚC THỨ SÁU'), const AddNote('Gửi báo cáo cho khách trước thứ sáu'));
    });

    test('questions and screen', () {
      expect(p('TIẾP THEO LÀ GÌ'), isA<WhatsNext>());
      expect(p('LỊCH CHIỀU NAY CỦA ANH CÓ GÌ'), isA<WhatsNext>());
      expect(p('CUỘC HỌP TIẾP THEO MẤY GIỜ'), isA<WhatsNext>());
      expect(p('BÂY GIỜ LÀ MẤY GIỜ'), isA<WhatTime>());
      expect(p('TẮT MÀN HÌNH ĐI'), isA<ScreenOff>());
    });

    test('rescheduling is understood but not supported yet', () {
      expect(p('DỜI CUỘC HỌP TEAM DESIG SANG TÁM GIỜ RƯỠI'), isA<NotSupported>());
      expect(p('RỜI CUỘC HỌP DEXI SANG TÁM GIỜ RƯỠI'), isA<NotSupported>());
    });
  });

  group('typed text and the demo script', () {
    test('punctuation, case and a leading wake phrase are ignored', () {
      expect(p('Hey Near, hẹn giờ 25 phút để tập trung.'), const StartTimer(Duration(minutes: 25), focus: true));
      expect(p('Ghi lại: mua sữa và trứng trên đường về.'), const AddNote('Mua sữa và trứng trên đường về'));
    });

    test('reminders with a part of day, a delay, or tomorrow', () {
      expect(p('Nhắc anh gọi cho chị Lan lúc ba giờ chiều.'), AddReminder('Gọi cho chị Lan', DateTime(2026, 11, 16, 15)));
      expect(p('nhắc anh đứng dậy sau 20 phút'), AddReminder('Đứng dậy', DateTime(2026, 11, 16, 14, 32)));
      expect(p('nhắc em uống nước 10 phút nữa'), AddReminder('Uống nước', DateTime(2026, 11, 16, 14, 22)));
      expect(p('nhắc anh gọi chị Lan sau 2 phút'), AddReminder('Gọi chị Lan', DateTime(2026, 11, 16, 14, 14)));
      expect(p('nhắc anh nộp báo giá lúc tám giờ rưỡi sáng mai'),
          AddReminder('Nộp báo giá', DateTime(2026, 11, 17, 8, 30)));
      expect(p('nhắc tôi họp với khách 15:30'), AddReminder('Họp với khách', DateTime(2026, 11, 16, 15, 30)));
    });

    test('a reminder without a time keeps the text and asks later', () {
      expect(p('nhắc anh mua quà sinh nhật mẹ'), const AddReminder('Mua quà sinh nhật mẹ', null));
    });

    test('verbs with free text win over keywords inside the text', () {
      expect(p('ghi lại: tắt màn hình phòng họp'), const AddNote('Tắt màn hình phòng họp'));
      expect(p('ghi lại nhắc khách gửi hợp đồng'), const AddNote('Nhắc khách gửi hợp đồng'));
    });

    test('timer variants', () {
      expect(p('bắt đầu tập trung'), const StartTimer(Duration(minutes: 25), focus: true));
      expect(p('hẹn giờ nửa tiếng'), const StartTimer(Duration(minutes: 30), focus: false));
      expect(p('hẹn giờ 1 phút để tập trung'), const StartTimer(Duration(minutes: 1), focus: true));
      expect(p('dừng tập trung'), isA<CancelTimer>());
      expect(p('huỷ hẹn giờ'), isA<CancelTimer>(), reason: 'old tone placement');
      expect(p('hẹn giờ'), isNull, reason: 'no duration');
    });

    test('home layout: three columns or one', () {
      expect(p('chia màn ba cột: lịch, giá vàng, hẹn giờ'), isA<SplitColumns>(), reason: '"hẹn giờ" in the list is a column');
      expect(p('CHIA MÀN BA CỘT LỊCH GIÁ VÀNG HẸN GIỜ'), isA<SplitColumns>());
      expect(p('mở ba cột'), isA<SplitColumns>());
      expect(p('về một cột'), isA<SingleColumn>(), reason: 'not "về" = go home');
      expect(p('VỀ MỘT CỘT'), isA<SingleColumn>());
      expect(p('về dải ngày'), isA<SingleColumn>());
      expect(p('quay lại'), isA<GoHome>());
      expect(p('hẹn giờ 45 phút'), const StartTimer(Duration(minutes: 45), focus: false));
    });

    test('the example sentences shown on the strip are understood; the first is a 10-minute focus', () {
      for (final e in examples) {
        expect(p(e), isNotNull, reason: e);
      }
      expect(p(examples.first), const StartTimer(Duration(minutes: 10), focus: true));
    });

    test('naming the columns: the set in the order said', () {
      expect(p('chia màn ba cột: lịch, giá vàng, hẹn giờ'), const SplitColumns([Panel.calendar, Panel.gold, Panel.timer]));
      expect(p('chia màn hai cột lịch và tỷ giá'), const SplitColumns([Panel.calendar, Panel.fx]));
      expect(p('chia màn ba cột hẹn giờ vàng lịch'), const SplitColumns([Panel.timer, Panel.gold, Panel.calendar]));
      expect(p('mở ba cột'), const SplitColumns(), reason: 'no names: the remembered set');
      expect(p('chia màn ba cột lịch'), const SplitColumns(), reason: 'one name is not a set');
    });

    test('changing one column: "đổi cột giữa sang tỷ giá đô la"', () {
      expect(p('đổi cột giữa sang tỷ giá đô la'), const SwapPanel(Panel.fx, index: 1));
      expect(p('ĐỔI CỘT GIỮA SANG TỈ GIÁ ĐÔ LA'), const SwapPanel(Panel.fx, index: 1), reason: 'STT writes "tỉ"');
      expect(p('đổi cột giữa sang đô la'), const SwapPanel(Panel.fx, index: 1));
      expect(p('chuyển cột phải thành giá vàng'), const SwapPanel(Panel.gold, index: -1));
      expect(p('đổi cột thứ nhất sang hẹn giờ'), const SwapPanel(Panel.timer, index: 0));
      expect(p('đổi cột ba sang lịch'), const SwapPanel(Panel.calendar, index: 2));
      expect(p('đổi vàng sang tỷ giá'), const SwapPanel(Panel.fx, from: Panel.gold));
      expect(p('đổi cột sang tỷ giá'), const SwapPanel(Panel.fx));
      expect(p('đổi lịch họp sang thứ năm'), isA<NotSupported>(), reason: 'no panel after "sang": moving a meeting');
      expect(p('chuyển cuộc họp sang ba giờ'), isNot(isA<SwapPanel>()));
      expect(p('báo anh khi vàng vượt 4.150 đô'), const SetGoldAlert(4150), reason: 'not a column');
    });

    test('gold (scenario 3)', () {
      expect(p('mở chart vàng sáng nay'), isA<ShowGold>());
      expect(p('MỞ CHÁT VÀNG'), isA<ShowGold>(), reason: 'Zipformer spelling');
      expect(p('mở biểu đồ vàng'), isA<ShowGold>());
      expect(p('so với hôm qua thì sao'), isA<CompareGoldYesterday>());
      expect(p('báo anh khi vàng vượt 4.150 đô'), const SetGoldAlert(4150));
      expect(p('BÁO ANH KHI VÀNG VƯỢT BỐN NGHÌN MỘT TRĂM NĂM MƯƠI ĐÔ'), const SetGoldAlert(4150));
      expect(p('báo khi vàng xuống dưới 4100'), const SetGoldAlert(4100));
      expect(p('ghi lại mua vàng cho mẹ'), isA<AddNote>(), reason: 'a note keeps its words');
    });

    test('week and month (scenario 4)', () {
      expect(p('tuần này anh có gì'), isA<ShowWeek>());
      expect(p('TUẦN NÀY ANH CÓ GÌ'), isA<ShowWeek>());
      expect(p('thứ năm rảnh lúc nào'), const FreeSlots(DateTime.thursday));
      expect(p('THỨ SÁU RẢNH LÚC NÀO'), const FreeSlots(DateTime.friday));
      expect(p('mở lịch tháng này'), isA<ShowMonth>());
      expect(p('còn mấy ngày tới hạn gửi báo giá'), const DaysUntil('gửi báo giá'));
      expect(p('CÒN MẤY NGÀY NỮA ĐẾN HẠN GỬI BÁO GIÁ'), const DaysUntil('gửi báo giá'));
      expect(p('lịch chiều nay có gì'), isA<WhatsNext>(), reason: 'today is still "what is next"');
      expect(p('nhắc anh gọi chị Lan thứ năm'), isNot(isA<FreeSlots>()));
    });

    test('busy at a time: "sáu giờ chiều nay có họp không"', () {
      // now is 14:12 on Monday 16/11
      expect(p('SÁU GIỜ CHIỀU NAY CÓ HỌP KHÔNG'), BusyAt(DateTime(2026, 11, 16, 18)));
      expect(p('3 giờ có lịch gì không'), BusyAt(DateTime(2026, 11, 16, 15)));
      expect(p('mai 9 giờ có bận không'), BusyAt(DateTime(2026, 11, 17, 9)));
      expect(p('chín giờ sáng mai có họp không'), BusyAt(DateTime(2026, 11, 17, 9)));
      expect(p('sáu giờ sáng nay có họp không'), BusyAt(DateTime(2026, 11, 16, 6)), reason: 'this morning, not tomorrow');
      expect(p('thứ năm 3 giờ rảnh không'), isNot(isA<BusyAt>()), reason: 'a weekday is not today');
      expect(p('chiều nay có họp không'), isNot(isA<BusyAt>()), reason: 'no clock time');
      expect(p('nhắc anh 3 giờ chiều xem có họp không'), isA<AddReminder>(), reason: 'reminders come first');
      expect(p('có hẹn giờ nào không'), isNot(isA<BusyAt>()));
    });

    test('views', () {
      expect(p('tổng kết hôm nay'), isA<ShowRecap>());
      expect(p('hôm nay thế nào'), isA<ShowRecap>());
      expect(p('ngày mai có gì'), isA<ShowTomorrow>());
      expect(p('bật màn'), isA<ScreenOn>());
      expect(p('chế độ đêm'), isA<ScreenOff>());
      expect(p('quay lại'), isA<GoHome>());
      expect(p('thôi'), isA<GoHome>());
    });

    test('not understood', () {
      expect(p(''), isNull);
      expect(p('ừ'), isNull);
      expect(p('ghi lại'), isNull, reason: 'nothing to write down');
      expect(p('thời tiết hôm nay thế nào'), isNull);
    });
  });
}
