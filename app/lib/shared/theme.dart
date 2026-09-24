import 'package:flutter/material.dart';

/// Dark, focused Material 3 theme — a private line should look like one.
class HotlineTheme {
  HotlineTheme._();

  static const Color _bg = Color(0xFF0B0F14);
  static const Color _surface = Color(0xFF121821);
  static const Color _accent = Color(0xFF3DDC97); // secure-line green
  static const Color _accentDim = Color(0xFF1E4B3B);
  static const Color _danger = Color(0xFFE4574F);

  static ThemeData dark() {
    final scheme = ColorScheme.dark(
      primary: _accent,
      onPrimary: Colors.black,
      secondary: _accentDim,
      surface: _surface,
      error: _danger,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: _bg,
      appBarTheme: const AppBarTheme(
        backgroundColor: _surface,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: false,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: _surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    );
  }
}
