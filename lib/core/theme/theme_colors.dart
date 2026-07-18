/// XMate 统一颜色 Token 定义
///
/// 所有 UI 组件的颜色都应通过此类获取，以支持浅色/深色主题切换。
/// 提供 [BuildContext] 扩展 `context.xmColors` 便捷访问。
library;

import 'package:flutter/material.dart';

import 'theme_service.dart';

/// 颜色 Token 集合 — 根据 [Brightness] 返回对应颜色。
///
/// 使用方式：
/// ```dart
/// final bg = XMateColors.panelBg(context);
/// final div = XMateColors.divider(context);
/// ```
class XMateColors {
  XMateColors._();

  // ── 基础色板 ──

  /// 深色基底色（不透明）
  static const Color darkBase = Color(0xFF1A1A2E);

  /// 浅色基底色（不透明）
  static const Color lightBase = Color(0xFFFFFFFF);

  /// 浅色页面底色
  static const Color lightPageBg = Color(0xFFF0F2F5);

  // ── 面板背景 ──

  /// 面板/卡片背景色（带用户设定的透明度）
  static Color panelBg(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final opacity = ThemeService().backgroundOpacity;
    final alpha = (opacity * 255 / 100).round().clamp(0, 255);
    final base = brightness == Brightness.dark ? darkBase : lightBase;
    return base.withAlpha(alpha);
  }

  /// 面板装饰（背景 + 主题色边框）
  static BoxDecoration panelDecoration(BuildContext context, {double radius = 16.0}) {
    final cs = Theme.of(context).colorScheme;
    return BoxDecoration(
      color: panelBg(context),
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: cs.primary.withAlpha(60), width: 1.5),
    );
  }

  /// 工具栏背景色（固定较高不透明度 ∼93%）
  static Color toolbarBg(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final base = brightness == Brightness.dark ? darkBase : lightBase;
    return base.withAlpha(0xEE);
  }

  /// 对话框背景色（始终全不透明）
  static Color dialogBg(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return brightness == Brightness.dark ? darkBase : lightBase;
  }

  /// 页面背景色（如设置页、翻译页等外层容器用）
  static Color pageBg(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return brightness == Brightness.dark ? darkBase : lightPageBg;
  }

  /// 面板背景色（不依赖 BuildContext，用于 static 方法或常量场景）
  /// 调用方需自行保证在主题变化时刷新
  static Color panelBgStatic(Brightness brightness) {
    final opacity = ThemeService().backgroundOpacity;
    final alpha = (opacity * 255 / 100).round().clamp(0, 255);
    final base = brightness == Brightness.dark ? darkBase : lightBase;
    return base.withAlpha(alpha);
  }

  // ── 表面填充 / 卡片 ──

  /// 卡片内部填充色（如 _SectionCard 背景）
  static Color cardFill(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return brightness == Brightness.dark
        ? Colors.white.withAlpha(12)
        : Colors.black.withAlpha(8);
  }

  // ── 分隔线 ──

  /// 分隔线颜色
  static Color divider(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return brightness == Brightness.dark
        ? Colors.white.withAlpha(20)
        : Colors.black.withAlpha(12);
  }

  /// 较粗/较强分隔线
  static Color dividerStrong(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return brightness == Brightness.dark
        ? Colors.white.withAlpha(30)
        : Colors.black.withAlpha(18);
  }

  // ── 高亮 / 悬停 ──

  /// 列表项高亮色（选中/悬停）
  static Color highlight(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return brightness == Brightness.dark
        ? Colors.white.withAlpha(15)
        : Colors.black.withAlpha(8);
  }

  /// 更强的高亮（如选中项）
  static Color highlightStrong(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return brightness == Brightness.dark
        ? Colors.white.withAlpha(30)
        : Colors.black.withAlpha(15);
  }

  // ── 文字 ──

  /// 主文字色
  static Color textPrimary(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return brightness == Brightness.dark ? Colors.white : const Color(0xFF1A1A2E);
  }

  /// 次要文字色
  static Color textSecondary(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return brightness == Brightness.dark ? Colors.white70 : const Color(0xFF666666);
  }

  /// 暗淡文字色
  static Color textDim(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return brightness == Brightness.dark ? Colors.white54 : const Color(0xFF999999);
  }

  /// 超暗淡文字色
  static Color textHint(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return brightness == Brightness.dark ? Colors.white38 : const Color(0xFFBBBBBB);
  }

  // ── 输入框 ──

  /// 输入框填充色
  static Color inputFill(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return brightness == Brightness.dark
        ? const Color(0x20FFFFFF)
        : const Color(0x0A000000);
  }

  /// 输入框边框色
  static Color inputBorder(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return brightness == Brightness.dark
        ? Colors.white.withAlpha(10)
        : Colors.black.withAlpha(15);
  }
}

/// [BuildContext] 扩展 — 便捷访问 XMate 颜色 token。
extension XMateColorsExtension on BuildContext {
  /// 获取当前主题对应的 [XMateColors] 便捷访问
  XMateColorsHelper get xmColors => XMateColorsHelper(this);
}

/// 持有 [BuildContext] 的辅助类，提供属性式访问。
class XMateColorsHelper {
  final BuildContext context;
  const XMateColorsHelper(this.context);

  Color get panelBg => XMateColors.panelBg(context);
  BoxDecoration panelDecoration({double radius = 16.0}) => XMateColors.panelDecoration(context, radius: radius);
  Color get toolbarBg => XMateColors.toolbarBg(context);
  Color get dialogBg => XMateColors.dialogBg(context);
  Color get pageBg => XMateColors.pageBg(context);
  Color get cardFill => XMateColors.cardFill(context);
  Color get divider => XMateColors.divider(context);
  Color get dividerStrong => XMateColors.dividerStrong(context);
  Color get highlight => XMateColors.highlight(context);
  Color get highlightStrong => XMateColors.highlightStrong(context);
  Color get textPrimary => XMateColors.textPrimary(context);
  Color get textSecondary => XMateColors.textSecondary(context);
  Color get textDim => XMateColors.textDim(context);
  Color get textHint => XMateColors.textHint(context);
  Color get inputFill => XMateColors.inputFill(context);
  Color get inputBorder => XMateColors.inputBorder(context);

  /// 从当前主题获取强调色
  Color get accent => Theme.of(context).colorScheme.primary;
}
