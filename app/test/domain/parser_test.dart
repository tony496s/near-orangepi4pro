import 'package:flutter_test/flutter_test.dart';
import 'package:near_app/domain/intent/commands.dart';
import 'package:near_app/domain/intent/parser.dart';

void main() {
  final now = DateTime(2026, 11, 16, 14, 12);
  Command? p(String s) => parseCommand(s, now);

  group('real Zipformer-vi 30M transcripts from Phase 0 E4', () {
    test('timers', () {
      expect(p('ĐẶT HẸN GIỜ MƯỜI LĂM PHÚT'), const StartTimer(Duration(minutes: 15), focus: false));
      expect(p('HẸN GIỜ HAI MƯƠI LĂM PHÚT ĐỂ TẬP TRUNG'), const StartTimer(Duration(minutes: 25), focus: true));
      expect(p('BẬT CHẾ ĐỘ TẬP TRUNG TRONG MỘT TIẾNG'), const StartTimer(Duration(hours: 1), focus: true));
      expect(p('CÒN BAO NHIÊU PHÚT NỮA'), isA<TimeLeft>());
      expect(p('HỦY HẸN GIỜ'), isA<CancelTimer>());
    });

    test('reminder that lost "chiều" still lands at 15:00', () {
      expect(p('NHẮC ANH GỌI CHO CHỊ LAN LÚC BA GIỜ'), AddReminder('Gọi cho chị lan', DateTime(2026, 11, 16, 15)));
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
      expect(p('Nhắc anh gọi cho chị Lan lúc ba giờ chiều.'), AddReminder('Gọi cho chị lan', DateTime(2026, 11, 16, 15)));
      expect(p('nhắc anh đứng dậy sau 20 phút'), AddReminder('Đứng dậy', DateTime(2026, 11, 16, 14, 32)));
      expect(p('nhắc em uống nước 10 phút nữa'), AddReminder('Uống nước', DateTime(2026, 11, 16, 14, 22)));
      expect(p('nhắc anh gọi chị Lan sau 2 phút'), AddReminder('Gọi chị lan', DateTime(2026, 11, 16, 14, 14)));
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
