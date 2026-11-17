import 'package:flutter_test/flutter_test.dart';
import 'package:near_app/agents/console_model.dart';
import 'package:near_app/agents/dev_words.dart';
import 'package:near_app/domain/intent/vi_text.dart';

String fixed(String heard) => sentence(fixDevWords(tokenize(heard)));

/// The machine named in [heard] and the task without it, as the console reads a transcript.
({Machine? machine, String task}) routed(String heard) {
  final (:machine, :rest) = machineIn(fixDevWords(tokenize(heard)));
  return (machine: machine, task: sentence(rest));
}

void main() {
  test('what the board heard (17/11) reads back as the dev words that were said', () {
    expect(fixed('THÊM LEO ĐÌNH CHO NÚT ĐĂNG NHẬP'), 'Thêm loading cho nút đăng nhập');
    expect(fixed('HAI NIA THÊM LEO ĐÌNH CHO NÚT ĐĂNG NHẬP'), 'Thêm loading cho nút đăng nhập');
    expect(fixed('THÊM SKIN NÊU CHO NÚT LOU IN'), 'Thêm spinner cho nút login');
    expect(fixed('SYP BẢN TEST'), 'Ship bản test');
    expect(fixed('LÊN TEST LEVIS'), 'Lên testflight');
    expect(fixed('SỬA LỖI ĐĂNG XUẤT Ở BARCADE'), 'Sửa lỗi đăng xuất ở backend');
  });

  test('plain Vietnamese is left alone', () {
    expect(fixed('THÊM HIỆU ỨNG CHỜ CHO NÚT ĐĂNG NHẬP'), 'Thêm hiệu ứng chờ cho nút đăng nhập');
    expect(fixDevWords(const []), isEmpty);
    expect(fixDevWords(const ['leo']), ['leo'], reason: 'half a phrase at the end is not a match');
  });

  test('the wake phrase is dropped only at the start', () {
    expect(fixDevWords(const ['hai', 'nia']), isEmpty);
    expect(fixDevWords(const ['gọi', 'hai', 'nia']), ['gọi', 'hai', 'nia']);
  });

  group('machine named in a task', () {
    const task = 'Thêm hiệu ứng chờ cho nút đăng nhập';

    test('what the board heard for each machine (17/11) names it, and leaves the task', () {
      for (final (said, machine) in const [
        ('TRÊN MA QUỐC', Machine.macbook),
        ('TRÊN MACBOOK', Machine.macbook),
        ('TRÊN LAPTOP', Machine.macbook),
        ('TRÊN MÁY MÓC', Machine.macbook),
        ('TRÊN SERVER', Machine.server),
        ('TRÊN MÁI CHỦ', Machine.server),
      ]) {
        expect(routed('THÊM HIỆU ỨNG CHỜ CHO NÚT ĐĂNG NHẬP $said'), (machine: machine, task: task), reason: said);
      }
    });

    test('other spellings, after "trên" or "ở", anywhere in the sentence', () {
      for (final (said, machine) in const [
        ('CHẠY TEST Ở MAC BOOK', Machine.macbook),
        ('CHẠY TEST TRÊN MÁC BÚC', Machine.macbook),
        ('CHẠY TEST TRÊN MẮC BÚC', Machine.macbook),
        ('CHẠY TEST TRÊN MÁY MAC', Machine.macbook),
        ('CHẠY TEST TRÊN MAC', Machine.macbook),
        ('CHẠY TEST TRÊN LAP TOP', Machine.macbook),
        ('CHẠY TEST Ở SƠ VƠ', Machine.server),
        ('CHẠY TEST TRÊN MÁY CHỦ', Machine.server),
        ('trên server chạy test', Machine.server),
      ]) {
        expect(routed(said), (machine: machine, task: 'Chạy test'), reason: said);
      }
    });

    test('works with fixed dev words and the wake phrase', () {
      expect(routed('HAI NIA THÊM LEO ĐÌNH CHO NÚT LOU IN TRÊN MA QUỐC'),
          (machine: Machine.macbook, task: 'Thêm loading cho nút login'));
    });

    test('without "trên" or "ở" a machine word is part of the task', () {
      for (final said in ['KIỂM TRA MÁY MÓC', 'THÊM CACHE CHO SERVER', 'SỬA LỖI SẠC LAPTOP', 'HIỆN LỖI TRÊN MÀN HÌNH']) {
        expect(routed(said), (machine: null, task: fixed(said)), reason: said);
      }
      expect(routed('HIỆN LỖI TRÊN MÀN HÌNH').task, 'Hiện lỗi trên màn hình');
      expect(machineIn(const []).machine, isNull);
      expect(machineIn(const []).rest, isEmpty);
      expect(machineIn(const ['trên']).rest, ['trên']);
    });
  });
}
