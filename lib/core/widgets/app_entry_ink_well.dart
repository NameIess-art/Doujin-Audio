import 'package:flutter/material.dart';

import 'app_buttons.dart';
import 'app_tap_highlight.dart';

/// Entry touch/click ripple with ticker-mute cleanup so covered pages do not
/// retain unfinished release ink when popped back into view.
class AppEntryInkWell extends InkWell {
  const AppEntryInkWell({
    super.key,
    super.splashColor,
    super.hoverColor,
    super.mouseCursor = WidgetStateMouseCursor.clickable,
    super.autofocus,
    super.onTap,
    super.onLongPress,
    super.borderRadius,
    super.customBorder,
    super.canRequestFocus,
    super.excludeFromSemantics,
    super.child,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final animate = !MediaQuery.disableAnimationsOf(context);
    return InkWell(
      mouseCursor: mouseCursor,
      splashFactory: AppTapHighlightFactory.forPlatform(
        theme.platform,
        animate: animate,
      ),
      highlightColor: Colors.transparent,
      hoverDuration: Duration.zero,
      splashColor: splashColor ?? appPressedTint(theme.colorScheme),
      hoverColor: hoverColor ?? appHoverTint(theme.colorScheme),
      autofocus: autofocus,
      enableFeedback: false,
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: borderRadius,
      customBorder: customBorder,
      canRequestFocus: canRequestFocus,
      excludeFromSemantics: excludeFromSemantics,
      child: child,
    );
  }

  /// Applies entry feedback to Material controls that own their ink response.
  static ThemeData entryTheme(BuildContext context) {
    final theme = Theme.of(context);
    final animate = !MediaQuery.disableAnimationsOf(context);
    return theme.copyWith(
      splashFactory: AppTapHighlightFactory.forPlatform(
        theme.platform,
        animate: animate,
      ),
      splashColor: appPressedTint(theme.colorScheme),
      hoverColor: appHoverTint(theme.colorScheme),
      highlightColor: Colors.transparent,
    );
  }
}
