import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

enum AppFeedbackTone { info, success, warning, destructive }

OverlayEntry? _activeFeedbackEntry;
Timer? _activeFeedbackTimer;

void showAppSnackBar(
  BuildContext context,
  String message, {
  AppFeedbackTone tone = AppFeedbackTone.info,
  IconData? icon,
  Color? iconColor,
  Duration duration = const Duration(milliseconds: 1100),
}) {
  _showTopFeedback(
    context,
    message,
    tone: tone,
    icon: icon,
    iconColor: iconColor,
    duration: duration,
  );
}

@Deprecated('Use showAppSnackBar instead. This alias will be removed.')
void showAppToast(
  BuildContext context,
  String message, {
  AppFeedbackTone tone = AppFeedbackTone.info,
  IconData? icon,
  Color? iconColor,
  Duration duration = const Duration(milliseconds: 1100),
}) {
  showAppSnackBar(
    context,
    message,
    tone: tone,
    icon: icon,
    iconColor: iconColor,
    duration: duration,
  );
}

void _showTopFeedback(
  BuildContext context,
  String message, {
  required AppFeedbackTone tone,
  IconData? icon,
  Color? iconColor,
  required Duration duration,
}) {
  final overlay = Overlay.of(context, rootOverlay: true);
  final resolvedIcon = icon ?? _defaultIconForTone(tone);
  HapticFeedback.selectionClick();

  _activeFeedbackTimer?.cancel();
  _activeFeedbackEntry?.remove();

  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (overlayContext) {
      final topInset = MediaQuery.of(overlayContext).padding.top + 10;

      return Positioned(
        top: topInset,
        left: 16,
        right: 16,
        child: _FeedbackAnimationWrapper(
          duration: duration,
          onRemove: () {
            if (_activeFeedbackEntry == entry) {
              _activeFeedbackEntry = null;
            }
            entry.remove();
          },
          child: IgnorePointer(
            child: Material(
              color: Colors.transparent,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: AppFeedbackSurface(
                    tone: tone,
                    icon: resolvedIcon,
                    iconColor: iconColor,
                    message: message,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );

  overlay.insert(entry);
  _activeFeedbackEntry = entry;
}

class _FeedbackAnimationWrapper extends StatefulWidget {
  const _FeedbackAnimationWrapper({
    required this.child,
    required this.duration,
    required this.onRemove,
  });

  final Widget child;
  final Duration duration;
  final VoidCallback onRemove;

  @override
  State<_FeedbackAnimationWrapper> createState() =>
      _FeedbackAnimationWrapperState();
}

class _FeedbackAnimationWrapperState extends State<_FeedbackAnimationWrapper>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;
  late final Animation<Offset> _offset;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    _opacity = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    _offset = Tween<Offset>(
      begin: const Offset(0, -0.08),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));

    _controller.forward();

    final stayDuration = widget.duration - const Duration(milliseconds: 250);
    Future.delayed(
      stayDuration > Duration.zero ? stayDuration : Duration.zero,
      () {
        if (mounted) {
          _controller.reverse().then((_) {
            if (mounted) widget.onRemove();
          });
        }
      },
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacity,
      child: SlideTransition(position: _offset, child: widget.child),
    );
  }
}

class AppFeedbackSurface extends StatelessWidget {
  const AppFeedbackSurface({
    super.key,
    required this.tone,
    required this.icon,
    required this.message,
    this.title,
    this.trailing,
    this.padding = const EdgeInsets.fromLTRB(16, 14, 16, 14),
    this.borderRadius = 22,
    this.iconColor,
  });

  final AppFeedbackTone tone;
  final IconData icon;
  final String message;
  final String? title;
  final Widget? trailing;
  final EdgeInsets padding;
  final double borderRadius;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final accent = iconColor ?? _accentColor(context, tone);
    final chipBackground = accent.withValues(alpha: 0.12);

    final isDark = theme.brightness == Brightness.dark;
    final surfaceColor = isDark
        ? cs.surfaceContainerHighest.withValues(alpha: 0.95)
        : cs.surfaceContainerHigh.withValues(alpha: 0.98);

    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: surfaceColor,
            borderRadius: BorderRadius.circular(borderRadius),
            border: Border.all(
              color: cs.outlineVariant.withValues(alpha: 0.18),
            ),
            boxShadow: [
              BoxShadow(
                color: cs.shadow.withValues(alpha: 0.12),
                blurRadius: 24,
                offset: const Offset(0, 12),
              ),
              BoxShadow(
                color: cs.shadow.withValues(alpha: 0.06),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Padding(
            padding: padding,
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: chipBackground,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, size: 18, color: accent),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (title != null) ...[
                        Text(
                          title!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: cs.onSurface,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 2),
                      ],
                      Text(
                        message,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style:
                            (title != null
                                    ? theme.textTheme.bodyMedium
                                    : theme.textTheme.titleSmall)
                                ?.copyWith(
                                  color: title != null
                                      ? cs.onSurfaceVariant
                                      : cs.onSurface,
                                  fontWeight: title != null
                                      ? FontWeight.w600
                                      : FontWeight.w800,
                                  height: 1.25,
                                ),
                      ),
                    ],
                  ),
                ),
                if (trailing != null) ...[const SizedBox(width: 12), trailing!],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Color _accentColor(BuildContext context, AppFeedbackTone tone) {
  final theme = Theme.of(context);
  final cs = theme.colorScheme;
  final isDark = theme.brightness == Brightness.dark;

  switch (tone) {
    case AppFeedbackTone.info:
      return isDark ? cs.primary : cs.primary;
    case AppFeedbackTone.success:
      return isDark ? Colors.greenAccent.shade200 : Colors.green.shade900;
    case AppFeedbackTone.warning:
      return isDark ? Colors.orangeAccent.shade100 : Colors.orange.shade900;
    case AppFeedbackTone.destructive:
      return isDark
          ? const Color(0xFFFFB4AB)
          : const Color(0xFFBA1A1A); // Custom light/dark error colors
  }
}

IconData _defaultIconForTone(AppFeedbackTone tone) {
  switch (tone) {
    case AppFeedbackTone.info:
      return Icons.info_outline_rounded;
    case AppFeedbackTone.success:
      return Icons.check_circle_outline_rounded;
    case AppFeedbackTone.warning:
      return Icons.warning_amber_rounded;
    case AppFeedbackTone.destructive:
      return Icons.delete_outline_rounded;
  }
}
