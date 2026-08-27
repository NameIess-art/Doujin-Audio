import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import '../../app/state/app_runtime_providers.dart';
import '../../app/theme/app_design_tokens.dart';
import '../ui/app_interaction_feedback_settings.dart';
import '../ui/ui_operation_service.dart';
import '../logging/app_log_service.dart';

enum AppFeedbackTone { info, success, warning, destructive }

enum AppInteractionFeedbackType { tap, selection, confirmation, destructive }

OverlayEntry? _activeFeedbackEntry;
Timer? _activeFeedbackTimer;
VoidCallback? _activeFeedbackRemove;

abstract final class AppInteractionFeedback {
  static bool get hapticFeedbackEnabled =>
      AppInteractionFeedbackSettings.hapticFeedbackEnabled;

  static set hapticFeedbackEnabled(bool value) {
    AppInteractionFeedbackSettings.hapticFeedbackEnabled = value;
  }

  static DateTime? _lastContinuousFeedbackAt;
  static Object? _lastContinuousValue;

  static Future<void> trigger(
    AppInteractionFeedbackType type, {
    BuildContext? context,
  }) {
    if (!hapticFeedbackEnabled) return Future<void>.value();
    switch (type) {
      case AppInteractionFeedbackType.tap:
        return context == null
            ? HapticFeedback.lightImpact()
            : Feedback.forTap(context);
      case AppInteractionFeedbackType.selection:
        return HapticFeedback.selectionClick();
      case AppInteractionFeedbackType.confirmation:
        return HapticFeedback.mediumImpact();
      case AppInteractionFeedbackType.destructive:
        return HapticFeedback.heavyImpact();
    }
  }

  static Future<void> continuous(
    Object value, {
    Duration interval = const Duration(milliseconds: 72),
  }) {
    if (!hapticFeedbackEnabled) return Future<void>.value();
    final now = DateTime.now();
    final previousAt = _lastContinuousFeedbackAt;
    if (_lastContinuousValue == value ||
        (previousAt != null && now.difference(previousAt) < interval)) {
      return Future<void>.value();
    }
    _lastContinuousValue = value;
    _lastContinuousFeedbackAt = now;
    return HapticFeedback.selectionClick();
  }

  static void resetContinuous() {
    _lastContinuousFeedbackAt = null;
    _lastContinuousValue = null;
  }
}

void showAppSnackBar(
  BuildContext context,
  String message, {
  AppFeedbackTone tone = AppFeedbackTone.info,
  String? title,
  IconData? icon,
  Color? iconColor,
  Duration? duration,
  String? actionLabel,
  VoidCallback? onAction,
  bool provideHapticFeedback = true,
}) {
  _showTopFeedback(
    context,
    message,
    tone: tone,
    title: title,
    icon: icon,
    iconColor: iconColor,
    duration:
        duration ??
        (tone == AppFeedbackTone.destructive
            ? const Duration(seconds: 4)
            : const Duration(seconds: 2)),
    actionLabel: actionLabel,
    onAction: onAction,
    provideHapticFeedback: provideHapticFeedback,
  );
}

void _showTopFeedback(
  BuildContext context,
  String message, {
  required AppFeedbackTone tone,
  String? title,
  IconData? icon,
  Color? iconColor,
  required Duration duration,
  String? actionLabel,
  VoidCallback? onAction,
  required bool provideHapticFeedback,
}) {
  final overlay = Overlay.of(context, rootOverlay: true);
  final resolvedIcon = icon ?? _defaultIconForTone(tone);
  final hasAction =
      actionLabel != null && actionLabel.trim().isNotEmpty && onAction != null;
  if (provideHapticFeedback) {
    unawaited(
      AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection),
    );
  }

  _activeFeedbackTimer?.cancel();
  _activeFeedbackRemove?.call();

  final dismissKey = Object();
  late final OverlayEntry entry;
  var removed = false;
  void removeEntry() {
    if (removed) return;
    removed = true;
    if (_activeFeedbackEntry == entry) {
      _activeFeedbackEntry = null;
    }
    if (_activeFeedbackRemove == removeEntry) {
      _activeFeedbackRemove = null;
    }
    entry.remove();
  }

  entry = OverlayEntry(
    builder: (overlayContext) {
      final topInset = MediaQuery.of(overlayContext).padding.top + 10;

      return Positioned(
        top: topInset,
        left: 16,
        right: 16,
        child: Dismissible(
          key: ValueKey<Object>(dismissKey),
          direction: DismissDirection.startToEnd,
          onDismissed: (_) => removeEntry(),
          child: _FeedbackAnimationWrapper(
            duration: duration,
            transitionDuration: AppDesignTokens.of(
              overlayContext,
            ).motionStandard,
            onRemove: removeEntry,
            child: IgnorePointer(
              ignoring: !hasAction,
              child: Material(
                color: Colors.transparent,
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: AppFeedbackSurface(
                      tone: tone,
                      icon: resolvedIcon,
                      iconColor: iconColor,
                      title: title,
                      message: message,
                      trailing: hasAction
                          ? TextButton(
                              onPressed: () {
                                removeEntry();
                                onAction();
                              },
                              child: Text(actionLabel),
                            )
                          : null,
                    ),
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
  _activeFeedbackRemove = removeEntry;
}

class _FeedbackAnimationWrapper extends StatefulWidget {
  const _FeedbackAnimationWrapper({
    required this.child,
    required this.duration,
    required this.transitionDuration,
    required this.onRemove,
  });

  final Widget child;
  final Duration duration;
  final Duration transitionDuration;
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
  Timer? _dismissTimer;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.transitionDuration,
    );
    _opacity = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    _offset = Tween<Offset>(
      begin: const Offset(0, -0.08),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));

    _controller.forward();

    final stayDuration = widget.duration - widget.transitionDuration;
    _dismissTimer = Timer(
      stayDuration > Duration.zero ? stayDuration : Duration.zero,
      () {
        if (!mounted) return;
        _controller.reverse().then((_) {
          if (mounted) widget.onRemove();
        });
      },
    );
  }

  @override
  void dispose() {
    _dismissTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return widget.child;
    return FadeTransition(
      opacity: _opacity,
      child: SlideTransition(position: _offset, child: widget.child),
    );
  }
}

class AppFeedbackSurface extends ConsumerWidget {
  const AppFeedbackSurface({
    super.key,
    required this.tone,
    required this.icon,
    required this.message,
    this.title,
    this.trailing,
    this.padding = const EdgeInsets.fromLTRB(16, 14, 16, 14),
    this.borderRadius,
    this.iconColor,
  });

  final AppFeedbackTone tone;
  final IconData icon;
  final String message;
  final String? title;
  final Widget? trailing;
  final EdgeInsets padding;
  final double? borderRadius;
  final Color? iconColor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final tokens = AppDesignTokens.of(context);
    final blurEnabled = ref.watch(
      settingsStateProvider.select(
        (state) => state.value?.uiBlurEffectEnabled ?? true,
      ),
    );
    final accent = iconColor ?? _accentColor(context, tone);
    final chipBackground = accent.withValues(alpha: 0.12);
    final resolvedBorderRadius = borderRadius ?? tokens.radiusCard;

    final isDark = theme.brightness == Brightness.dark;
    final baseSurfaceColor = isDark
        ? cs.surfaceContainerHighest
        : cs.surfaceContainerHigh;
    final surfaceColor = blurEnabled
        ? baseSurfaceColor.withValues(alpha: isDark ? 0.80 : 0.86)
        : baseSurfaceColor;

    final surface = DecoratedBox(
      decoration: BoxDecoration(
        color: surfaceColor,
        borderRadius: BorderRadius.circular(resolvedBorderRadius),
        border: Border.all(
          color: cs.outlineVariant.withValues(alpha: tokens.subtleBorderAlpha),
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
              width: tokens.iconContainerSize,
              height: tokens.iconContainerSize,
              decoration: BoxDecoration(
                color: chipBackground,
                borderRadius: BorderRadius.circular(tokens.radiusSmall),
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
    );

    return ClipRRect(
      borderRadius: BorderRadius.circular(resolvedBorderRadius),
      child: blurEnabled
          ? BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
              child: surface,
            )
          : surface,
    );
  }
}

Color _accentColor(BuildContext context, AppFeedbackTone tone) {
  final cs = Theme.of(context).colorScheme;
  final tokens = AppDesignTokens.of(context);

  switch (tone) {
    case AppFeedbackTone.info:
      return cs.primary;
    case AppFeedbackTone.success:
      return tokens.success;
    case AppFeedbackTone.warning:
      return tokens.warning;
    case AppFeedbackTone.destructive:
      return cs.error;
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

extension UiOperationServiceFeedback on UiOperationService {
  Future<T?> runWithFeedback<T>({
    required BuildContext context,
    required UiOperationScope scope,
    required String labelKey,
    required UiOperationTask<T> task,
    required String failureMessage,
    required String operationFailedTitle,
    String? retryLabel,
    bool cancelPrevious = true,
    VoidCallback? onRetry,
  }) async {
    try {
      return await run<T>(
        scope: scope,
        labelKey: labelKey,
        task: task,
        cancelPrevious: cancelPrevious,
      );
    } catch (error, stackTrace) {
      AppLogService.error(
        'operation_failed: $scope',
        error: error,
        stackTrace: stackTrace,
      );
      if (context.mounted) {
        showAppSnackBar(
          context,
          failureMessage,
          tone: AppFeedbackTone.destructive,
          title: operationFailedTitle,
          icon: Icons.error_outline_rounded,
          actionLabel: onRetry != null ? retryLabel : null,
          onAction: onRetry,
          duration: onRetry != null ? const Duration(seconds: 6) : null,
        );
      }
      return null;
    }
  }
}
