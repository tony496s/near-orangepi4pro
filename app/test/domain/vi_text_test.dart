import 'package:flutter_test/flutter_test.dart';
import 'package:near_app/domain/intent/vi_text.dart';

void main() {
  test('tokenize: case, punctuation, clock times, separators, wake phrase', () {
    expect(tokenize('Hey Near, ĐẶT HẸN GIỜ 15:30!'), ['đặt', 'hẹn', 'giờ', '15', 'giờ', '30']);
    expect(tokenize('lúc 3h30 chiều'), ['lúc', '3', 'giờ', '30', 'chiều']);
    expect(tokenize('vượt 4.150 đô'), ['vượt', '4150', 'đô']);
    expect(tokenize('huỷ hẹn giờ'), ['hủy', 'hẹn', 'giờ']);
    expect(tokenize('  '), isEmpty);
  });

  group('names after kinship words', () {
    String s(String text) => sentence(tokenize(text));

    test('a name at the end or before a boundary word is capitalized', () {
      expect(s('GỌI CHO CHỊ LAN'), 'Gọi cho chị Lan');
      expect(s('gọi chị lan về ăn cơm'), 'Gọi chị Lan về ăn cơm');
      expect(s('họp với anh hùng và chị mai'), 'Họp với anh Hùng và chị Mai');
    });

    test('ordinary words after a kinship term are left alone', () {
      expect(s('bảo anh đi đón con'), 'Bảo anh đi đón con');
      expect(s('gọi cho chị ấy'), 'Gọi cho chị ấy');
      expect(s('mua quà cho bà'), 'Mua quà cho bà');
      expect(s('đón em gái'), 'Đón em gái');
    });
  });
}
