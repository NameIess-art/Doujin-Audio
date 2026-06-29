import 'dart:ui';

import 'package:flutter/material.dart';

@immutable
class AppDesignTokens extends ThemeExtension<AppDesignTokens> {
  const AppDesignTokens({
    required this.asmrAccent,
    required this.asmrContainer,
    required this.onAsmrContainer,
    required this.onAsmrAccent,
    required this.asmrSurface,
    required this.subtleBorderAlpha,
    required this.standardBorderAlpha,
    this.radiusSmall = 12,
    this.radiusControl = 14,
    this.radiusCard = 16,
    this.radiusSection = 20,
    this.radiusOverlay = 24,
    this.iconContainerSize = 36,
    this.motionFast = const Duration(milliseconds: 180),
    this.motionStandard = const Duration(milliseconds: 220),
    this.motionSlow = const Duration(milliseconds: 300),
  });

  static const light = AppDesignTokens(
    asmrAccent: Color(0xFF1D4ED8),
    asmrContainer: Color(0xFFDBEAFE),
    onAsmrContainer: Color(0xFF1E40AF),
    onAsmrAccent: Colors.white,
    asmrSurface: Color(0xFFF4F7FA),
    subtleBorderAlpha: 0.30,
    standardBorderAlpha: 0.50,
  );

  static const dark = AppDesignTokens(
    asmrAccent: Color(0xFF60A5FA),
    asmrContainer: Color(0xFF172554),
    onAsmrContainer: Color(0xFFDBEAFE),
    onAsmrAccent: Color(0xFF0F172A),
    asmrSurface: Color(0xFF181D2B),
    subtleBorderAlpha: 0.15,
    standardBorderAlpha: 0.28,
  );

  static AppDesignTokens of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<AppDesignTokens>() ??
        (theme.brightness == Brightness.dark ? dark : light);
  }

  final Color asmrAccent;
  final Color asmrContainer;
  final Color onAsmrContainer;
  final Color onAsmrAccent;
  final Color asmrSurface;
  final double subtleBorderAlpha;
  final double standardBorderAlpha;
  final double radiusSmall;
  final double radiusControl;
  final double radiusCard;
  final double radiusSection;
  final double radiusOverlay;
  final double iconContainerSize;
  final Duration motionFast;
  final Duration motionStandard;
  final Duration motionSlow;

  @override
  AppDesignTokens copyWith({
    Color? asmrAccent,
    Color? asmrContainer,
    Color? onAsmrContainer,
    Color? onAsmrAccent,
    Color? asmrSurface,
    double? subtleBorderAlpha,
    double? standardBorderAlpha,
    double? radiusSmall,
    double? radiusControl,
    double? radiusCard,
    double? radiusSection,
    double? radiusOverlay,
    double? iconContainerSize,
    Duration? motionFast,
    Duration? motionStandard,
    Duration? motionSlow,
  }) {
    return AppDesignTokens(
      asmrAccent: asmrAccent ?? this.asmrAccent,
      asmrContainer: asmrContainer ?? this.asmrContainer,
      onAsmrContainer: onAsmrContainer ?? this.onAsmrContainer,
      onAsmrAccent: onAsmrAccent ?? this.onAsmrAccent,
      asmrSurface: asmrSurface ?? this.asmrSurface,
      subtleBorderAlpha: subtleBorderAlpha ?? this.subtleBorderAlpha,
      standardBorderAlpha: standardBorderAlpha ?? this.standardBorderAlpha,
      radiusSmall: radiusSmall ?? this.radiusSmall,
      radiusControl: radiusControl ?? this.radiusControl,
      radiusCard: radiusCard ?? this.radiusCard,
      radiusSection: radiusSection ?? this.radiusSection,
      radiusOverlay: radiusOverlay ?? this.radiusOverlay,
      iconContainerSize: iconContainerSize ?? this.iconContainerSize,
      motionFast: motionFast ?? this.motionFast,
      motionStandard: motionStandard ?? this.motionStandard,
      motionSlow: motionSlow ?? this.motionSlow,
    );
  }

  @override
  AppDesignTokens lerp(covariant AppDesignTokens? other, double t) {
    if (other == null) return this;
    return AppDesignTokens(
      asmrAccent: Color.lerp(asmrAccent, other.asmrAccent, t)!,
      asmrContainer: Color.lerp(asmrContainer, other.asmrContainer, t)!,
      onAsmrContainer: Color.lerp(onAsmrContainer, other.onAsmrContainer, t)!,
      onAsmrAccent: Color.lerp(onAsmrAccent, other.onAsmrAccent, t)!,
      asmrSurface: Color.lerp(asmrSurface, other.asmrSurface, t)!,
      subtleBorderAlpha: lerpDouble(
        subtleBorderAlpha,
        other.subtleBorderAlpha,
        t,
      )!,
      standardBorderAlpha: lerpDouble(
        standardBorderAlpha,
        other.standardBorderAlpha,
        t,
      )!,
      radiusSmall: lerpDouble(radiusSmall, other.radiusSmall, t)!,
      radiusControl: lerpDouble(radiusControl, other.radiusControl, t)!,
      radiusCard: lerpDouble(radiusCard, other.radiusCard, t)!,
      radiusSection: lerpDouble(radiusSection, other.radiusSection, t)!,
      radiusOverlay: lerpDouble(radiusOverlay, other.radiusOverlay, t)!,
      iconContainerSize: lerpDouble(
        iconContainerSize,
        other.iconContainerSize,
        t,
      )!,
      motionFast: _lerpDuration(motionFast, other.motionFast, t),
      motionStandard: _lerpDuration(motionStandard, other.motionStandard, t),
      motionSlow: _lerpDuration(motionSlow, other.motionSlow, t),
    );
  }
}

Duration _lerpDuration(Duration a, Duration b, double t) {
  return Duration(
    microseconds: lerpDouble(a.inMicroseconds, b.inMicroseconds, t)!.round(),
  );
}
