import 'package:flutter/material.dart';

import 'app_feedback.dart';

@immutable
class SwipeRevealAction {
  const SwipeRevealAction({
    required this.icon,
    required this.onPressed,
    this.iconWidget,
    this.tooltip,
    this.primary = false,
    this.destructive = false,
    this.feedback = AppInteractionFeedbackType.selection,
  });

  final IconData icon;
  final Widget? iconWidget;
  final String? tooltip;
  final VoidCallback onPressed;
  final bool primary;
  final bool destructive;
  final AppInteractionFeedbackType feedback;
}

/// Draws the revealed actions; gesture and close state belong to the card.
class SwipeRevealActionPane extends StatelessWidget {
  const SwipeRevealActionPane({
    super.key,
    required this.actions,
    required this.fromStart,
    required this.vertical,
    required this.width,
    required this.progress,
    required this.shape,
    required this.label,
    required this.tooltip,
    required this.onAction,
    this.color,
  });

  final List<SwipeRevealAction> actions;
  final bool fromStart;
  final bool vertical;
  final double width;
  final double progress;
  final ShapeBorder shape;
  final String label;
  final String tooltip;
  final Color? color;
  final ValueChanged<VoidCallback> onAction;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final destructive = actions.any((action) => action.destructive);
    final baseColor =
        color ??
        (destructive
            ? Theme.of(context).brightness == Brightness.dark
                  ? ColorScheme.fromSeed(seedColor: cs.primary).error
                  : cs.error
            : cs.primary);
    final onColor =
        ThemeData.estimateBrightnessForColor(baseColor) == Brightness.dark
        ? const Color(0xFFF8F5F7)
        : const Color(0xFF211F23);
    final revealShape = switch (shape) {
      final OutlinedBorder shape => shape.copyWith(side: BorderSide.none),
      final ShapeBorder shape => shape,
    };
    final showVertical = vertical && actions.length > 1;

    Widget button(SwipeRevealAction action, double size) {
      final background = action.primary
          ? action.destructive
                ? onColor
                : onColor.withValues(alpha: 0.3)
          : onColor.withValues(alpha: 0.18);
      return SwipeRevealActionButton(
        onPressed: () {
          AppInteractionFeedback.trigger(action.feedback);
          onAction(action.onPressed);
        },
        backgroundColor: background,
        foregroundColor: action.destructive ? baseColor : onColor,
        tooltip: action.tooltip,
        icon: action.icon,
        iconWidget: action.iconWidget,
        tonal: !action.destructive,
        size: size,
      );
    }

    return DecoratedBox(
      decoration: ShapeDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color.lerp(baseColor, onColor, 0.08)!, baseColor],
        ),
        shape: revealShape,
      ),
      child: Stack(
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: EdgeInsets.only(
                left: 18,
                right: showVertical
                    ? width + 26
                    : actions.length > 2
                    ? 216
                    : actions.length > 1
                    ? 158
                    : 86,
              ),
              child: fromStart || progress == 0
                  ? const SizedBox.shrink()
                  : AnimatedOpacity(
                      opacity: 0.24 + progress * 0.76,
                      duration: const Duration(milliseconds: 160),
                      curve: Curves.easeOutCubic,
                      child: LayoutBuilder(
                        builder: (context, constraints) => Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 5,
                              ),
                              decoration: BoxDecoration(
                                color: onColor.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(999),
                                border: Border.all(
                                  color: onColor.withValues(alpha: 0.18),
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.swipe_left_rounded,
                                    size: 14,
                                    color: onColor,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    label,
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelMedium
                                        ?.copyWith(
                                          color: onColor,
                                          fontWeight: FontWeight.w800,
                                        ),
                                  ),
                                ],
                              ),
                            ),
                            if (constraints.maxHeight >= 64) ...[
                              const SizedBox(height: 8),
                              Text(
                                tooltip,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(
                                      color: onColor,
                                      fontWeight: FontWeight.w600,
                                    ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
            ),
          ),
          Align(
            alignment: fromStart ? Alignment.centerLeft : Alignment.centerRight,
            child: Padding(
              padding: EdgeInsets.only(
                top: showVertical ? 10 : 0,
                bottom: showVertical ? 10 : 0,
                left: fromStart ? (showVertical ? 10 : 14) : 0,
                right: fromStart ? 0 : (showVertical ? 10 : 14),
              ),
              child: AnimatedScale(
                scale: 0.92 + progress * 0.08,
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOutBack,
                child: showVertical
                    ? SizedBox(
                        width: width - 20,
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            const gap = 6.0;
                            final size =
                                ((constraints.maxHeight -
                                            gap * (actions.length - 1)) /
                                        actions.length)
                                    .clamp(34.0, 48.0);
                            return Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                for (
                                  var index = 0;
                                  index < actions.length;
                                  index++
                                ) ...[
                                  if (index > 0) const SizedBox(height: gap),
                                  button(actions[index], size),
                                ],
                              ],
                            );
                          },
                        ),
                      )
                    : LayoutBuilder(
                        builder: (context, constraints) {
                          final size = constraints.maxHeight.isFinite
                              ? (constraints.maxHeight - 20).clamp(34.0, 54.0)
                              : 54.0;
                          return Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              for (
                                var index = 0;
                                index < actions.length;
                                index++
                              ) ...[
                                if (index > 0) const SizedBox(width: 8),
                                button(actions[index], size),
                              ],
                            ],
                          );
                        },
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class SwipeRevealActionButton extends StatelessWidget {
  const SwipeRevealActionButton({
    super.key,
    required this.onPressed,
    required this.backgroundColor,
    required this.foregroundColor,
    required this.tooltip,
    required this.icon,
    this.iconWidget,
    this.tonal = false,
    this.size = 54,
  });

  final VoidCallback onPressed;
  final Color backgroundColor;
  final Color foregroundColor;
  final String? tooltip;
  final IconData icon;
  final Widget? iconWidget;
  final bool tonal;
  final double size;

  @override
  Widget build(BuildContext context) {
    final style = IconButton.styleFrom(
      backgroundColor: backgroundColor,
      foregroundColor: foregroundColor,
      minimumSize: Size.square(size),
      maximumSize: Size.square(size),
      padding: EdgeInsets.zero,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    final iconSize = (size * 0.46).clamp(16.0, 22.0);
    final effectiveIcon = iconWidget != null
        ? IconTheme.merge(
            data: IconThemeData(size: iconSize, color: foregroundColor),
            child: iconWidget!,
          )
        : Icon(icon, size: iconSize);
    return tonal
        ? IconButton.filledTonal(
            onPressed: onPressed,
            style: style,
            tooltip: tooltip,
            icon: effectiveIcon,
          )
        : IconButton.filled(
            onPressed: onPressed,
            style: style,
            tooltip: tooltip,
            icon: effectiveIcon,
          );
  }
}
