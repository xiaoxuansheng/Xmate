/// XMate 主题服务
///
/// 单例，管理主题模式 / 强调色 / 背景透明度。
/// 持久化到 [SettingsService]（`app.theme.*` 键），通过 [ChangeNotifier] 通知 UI 刷新。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../settings/settings_service.dart';

import 'app_theme.dart';

/// 预设强调色列表（按色相从小到大排列）
const kAccentPresets = <Color>[
  Color(0xFFC2735B), // 14°  暖橙
  Color(0xFFC2C05B), // 59°  黄绿
  Color(0xFF76C25B), // 104° 绿色
  Color(0xFF5BC28D), // 149° 青绿
  Color(0xFF5BAAC2), // 194° 青蓝（默认）
  Color(0xFF5B5DC2), // 239° 蓝紫
  Color(0xFFA65BC2), // 284° 紫色
  Color(0xFFC25B91), // 329° 粉红
];

/// 主题模式持久化值
const kThemeModeDark = 0;
const kThemeModeLight = 1;
const kThemeModeSystem = 2;

/// 设置键
const _kThemeMode = 'app.theme.mode';
const _kAccentColor = 'app.theme.accentColor';
const _kBackgroundOpacity = 'app.theme.backgroundOpacity';

class ThemeService extends ChangeNotifier {
  static final ThemeService _instance = ThemeService._();
  factory ThemeService() => _instance;
  ThemeService._();

  /// Set by the settings page to push theme changes to the notification process.
  static void Function()? onChanged;

  final SettingsService _settings = SettingsService();

  // ── 状态 ──

  ThemeMode _themeMode = ThemeMode.system;
  Color _accentColor = const Color(0xFF5AAAC2);
  int _backgroundOpacity = 87; // 75-100，默认 87 ≈ 0xDD

  bool _initialized = false;

  // ── Getters ──

  ThemeMode get themeMode => _themeMode;
  Color get accentColor => _accentColor;
  int get backgroundOpacity => _backgroundOpacity;

  /// 当前系统是否为浅色主题
  /// 优先使用原生方法通道（Windows 注册表），失败时回退到 Flutter platformBrightness
  bool _systemIsLight = false;

  bool get _isSystemLight => _systemIsLight;

  /// 实际生效的 Brightness（跟随系统时动态计算）
  Brightness get effectiveBrightness {
    switch (_themeMode) {
      case ThemeMode.dark:
        return Brightness.dark;
      case ThemeMode.light:
        return Brightness.light;
      case ThemeMode.system:
        return _isSystemLight ? Brightness.light : Brightness.dark;
    }
  }

  /// 浅色主题 [ThemeData]
  ThemeData get lightTheme => buildLightTheme(accent: _accentColor, opacity: _backgroundOpacity);

  /// 深色主题 [ThemeData]
  ThemeData get darkTheme => buildDarkTheme(accent: _accentColor, opacity: _backgroundOpacity);

  // ── 初始化 ──

  /// 从 [SettingsService] 加载已保存的主题设置。
  /// 应在 [SettingsService.init()] 之后调用。
  void init() {
    if (_initialized) return;
    _initialized = true;

    final mode = _settings.getWithDefault<int>(_kThemeMode, kThemeModeSystem);
    _themeMode = _intToThemeMode(mode);

    final colorVal = _settings.getWithDefault<int>(_kAccentColor, 0xFF5AAAC2);
    _accentColor = Color(colorVal);

    _backgroundOpacity = _settings.getWithDefault<int>(_kBackgroundOpacity, 87).clamp(75, 100);

    // Fetch system theme asynchronously (non-blocking)
    fetchSystemIsLight();
  }

  // ── Setters ──

  /// 设置主题模式并持久化
  Future<void> setThemeMode(ThemeMode mode) async {
    if (_themeMode == mode) return;
    _themeMode = mode;
    await _settings.set(_kThemeMode, _themeModeToInt(mode));
    notifyListeners();
    onChanged?.call();
    _updateTaskbarIcon();
  }

  /// 设置强调色并持久化
  Future<void> setAccentColor(Color color) async {
    if (_accentColor == color) return;
    _accentColor = color;
    await _settings.set(_kAccentColor, color.toARGB32());
    notifyListeners();
    onChanged?.call();
  }

  /// 设置背景透明度（0-100）并持久化
  Future<void> setBackgroundOpacity(int opacity) async {
    final clamped = opacity.clamp(75, 100);
    if (_backgroundOpacity == clamped) return;
    _backgroundOpacity = clamped;
    await _settings.set(_kBackgroundOpacity, clamped);
    notifyListeners();
  }

  // ── 系统主题检测 ──

  /// 通过原生方法通道获取 Windows 系统主题
  static const _channel = MethodChannel('com.xmate/window');

  /// 异步获取 Windows 系统主题是否为浅色模式，并更新内部状态。
  /// 应在 [init] 时调用一次，之后可在系统主题变化时再次调用。
  Future<void> fetchSystemIsLight() async {
    try {
      final result = await _channel.invokeMethod<bool>('getSystemTheme');
      _systemIsLight = result ?? false;
    } catch (_) {
      // Fallback: use Flutter's platform brightness
      _systemIsLight = false;
    }
    if (_themeMode == ThemeMode.system) {
      notifyListeners();
    }
    _updateTaskbarIcon();
  }

  /// 更新任务栏图标以匹配当前主题
  Future<void> _updateTaskbarIcon() async {
    try {
      await _channel.invokeMethod('setTaskbarIcon', {
        'name': effectiveBrightness == Brightness.dark
            ? 'app_icon_dark.ico'
            : 'app_icon_from_logo.ico',
      });
    } catch (_) {}
  }

  /// 刷新系统主题状态（用于系统主题变化时主动调用）
  Future<void> refreshSystemTheme() async {
    if (_themeMode != ThemeMode.system) return;
    // 通知监听者重建以反映最新的系统主题
    notifyListeners();
    _updateTaskbarIcon();
  }

  // ── 工具方法 ──

  static ThemeMode _intToThemeMode(int value) {
    switch (value) {
      case kThemeModeLight:
        return ThemeMode.light;
      case kThemeModeSystem:
        return ThemeMode.system;
      default:
        return ThemeMode.dark;
    }
  }

  static int _themeModeToInt(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.light:
        return kThemeModeLight;
      case ThemeMode.system:
        return kThemeModeSystem;
      default:
        return kThemeModeDark;
    }
  }
}
