import 'package:flutter/material.dart';

import '../../app/theme/app_styles.dart';

class AppOverlayIconButton extends StatelessWidget {
  const AppOverlayIconButton({
    super.key,
    this.buttonKey,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.buttonSize = AppPageHeaderMetrics.buttonSize,
    this.foregroundColor = Colors.white,
  });

  static const iconShadows = [
    Shadow(color: Color(0xA6000000), offset: Offset(0, 2), blurRadius: 5),
  ];

  final Key? buttonKey;
  final Widget icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final double buttonSize;
  final Color foregroundColor;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final size = Size.square(buttonSize);
    return IconButton(
      key: buttonKey,
      onPressed: onPressed,
      tooltip: tooltip,
      style:
          IconButton.styleFrom(
            fixedSize: size,
            minimumSize: size,
            maximumSize: size,
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.standard,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            iconSize: 32,
            backgroundColor: Colors.transparent,
            overlayColor: Colors.transparent,
            splashFactory: NoSplash.splashFactory,
            shape: const RoundedRectangleBorder(),
          ).copyWith(
            foregroundColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.disabled)) {
                return colors.onSurface.withValues(alpha: 0.38);
              }
              if (states.contains(WidgetState.hovered) ||
                  states.contains(WidgetState.focused)) {
                return colors.primary;
              }
              return foregroundColor;
            }),
          ),
      icon: IconTheme.merge(
        data: const IconThemeData(shadows: iconShadows),
        child: icon,
      ),
    );
  }
}

class AppPrimaryButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final String label;
  final IconData? icon;
  final bool isLoading;
  final bool isDestructive;

  const AppPrimaryButton({
    super.key,
    required this.onPressed,
    required this.label,
    this.icon,
    this.isLoading = false,
    this.isDestructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final foregroundColor = isDestructive
        ? colorScheme.onError
        : colorScheme.onPrimary;
    final backgroundColor = isDestructive
        ? colorScheme.error
        : colorScheme.primary;

    final style = FilledButton.styleFrom(
      foregroundColor: foregroundColor,
      backgroundColor: backgroundColor,
      minimumSize: const Size.fromHeight(48),
      shape: const StadiumBorder(),
      textStyle: theme.textTheme.labelLarge?.copyWith(
        fontWeight: FontWeight.bold,
      ),
    );

    if (isLoading) {
      return FilledButton.icon(
        onPressed: null,
        style: style,
        icon: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: foregroundColor,
          ),
        ),
        label: Text(label),
      );
    }

    if (icon != null) {
      return FilledButton.icon(
        onPressed: onPressed,
        style: style,
        icon: Icon(icon, size: 20),
        label: Text(label),
      );
    }

    return FilledButton(onPressed: onPressed, style: style, child: Text(label));
  }
}

class AppSecondaryButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final String label;
  final IconData? icon;
  final bool isDestructive;
  final bool isLoading;

  const AppSecondaryButton({
    super.key,
    required this.onPressed,
    required this.label,
    this.icon,
    this.isDestructive = false,
    this.isLoading = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final foregroundColor = isDestructive
        ? colorScheme.error
        : colorScheme.primary;

    final style = OutlinedButton.styleFrom(
      foregroundColor: foregroundColor,
      minimumSize: const Size.fromHeight(48),
      side: BorderSide(
        color: isDestructive
            ? colorScheme.error.withValues(alpha: 0.5)
            : colorScheme.outlineVariant,
      ),
      shape: const StadiumBorder(),
      textStyle: theme.textTheme.labelLarge?.copyWith(
        fontWeight: FontWeight.bold,
      ),
    );

    if (isLoading) {
      return OutlinedButton.icon(
        onPressed: null,
        style: style,
        icon: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: foregroundColor.withValues(alpha: 0.5),
          ),
        ),
        label: Text(label),
      );
    }

    if (icon != null) {
      return OutlinedButton.icon(
        onPressed: onPressed,
        style: style,
        icon: Icon(icon, size: 20),
        label: Text(label),
      );
    }

    return OutlinedButton(
      onPressed: onPressed,
      style: style,
      child: Text(label),
    );
  }
}
