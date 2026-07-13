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
    required this.success,
    required this.onSuccess,
    required this.successContainer,
    required this.onSuccessContainer,
    required this.warning,
    required this.onWarning,
    required this.warningContainer,
    required this.onWarningContainer,
    this.spaceXxs = 4,
    this.spaceXs = 8,
    this.spaceSm = 12,
    this.spaceMd = 16,
    this.spaceLg = 20,
    this.spaceXl = 24,
    this.spaceXxl = 32,
    this.minimumTapTarget = 48,
    this.iconSmall = 18,
    this.iconStandard = 24,
    this.pageHorizontalPadding = 16,
    this.compactContentMaxWidth = 720,
    this.readableContentMaxWidth = 1040,
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
    success: Color(0xFF216E39),
    onSuccess: Colors.white,
    successContainer: Color(0xFFD7F4DE),
    onSuccessContainer: Color(0xFF0E4A24),
    warning: Color(0xFF8A4B00),
    onWarning: Colors.white,
    warningContainer: Color(0xFFFFDDB7),
    onWarningContainer: Color(0xFF5A3000),
  );

  static const dark = AppDesignTokens(
    asmrAccent: Color(0xFF60A5FA),
    asmrContainer: Color(0xFF172554),
    onAsmrContainer: Color(0xFFDBEAFE),
    onAsmrAccent: Color(0xFF0F172A),
    asmrSurface: Color(0xFF181D2B),
    subtleBorderAlpha: 0.15,
    standardBorderAlpha: 0.28,
    success: Color(0xFF8FDBA6),
    onSuccess: Color(0xFF0B3A1D),
    successContainer: Color(0xFF174D2A),
    onSuccessContainer: Color(0xFFB8F2C7),
    warning: Color(0xFFFFB95C),
    onWarning: Color(0xFF4A2800),
    warningContainer: Color(0xFF603B08),
    onWarningContainer: Color(0xFFFFDDB7),
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
  final Color success;
  final Color onSuccess;
  final Color successContainer;
  final Color onSuccessContainer;
  final Color warning;
  final Color onWarning;
  final Color warningContainer;
  final Color onWarningContainer;
  final double spaceXxs;
  final double spaceXs;
  final double spaceSm;
  final double spaceMd;
  final double spaceLg;
  final double spaceXl;
  final double spaceXxl;
  final double minimumTapTarget;
  final double iconSmall;
  final double iconStandard;
  final double pageHorizontalPadding;
  final double compactContentMaxWidth;
  final double readableContentMaxWidth;
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
    Color? success,
    Color? onSuccess,
    Color? successContainer,
    Color? onSuccessContainer,
    Color? warning,
    Color? onWarning,
    Color? warningContainer,
    Color? onWarningContainer,
    double? spaceXxs,
    double? spaceXs,
    double? spaceSm,
    double? spaceMd,
    double? spaceLg,
    double? spaceXl,
    double? spaceXxl,
    double? minimumTapTarget,
    double? iconSmall,
    double? iconStandard,
    double? pageHorizontalPadding,
    double? compactContentMaxWidth,
    double? readableContentMaxWidth,
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
      success: success ?? this.success,
      onSuccess: onSuccess ?? this.onSuccess,
      successContainer: successContainer ?? this.successContainer,
      onSuccessContainer: onSuccessContainer ?? this.onSuccessContainer,
      warning: warning ?? this.warning,
      onWarning: onWarning ?? this.onWarning,
      warningContainer: warningContainer ?? this.warningContainer,
      onWarningContainer: onWarningContainer ?? this.onWarningContainer,
      spaceXxs: spaceXxs ?? this.spaceXxs,
      spaceXs: spaceXs ?? this.spaceXs,
      spaceSm: spaceSm ?? this.spaceSm,
      spaceMd: spaceMd ?? this.spaceMd,
      spaceLg: spaceLg ?? this.spaceLg,
      spaceXl: spaceXl ?? this.spaceXl,
      spaceXxl: spaceXxl ?? this.spaceXxl,
      minimumTapTarget: minimumTapTarget ?? this.minimumTapTarget,
      iconSmall: iconSmall ?? this.iconSmall,
      iconStandard: iconStandard ?? this.iconStandard,
      pageHorizontalPadding:
          pageHorizontalPadding ?? this.pageHorizontalPadding,
      compactContentMaxWidth:
          compactContentMaxWidth ?? this.compactContentMaxWidth,
      readableContentMaxWidth:
          readableContentMaxWidth ?? this.readableContentMaxWidth,
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
      success: Color.lerp(success, other.success, t)!,
      onSuccess: Color.lerp(onSuccess, other.onSuccess, t)!,
      successContainer: Color.lerp(
        successContainer,
        other.successContainer,
        t,
      )!,
      onSuccessContainer: Color.lerp(
        onSuccessContainer,
        other.onSuccessContainer,
        t,
      )!,
      warning: Color.lerp(warning, other.warning, t)!,
      onWarning: Color.lerp(onWarning, other.onWarning, t)!,
      warningContainer: Color.lerp(
        warningContainer,
        other.warningContainer,
        t,
      )!,
      onWarningContainer: Color.lerp(
        onWarningContainer,
        other.onWarningContainer,
        t,
      )!,
      spaceXxs: lerpDouble(spaceXxs, other.spaceXxs, t)!,
      spaceXs: lerpDouble(spaceXs, other.spaceXs, t)!,
      spaceSm: lerpDouble(spaceSm, other.spaceSm, t)!,
      spaceMd: lerpDouble(spaceMd, other.spaceMd, t)!,
      spaceLg: lerpDouble(spaceLg, other.spaceLg, t)!,
      spaceXl: lerpDouble(spaceXl, other.spaceXl, t)!,
      spaceXxl: lerpDouble(spaceXxl, other.spaceXxl, t)!,
      minimumTapTarget: lerpDouble(
        minimumTapTarget,
        other.minimumTapTarget,
        t,
      )!,
      iconSmall: lerpDouble(iconSmall, other.iconSmall, t)!,
      iconStandard: lerpDouble(iconStandard, other.iconStandard, t)!,
      pageHorizontalPadding: lerpDouble(
        pageHorizontalPadding,
        other.pageHorizontalPadding,
        t,
      )!,
      compactContentMaxWidth: lerpDouble(
        compactContentMaxWidth,
        other.compactContentMaxWidth,
        t,
      )!,
      readableContentMaxWidth: lerpDouble(
        readableContentMaxWidth,
        other.readableContentMaxWidth,
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
