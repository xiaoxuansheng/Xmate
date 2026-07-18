/// 便签锁内容加密（纯 Dart，无第三方依赖）
///
/// 威胁模型：防止直接打开 %APPDATA% 下 JSON 读取锁定便签的内容或口令。
/// 口令不落盘 —— 只存 KDF 验证子（verifier）；内容用 KDF 派生密钥的
/// xorshift64* 流加密。KDF 迭代 10 万次抬高离线穷举 6 位数字码的成本。
/// （非对抗性密码学强度，定位为"防直接翻文件"。）
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

class NoteCrypto {
  static const _mask = 0xFFFFFFFFFFFFFFFF;

  /// 每便签随机盐（16 字节 base64），上锁时生成
  static String newSalt() {
    final r = Random.secure();
    final b = List<int>.generate(16, (_) => r.nextInt(256));
    return base64Encode(b);
  }

  // FNV-1a 64
  static int _fnv(List<int> data) {
    var h = 0xcbf29ce484222325;
    for (final b in data) {
      h ^= b;
      h = (h * 0x100000001b3) & _mask;
    }
    return h;
  }

  // xorshift64* 一轮
  static int _mix(int s) {
    s ^= s >>> 12;
    s ^= (s << 25) & _mask;
    s ^= s >>> 27;
    return (s * 0x2545F4914F6CDD1D) & _mask;
  }

  /// 迭代 KDF：code + salt → 64bit 密钥（约 1-3ms）
  static int _kdf(String code, String salt) {
    var h = _fnv(utf8.encode('$salt|xmate-note|$code'));
    for (var i = 0; i < 100000; i++) {
      h = _mix(h ^ i);
    }
    return h;
  }

  /// 口令验证子（落盘）：与密钥流种子用不同 tweak，不互相泄露
  static String verifier(String code, String salt) {
    var v = _mix(_kdf(code, salt) ^ 0x5f3759df9e3779b9);
    v = _mix(v);
    return v.toRadixString(16).padLeft(16, '0');
  }

  static Uint8List _xorStream(List<int> data, int key) {
    final out = Uint8List(data.length);
    var s = _mix(key ^ 0x9e3779b97f4a7c15);
    var ks = 0;
    var kb = 0;
    for (var i = 0; i < data.length; i++) {
      if (kb == 0) {
        s = _mix(s);
        ks = s;
        kb = 8;
      }
      out[i] = data[i] ^ (ks & 0xFF);
      ks >>>= 8;
      kb--;
    }
    return out;
  }

  /// 加密内容 → base64
  static String encrypt(String plain, String code, String salt) {
    final key = _kdf(code, salt);
    return base64Encode(_xorStream(utf8.encode(plain), key));
  }

  /// 解密 base64 → 明文（失败 / 密钥错误产生非法 UTF-8 → null）
  static String? decrypt(String enc, String code, String salt) {
    try {
      final key = _kdf(code, salt);
      final out = _xorStream(base64Decode(enc), key);
      return utf8.decode(out, allowMalformed: false);
    } catch (_) {
      return null;
    }
  }
}
