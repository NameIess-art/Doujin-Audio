import 'package:flutter/material.dart';

import '../theme/app_styles.dart';

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
      shape: const RoundedRectangleBorder(borderRadius: AppRadius.borderMedium),
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
      shape: const RoundedRectangleBorder(borderRadius: AppRadius.borderMedium),
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

class AppIconButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final IconData icon;
  final String tooltip;
  final Color? color;
  final double iconSize;
  final double containerSize;

  const AppIconButton({
    super.key,
    required this.onPressed,
    required this.icon,
    required this.tooltip,
    this.color,
    this.iconSize = 24.0,
    this.containerSize = 48.0,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        clipBehavior: Clip.hardEdge,
        child: InkWell(
          onTap: onPressed,
          child: SizedBox(
            width: containerSize,
            height: containerSize,
            child: Center(
              child: Icon(
                icon,
                size: iconSize,
                color: color ?? theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
