import 'package:flutter/material.dart';

enum AppIconColorGroup { warm, purple, blue, green, sunset, neutral }

extension AppIconColorGroupColors on AppIconColorGroup {
  List<Color> colors(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    return switch (this) {
      AppIconColorGroup.warm =>
        dark
            ? const [Color(0xFFFF6BB5), Color(0xFFFF9B73)]
            : const [Color(0xFFFF2381), Color(0xFFFF774D)],
      AppIconColorGroup.purple =>
        dark
            ? const [Color(0xFFA58BFF), Color(0xFFD39BFF)]
            : const [Color(0xFF8155E8), Color(0xFFB96FF5)],
      AppIconColorGroup.blue =>
        dark
            ? const [Color(0xFF22D3EE), Color(0xFF8B5CF6)]
            : const [Color(0xFF0EA5E9), Color(0xFF6366F1)],
      AppIconColorGroup.green =>
        dark
            ? const [Color(0xFF2DD4BF), Color(0xFFA3E635)]
            : const [Color(0xFF16B981), Color(0xFF84CC16)],
      AppIconColorGroup.sunset =>
        dark
            ? const [Color(0xFFFBBF24), Color(0xFFFB923C)]
            : const [Color(0xFFF0B429), Color(0xFFFF7043)],
      AppIconColorGroup.neutral =>
        dark
            ? const [Color(0xFFAEB8C4), Color(0xFFE5E7EB)]
            : const [Color(0xFF788494), Color(0xFFB9C2CF)],
    };
  }

  LinearGradient gradient(Brightness brightness) {
    return LinearGradient(colors: colors(brightness));
  }
}

class AppBrandIconTheme extends ThemeExtension<AppBrandIconTheme> {
  const AppBrandIconTheme({required this.gradient});

  final LinearGradient gradient;

  factory AppBrandIconTheme.forGroup(
    AppIconColorGroup group,
    Brightness brightness,
  ) {
    return AppBrandIconTheme(gradient: group.gradient(brightness));
  }

  @override
  AppBrandIconTheme copyWith({LinearGradient? gradient}) {
    return AppBrandIconTheme(gradient: gradient ?? this.gradient);
  }

  @override
  AppBrandIconTheme lerp(covariant AppBrandIconTheme? other, double t) {
    if (other == null) return this;
    return AppBrandIconTheme(
      gradient: LinearGradient.lerp(gradient, other.gradient, t)!,
    );
  }
}
