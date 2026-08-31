import 'package:flutter/material.dart';

class AppSpacing {
  AppSpacing._();

  static const double xxs = 4.0;
  static const double xs = 8.0;
  static const double sm = 12.0;
  static const double md = 16.0;
  static const double lg = 20.0;
  static const double xl = 24.0;
  static const double xxl = 32.0;
  static const double xxxl = 48.0;

  static const EdgeInsets edgeInsetsHorizontalMd = EdgeInsets.symmetric(
    horizontal: md,
  );
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

  static const BorderRadius borderSmall = BorderRadius.all(
    Radius.circular(small),
  );
  static const BorderRadius borderMedium = BorderRadius.all(
    Radius.circular(medium),
  );
  static const BorderRadius borderCard = BorderRadius.all(
    Radius.circular(card),
  );
  static const BorderRadius borderDialog = BorderRadius.all(
    Radius.circular(dialog),
  );
}

class AppDurations {
  AppDurations._();

  static const Duration fast = Duration(milliseconds: 150);
  static const Duration normal = Duration(milliseconds: 250);
  static const Duration slow = Duration(milliseconds: 350);
}

abstract final class AppPageHeaderMetrics {
  static const double contentHeight = 44;
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
  static const double firstContentSpacing = AppSpacing.xxs;
  static const double bottomSpacing = AppSpacing.xxs;
  static const double toolbarHeight = 62;
  static const double expandedToolbarHeight = 88;
}
