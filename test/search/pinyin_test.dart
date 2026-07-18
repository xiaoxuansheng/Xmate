/// Pinyin initials unit tests.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:xmate/core/search/file_pinyin_data.dart';

void main() {
  group('getPinyinInitials', () {
    test('common characters', () {
      expect(getPinyinInitials(0x5C71), 's'); // 山 — shan → s
      expect(getPinyinInitials(0x4E1C), 'd'); // 东 — dong → d
      expect(getPinyinInitials(0x6D4B), 'c'); // 测 — ce → c
      expect(getPinyinInitials(0x8BD5), 's'); // 试 — shi → s
    });

    test('non-Chinese returns empty', () {
      expect(getPinyinInitials(0x61), ''); // 'a'
      expect(getPinyinInitials(0x41), ''); // 'A'
      expect(getPinyinInitials(0x30), ''); // '0'
      expect(getPinyinInitials(0x20), ''); // space
    });
  });

  group('toPinyinInitials', () {
    test('山东 → sd', () {
      expect(toPinyinInitials('山东'), 'sd');
    });

    test('测试 → cs', () {
      expect(toPinyinInitials('测试'), 'cs');
    });

    test('文件 → wj', () {
      expect(toPinyinInitials('文件'), 'wj');
    });

    test('按键 → aj (accented vowel fix)', () {
      expect(toPinyinInitials('按键'), 'aj');
    });

    test('嗯 → n (accented consonant fix)', () {
      expect(toPinyinInitials('嗯'), 'n');
    });

    test('mixed Chinese + ASCII', () {
      expect(toPinyinInitials('测试123'), 'cs123');
    });

    test('uppercase ASCII lowercased', () {
      expect(toPinyinInitials('Test'), 'test');
    });

    test('空字符串', () {
      expect(toPinyinInitials(''), '');
    });

    test('pure ASCII digits', () {
      expect(toPinyinInitials('123'), '123');
    });
  });
}
