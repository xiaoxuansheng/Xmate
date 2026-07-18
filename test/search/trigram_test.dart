/// Trigram unit tests — pack/unpack, extraction, round-trip.
library;

import 'package:flutter_test/flutter_test.dart';
import 'dart:convert';
import 'package:xmate/core/search/file_trigram_index.dart';

void main() {
  // ── Pack / Unpack ──────────────────────────────────────────────────────

  group('packTrigram / unpackTrigram', () {
    test('round-trip ASCII', () {
      for (final bytes in [
        [0x24, 0x24, 0x61], // $$a
        [0x24, 0x61, 0x24], // $a$
        [0x73, 0x64, 0x00], // sd + NUL (hypothetical)
        [0xE5, 0xB1, 0xB1], // 山 UTF-8 part 1
        [0xB1, 0xE4, 0xB8], // cross-char boundary
      ]) {
        final packed = packTrigram(bytes[0], bytes[1], bytes[2]);
        final (b0, b1, b2) = unpackTrigram(packed);
        expect(b0, bytes[0]);
        expect(b1, bytes[1]);
        expect(b2, bytes[2]);
      }
    });

    test('pack is deterministic', () {
      // Same bytes produce same packed value every time
      final a = packTrigram(0x24, 0x24, 0x73);
      final b = packTrigram(0x24, 0x24, 0x73);
      expect(a, b);
    });
  });

  // ── Trigram extraction ─────────────────────────────────────────────────

  group('extractTrigrams', () {
    test('empty string', () {
      expect(extractTrigrams(''), isEmpty);
    });

    test('single char "a"', () {
      // "a" → utf8 [0x61] → padded [0x24,0x24,0x61,0x24]
      // trigrams: pack($,$,a)=pack(0x24,0x24,0x61), pack($,a,$)=pack(0x24,0x61,0x24)
      final trigrams = extractTrigrams('a');
      expect(trigrams.length, 2);
      expect(trigrams[0], packTrigram(0x24, 0x24, 0x61));
      expect(trigrams[1], packTrigram(0x24, 0x61, 0x24));
    });

    test('two chars "sd"', () {
      // "sd" → utf8 [0x73,0x64] → padded [0x24,0x24,0x73,0x64,0x24]
      // trigrams: $$s, $sd, sd$
      final trigrams = extractTrigrams('sd');
      expect(trigrams.length, 3);
      expect(trigrams[0], packTrigram(0x24, 0x24, 0x73));
      expect(trigrams[1], packTrigram(0x24, 0x73, 0x64));
      expect(trigrams[2], packTrigram(0x73, 0x64, 0x24));
    });

    test('Chinese "山"', () {
      // 山 → utf8 [0xE5,0xB1,0xB1] → padded [0x24,0x24,0xE5,0xB1,0xB1,0x24]
      final t = extractTrigrams('山');
      expect(t.length, greaterThanOrEqualTo(2));
      // First trigram: $,$,0xE5
      expect(t[0], packTrigram(0x24, 0x24, 0xE5));
    });

    test('Chinese "山东"', () {
      // 山东 → utf8 [0xE5,0xB1,0xB1, 0xE4,0xB8,0x9C]
      // padded [0x24,0x24, 0xE5,0xB1,0xB1, 0xE4,0xB8,0x9C, 0x24]
      // 7 trigrams (n+3-2 = 8-2 = 6? wait: length=8, window goes 0..5 = 6 trigrams)
      // padded length = 2 + 6 + 1 = 9, window count = 9-2 = 7
      final t = extractTrigrams('山东');
      expect(t.length, 7);
      expect(t[0], packTrigram(0x24, 0x24, 0xE5)); // $$-first-byte-of-山
      // $$ followed by E5 B1 = first two bytes of 山
      expect(t[1], packTrigram(0x24, 0xE5, 0xB1));
    });

    test('mixed "测试123"', () {
      final t = extractTrigrams('测试123');
      expect(t, isNotEmpty);
    });
  });

  // ── extractTrigramsFromBytes ────────────────────────────────────────────

  group('extractTrigramsFromBytes', () {
    test('matches extractTrigrams', () {
      for (final s in ['a', 'sd', 'hello', '山东', '测试']) {
        final a = extractTrigrams(s);
        final b = extractTrigramsFromBytes(utf8.encode(s));
        expect(a, b, reason: 'mismatch for "$s"');
      }
    });
  });
}
