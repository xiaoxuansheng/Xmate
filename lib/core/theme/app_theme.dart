/// XMate ThemeData 工厂
///
/// 根据强调色和透明度参数构建浅色/深色 [ThemeData]。
library;

import 'package:flutter/material.dart';

/// 构建浅色 [ThemeData] 的工厂方法。
ThemeData buildLightTheme({required Color accent, required int opacity}) {
  final colorScheme = ColorScheme.fromSeed(
    seedColor: accent,
    brightness: Brightness.light,
  );

  return ThemeData.light(useMaterial3: true).copyWith(
    colorScheme: colorScheme,
    scaffoldBackgroundColor: Colors.transparent,
    dividerColor: Colors.black.withAlpha(12),
    textTheme: ThemeData.light().textTheme.apply(
          fontFamilyFallback: const ['Microsoft YaHei'],
        ),
    // 下拉菜单主题
    dropdownMenuTheme: DropdownMenuThemeData(
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.black.withAlpha(6),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: Colors.black.withAlpha(15)),
        ),
      ),
    ),
    // Input 主题
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.black.withAlpha(6),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: Colors.black.withAlpha(15)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: Colors.black.withAlpha(15)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: accent, width: 2),
      ),
    ),
    // Slider 主题
    sliderTheme: SliderThemeData(
      activeTrackColor: accent,
      thumbColor: accent,
      inactiveTrackColor: accent.withAlpha(40),
    ),
    // Switch 主题
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return accent;
        return Colors.grey.shade400;
      }),
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return accent.withAlpha(128);
        return Colors.grey.shade300;
      }),
    ),
  );
}

/// 构建深色 [ThemeData] 的工厂方法。
ThemeData buildDarkTheme({required Color accent, required int opacity}) {
  final colorScheme = ColorScheme.fromSeed(
    seedColor: accent,
    brightness: Brightness.dark,
  );

  return ThemeData.dark(useMaterial3: true).copyWith(
    colorScheme: colorScheme,
    scaffoldBackgroundColor: Colors.transparent,
    textTheme: ThemeData.dark().textTheme.apply(
          fontFamilyFallback: const ['Microsoft YaHei'],
        ),
    // Slider 主题
    sliderTheme: SliderThemeData(
      activeTrackColor: accent,
      thumbColor: accent,
      inactiveTrackColor: accent.withAlpha(60),
    ),
    // Switch 主题
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return accent;
        return Colors.grey;
      }),
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return accent.withAlpha(128);
        return Colors.grey.shade700;
      }),
    ),
  );
}
