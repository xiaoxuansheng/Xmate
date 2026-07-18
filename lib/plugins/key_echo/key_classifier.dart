/// Map Win32 virtual-key codes and modifier masks to human-readable labels.
///
/// Modifier mask (from C++ EncodeModifiers):
///   1 = Alt, 2 = Ctrl, 4 = Shift, 8 = Win
///
/// Exclusion rules (these keys NEVER appear in the Hotkey panel):
///   - Caps Lock / Num Lock / Scroll Lock / Insert  (shown in Status panel)
///   - Backspace, Enter, Tab, Escape, Delete
///   - Arrow keys, Numpad keys
///   - Shift+digit combos (Shift+1 → !, etc. — these are typing, not hotkeys)
library;

class KeyClassifier {
  KeyClassifier._();

  /// Convert a VK code + modifier mask to a display label.
  /// Returns null if the combo should NOT be displayed (excluded by rule).
  static String? toDisplayLabel(int vkCode, int modifiers) {
    // ── Exclude: status-related lock keys (shown in Status panel) ──
    if (_isStatusKey(vkCode)) return null;

    // ── Exclude: standalone typing/typing-adjacent keys ──
    if (_isExcludedKey(vkCode)) return null;

    // ── Exclude: Shift+digit (Shift+1=!, Shift+2=@, …) — typing ──
    final hasShift = (modifiers & 4) != 0;
    if (hasShift && _isMainDigit(vkCode)) return null;

    // ── Build label ──
    final bool hasModifiers = modifiers != 0;
    String? keyName;

    if (hasModifiers && _isLetter(vkCode)) {
      // Modifier + letter: show the actual uppercase letter.
      keyName = String.fromCharCode(vkCode).toUpperCase();
    } else {
      keyName = _vkCodeToName(vkCode);
      if (keyName == null) return null; // unhandled VK → skip
      // Skip standalone letters/digits without modifiers.
      if (!hasModifiers && (_isLetter(vkCode) || _isMainDigit(vkCode))) {
        return null;
      }
    }

    final modPrefix = _modifiersToString(modifiers);
    if (modPrefix.isEmpty) return keyName;
    return '$modPrefix+$keyName';
  }

  // ── Exclusion helpers ──

  static bool _isStatusKey(int vk) {
    return vk == 0x14 ||  // Caps Lock
           vk == 0x90 ||  // Num Lock
           vk == 0x91 ||  // Scroll Lock
           vk == 0x2D;    // Insert
  }

  static bool _isExcludedKey(int vk) {
    switch (vk) {
      case 0x08: // Backspace
      case 0x0D: // Enter
      case 0x09: // Tab
      case 0x1B: // Escape
      case 0x2E: // Delete
      case 0x25: // ←
      case 0x26: // ↑
      case 0x27: // →
      case 0x28: // ↓
        return true;
      // Numpad keys 0x60-0x6F (Num0-Num9, multiply, add, …)
      case 0x60: case 0x61: case 0x62: case 0x63: case 0x64:
      case 0x65: case 0x66: case 0x67: case 0x68: case 0x69:
      case 0x6A: case 0x6B: case 0x6D: case 0x6E: case 0x6F:
        return true;
      default:
        return false;
    }
  }

  static bool _isLetter(int vk) => vk >= 0x41 && vk <= 0x5A;

  static bool _isMainDigit(int vk) => vk >= 0x30 && vk <= 0x39;

  // ── Modifier string ──

  static String _modifiersToString(int mask) {
    final parts = <String>[];
    if (mask & 1 != 0) parts.add('Alt');
    if (mask & 2 != 0) parts.add('Ctrl');
    if (mask & 4 != 0) parts.add('Shift');
    if (mask & 8 != 0) parts.add('Win');
    return parts.join('+');
  }

  // ── VK code → name (functional / media / nav keys only) ──

  /// Returns null for VK codes we don't have a name for (skip them).
  static String? _vkCodeToName(int vk) {
    switch (vk) {
      // ── F-keys ──
      case 0x70: return 'F1';
      case 0x71: return 'F2';
      case 0x72: return 'F3';
      case 0x73: return 'F4';
      case 0x74: return 'F5';
      case 0x75: return 'F6';
      case 0x76: return 'F7';
      case 0x77: return 'F8';
      case 0x78: return 'F9';
      case 0x79: return 'F10';
      case 0x7A: return 'F11';
      case 0x7B: return 'F12';
      case 0x7C: return 'F13';
      case 0x7D: return 'F14';
      case 0x7E: return 'F15';
      case 0x7F: return 'F16';
      case 0x80: return 'F17';
      case 0x81: return 'F18';
      case 0x82: return 'F19';
      case 0x83: return 'F20';
      case 0x84: return 'F21';
      case 0x85: return 'F22';
      case 0x86: return 'F23';
      case 0x87: return 'F24';

      // ── Navigation ──
      case 0x24: return 'Home';
      case 0x23: return 'End';
      case 0x21: return 'Page Up';
      case 0x22: return 'Page Down';

      // ── Special ──
      case 0x2C: return 'Print Screen';
      case 0x13: return 'Pause';

      // ── Media ──
      case 0xAD: return 'Vol Mute';
      case 0xAE: return 'Vol Down';
      case 0xAF: return 'Vol Up';
      case 0xB0: return 'Next Track';
      case 0xB1: return 'Prev Track';
      case 0xB2: return 'Stop';
      case 0xB3: return 'Play/Pause';

      // ── Browser ──
      case 0xA6: return 'Back';
      case 0xA7: return 'Forward';
      case 0xA8: return 'Refresh';
      case 0xAA: return 'Search';
      case 0xAB: return 'Favorites';
      case 0xAC: return 'Home';

      // ── Launch ──
      case 0xB4: return 'Mail';
      case 0xB5: return 'Media';
      case 0xB6: return 'App 1';
      case 0xB7: return 'App 2';

      // ── Misc ──
      case 0x5D: return 'Menu';
      case 0x20: return 'Space'; // only reached with modifiers held

      default: return null;
    }
  }
}
