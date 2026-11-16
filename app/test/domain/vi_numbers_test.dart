import 'package:flutter_test/flutter_test.dart';
import 'package:near_app/domain/intent/vi_numbers.dart';
import 'package:near_app/domain/intent/vi_text.dart';

int? n(String s) => readNumber(tokenize(s), 0)?.value;

void main() {
  test('units, tens and the special unit words', () {
    expect(n('năm'), 5);
    expect(n('mười'), 10);
    expect(n('mười lăm'), 15);
    expect(n('mười một'), 11);
    expect(n('hai mươi'), 20);
    expect(n('hai mươi mốt'), 21);
    expect(n('hai mươi tư'), 24);
    expect(n('hai mươi lăm'), 25);
    expect(n('bốn mươi lăm'), 45);
    expect(n('chín mươi chín'), 99);
  });

  test('hundreds and thousands', () {
    expect(n('một trăm'), 100);
    expect(n('một trăm linh năm'), 105);
    expect(n('một trăm năm mươi'), 150);
    expect(n('bốn nghìn một trăm năm mươi'), 4150);
    expect(n('hai ngàn'), 2000);
  });

  test('digits, including thousand separators', () {
    expect(n('15'), 15);
    expect(n('4.150'), 4150);
    expect(n('4,150'), 4150);
  });

  test('stops at the first word that is not part of the number', () {
    expect(readNumber(tokenize('hai mươi lăm phút'), 0), (value: 25, length: 3));
    expect(readNumber(tokenize('ba giờ chiều'), 0), (value: 3, length: 1));
    expect(readNumber(tokenize('hai ba'), 0), (value: 2, length: 1), reason: 'two units in a row are two numbers');
  });

  test('not a number', () {
    expect(n('phút'), isNull);
    expect(n('lăm'), isNull, reason: '"lăm" only follows a ten');
    expect(readNumber(const [], 0), isNull);
  });
}
