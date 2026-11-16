import 'package:flutter_test/flutter_test.dart';
import 'package:near_app/agents/dev_words.dart';
import 'package:near_app/domain/intent/vi_text.dart';

String fixed(String heard) => sentence(fixDevWords(tokenize(heard)));

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
}
