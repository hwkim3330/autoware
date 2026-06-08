import 'package:flutter/material.dart';

/// Dark, in-vehicle dashboard theme. Landscape tablet oriented.
class AppTheme {
  static const bg = Color(0xFF0D1117);
  static const surface = Color(0xFF161B22);
  static const surfaceAlt = Color(0xFF1C2330);
  static const border = Color(0xFF30363D);
  static const textPrimary = Color(0xFFE6EDF3);
  static const textMuted = Color(0xFF8B949E);
  static const accent = Color(0xFF58A6FF);

  static ThemeData build() {
    final base = ThemeData.dark(useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: bg,
      colorScheme: base.colorScheme.copyWith(
        surface: surface,
        primary: accent,
        secondary: accent,
      ),
      cardTheme: const CardThemeData(
        color: surface,
        elevation: 0,
        margin: EdgeInsets.zero,
      ),
      dividerColor: border,
      textTheme: base.textTheme.apply(
        bodyColor: textPrimary,
        displayColor: textPrimary,
        fontFamily: 'Roboto',
      ),
      navigationRailTheme: const NavigationRailThemeData(
        backgroundColor: surface,
        selectedIconTheme: IconThemeData(color: accent),
        unselectedIconTheme: IconThemeData(color: textMuted),
        selectedLabelTextStyle: TextStyle(color: accent, fontSize: 11),
        unselectedLabelTextStyle: TextStyle(color: textMuted, fontSize: 11),
      ),
    );
  }

  static BoxDecoration card({Color? borderColor}) => BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor ?? border),
      );

  static const labelStyle = TextStyle(
    fontSize: 11,
    letterSpacing: 0.6,
    color: textMuted,
    fontWeight: FontWeight.w600,
  );
}
