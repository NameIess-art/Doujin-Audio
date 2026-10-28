import 'package:flutter/material.dart';

class AppSpacing {
  AppSpacing._();

  static const double xxs = 4.0;
  static const double xs = 8.0;
  static const double sm = 12.0;
  static const double md = 16.0;
  static const double lg = 20.0;
  static const double xl = 24.0;

  static const EdgeInsets edgeInsetsAllMd = EdgeInsets.all(md);
}

class AppRadius {
  AppRadius._();

  static const double small = 6.0;
  static const double medium = 10.0;
  static const double card = 12.0;
  static const double section = 16.0;
  static const double dialog = 20.0;
  static const double pill = 999.0;

  static const BorderRadius borderMedium = BorderRadius.all(
    Radius.circular(medium),
  );
  static const BorderRadius borderDialog = BorderRadius.all(
    Radius.circular(dialog),
  );
}

abstract final class AppPageHeaderMetrics {
  static const double buttonSize = 38;
  static const double contentHeight = buttonSize;
  static const double rowSpacing = 6;
  static const double expandedContentHeight = contentHeight * 2 + rowSpacing;
  static const EdgeInsets padding = EdgeInsets.fromLTRB(
    AppSpacing.md,
    6,
    AppSpacing.md,
    0,
  );
  static const EdgeInsets mainTabPadding = EdgeInsets.fromLTRB(
    AppSpacing.md,
    6,
    AppSpacing.md,
    0,
  );
  static const double firstContentSpacing = AppSpacing.xs;
  static const double toolbarHeight = 62;
  static const double expandedToolbarHeight = 88;

  static double headerHeight(
    BuildContext context, {
    double? contentHeight,
    double additionalHeight = 0,
  }) =>
      MediaQuery.paddingOf(context).top +
      padding.vertical +
      (contentHeight ?? AppPageHeaderMetrics.contentHeight) +
      additionalHeight;

  static double contentTopInset(
    BuildContext context, {
    double? contentHeight,
    double additionalHeight = 0,
  }) =>
      headerHeight(
        context,
        contentHeight: contentHeight,
        additionalHeight: additionalHeight,
      ) +
      firstContentSpacing;
}
