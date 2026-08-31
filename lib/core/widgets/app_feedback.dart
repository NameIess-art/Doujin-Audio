import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import '../../app/state/app_runtime_providers.dart';
import '../../app/theme/app_design_tokens.dart';
import '../../app/theme/app_styles.dart';
import '../ui/app_interaction_feedback_settings.dart';
import '../ui/undoable_removal_service.dart';
import '../ui/ui_operation_service.dart';
import '../logging/app_log_service.dart';

enum AppFeedbackTone { info, success, warning, destructive }

enum AppInteractionFeedbackType { tap, selection, confirmation, destructive }

enum AppFeedbackDismissReason { timeout, action, swipe, replaced, updated }

const Duration kUndoableRemovalFeedbackDuration = Duration(seconds: 4);
const String _undoableRemovalFeedbackGroup = 'undoable-removal';

OverlayEntry? _activeFeedbackEntry;
Timer? _activeFeedbackTimer;
void Function(AppFeedbackDismissReason reason)? _activeFeedbackRemove;
Object? _activeFeedbackReplacementGroup;

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
  Object? replacementGroup,
  ValueChanged<AppFeedbackDismissReason>? onDismissed,
  bool provideHapticFeedback = true,
  bool? showCountdown,
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
    replacementGroup: replacementGroup,
    onDismissed: onDismissed,
    provideHapticFeedback: provideHapticFeedback,
    showCountdown:
        showCountdown ??
        (tone == AppFeedbackTone.destructive ||
            replacementGroup == _undoableRemovalFeedbackGroup),
  );
}

Future<bool> showUndoableRemovalFeedback(
  BuildContext context, {
  required UndoableRemovalService service,
  required UndoableRemovalAction action,
  required String message,
  required String Function(int count) batchMessage,
  required String undoLabel,
  required String failureMessage,
  IconData icon = Icons.delete_outline_rounded,
}) async {
  final staged = await service.stage(action);
  if (!staged) {
    if (context.mounted) {
      showAppSnackBar(
        context,
        failureMessage,
        tone: AppFeedbackTone.destructive,
        icon: Icons.error_outline_rounded,
      );
    }
    return false;
  }
  if (!context.mounted) {
    await service.commitPending();
    return true;
  }
  showPendingUndoableRemovalFeedback(
    context,
    service: service,
    message: message,
    batchMessage: batchMessage,
    undoLabel: undoLabel,
    failureMessage: failureMessage,
    icon: icon,
  );
  return true;
}

void showPendingUndoableRemovalFeedback(
  BuildContext context, {
  required UndoableRemovalService service,
  required String message,
  required String Function(int count) batchMessage,
  required String undoLabel,
  required String failureMessage,
  IconData icon = Icons.delete_outline_rounded,
}) {
  final count = service.state.pendingCount;
  if (count == 0) return;
  showAppSnackBar(
    context,
    count == 1 ? message : batchMessage(count),
    tone: AppFeedbackTone.destructive,
    icon: icon,
    duration: kUndoableRemovalFeedbackDuration,
    actionLabel: undoLabel,
    onAction: () => unawaited(service.undoPending()),
    replacementGroup: _undoableRemovalFeedbackGroup,
    onDismissed: (reason) {
      if (reason == AppFeedbackDismissReason.action ||
          reason == AppFeedbackDismissReason.updated) {
        return;
      }
      unawaited(
        service.commitPending().then((failures) {
          if (failures == 0 || !context.mounted) return;
          showAppSnackBar(
            context,
            failureMessage,
            tone: AppFeedbackTone.destructive,
            icon: Icons.error_outline_rounded,
          );
        }),
      );
    },
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
  Object? replacementGroup,
  ValueChanged<AppFeedbackDismissReason>? onDismissed,
  required bool provideHapticFeedback,
  bool showCountdown = false,
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
  final replacementReason =
      replacementGroup != null &&
          replacementGroup == _activeFeedbackReplacementGroup
      ? AppFeedbackDismissReason.updated
      : AppFeedbackDismissReason.replaced;
  _activeFeedbackRemove?.call(replacementReason);

  final dismissKey = Object();
  late final OverlayEntry entry;
  var removed = false;
  void removeEntry(AppFeedbackDismissReason reason) {
    if (removed) return;
    removed = true;
    if (_activeFeedbackEntry == entry) {
      _activeFeedbackEntry = null;
      _activeFeedbackRemove = null;
      _activeFeedbackReplacementGroup = null;
    }
    entry.remove();
    onDismissed?.call(reason);
  }

  entry = OverlayEntry(
    builder: (overlayContext) {
      final mediaQuery = MediaQuery.of(overlayContext);
      final isLandscape =
          mediaQuery.orientation == Orientation.landscape ||
          mediaQuery.size.width >= 980;
      final topInset =
          mediaQuery.padding.top +
          AppPageHeaderMetrics.mainTabPadding.top +
          36.0 +
          6.0;

      double leftInset = 16.0;
      var availableWidth = mediaQuery.size.width;
      if (isLandscape) {
        double derivedLeft = 0;
        if (context.mounted) {
          RenderBox? targetBox;
          context.visitAncestorElements((element) {
            final key = element.widget.key;
            if (key is ValueKey<String>) {
              final keyStr = key.value;
              if (keyStr.startsWith('main_page_canvas_') ||
                  keyStr.startsWith('audio_library_') ||
                  keyStr.startsWith('main_destination_')) {
                final box = element.findRenderObject() as RenderBox?;
                if (box != null && box.hasSize) {
                  targetBox = box;
                  return false;
                }
              }
            }
            return true;
          });
          targetBox ??= context.findRenderObject() as RenderBox?;
          if (targetBox != null && targetBox!.hasSize) {
            final origin = targetBox!.localToGlobal(Offset.zero);
            availableWidth = origin.dx + targetBox!.size.width;
            if (origin.dx > 40 && origin.dx < mediaQuery.size.width * 0.7) {
              derivedLeft = origin.dx;
            }
          }
        }
        if (derivedLeft <= 0) {
          derivedLeft = mediaQuery.size.width >= 980 ? 292 : 260;
        }
        leftInset = derivedLeft + 16.0;
      }
      if (availableWidth < 600) {
        leftInset = 16.0;
      } else {
        final maximumLeftInset = availableWidth - 16.0 - 240;
        if (leftInset > maximumLeftInset) {
          leftInset = maximumLeftInset.clamp(16.0, leftInset);
        }
      }

      return Positioned(
        top: topInset,
        left: leftInset,
        right: 16.0,
        child: _FeedbackAnimationWrapper(
          duration: duration,
          transitionDuration: AppDesignTokens.of(overlayContext).motionStandard,
          showCountdown: showCountdown,
          onRemove: () => removeEntry(AppFeedbackDismissReason.timeout),
          builder: (wrapperContext, remainingSeconds) {
            final isRemovalAction =
                hasAction &&
                replacementGroup == _undoableRemovalFeedbackGroup &&
                remainingSeconds != null;
            final resolvedActionLabel = hasAction
                ? (isRemovalAction
                    ? '$actionLabel (${remainingSeconds}s)'
                    : actionLabel)
                : null;
            return Dismissible(
              key: ValueKey<Object>(dismissKey),
              onDismissed: (_) => removeEntry(AppFeedbackDismissReason.swipe),
              child: Material(
                color: Colors.transparent,
                child: AppFeedbackSurface(
                  tone: tone,
                  icon: resolvedIcon,
                  iconColor: iconColor,
                  title: title,
                  message: message,
                  remainingSeconds: hasAction ? null : remainingSeconds,
                  trailing: hasAction
                      ? TextButton(
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 4,
                            ),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            shape: const StadiumBorder(),
                          ),
                          onPressed: () {
                            removeEntry(AppFeedbackDismissReason.action);
                            onAction();
                          },
                          child: Text(resolvedActionLabel!),
                        )
                      : null,
                ),
              ),
            );
          },
        ),
      );
    },
  );

  overlay.insert(entry);
  _activeFeedbackEntry = entry;
  _activeFeedbackRemove = removeEntry;
  _activeFeedbackReplacementGroup = replacementGroup;
}

class _FeedbackAnimationWrapper extends StatefulWidget {
  const _FeedbackAnimationWrapper({
    required this.builder,
    required this.duration,
    required this.transitionDuration,
    required this.onRemove,
    this.showCountdown = false,
  });

  final Widget Function(BuildContext context, int? remainingSeconds) builder;
  final Duration duration;
  final Duration transitionDuration;
  final VoidCallback onRemove;
  final bool showCountdown;

  @override
  State<_FeedbackAnimationWrapper> createState() =>
      _FeedbackAnimationWrapperState();
}

class _FeedbackAnimationWrapperState extends State<_FeedbackAnimationWrapper>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;
  Timer? _dismissTimer;
  Timer? _countdownTimer;
  late int _remainingSeconds;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.transitionDuration,
    );
    _opacity = CurvedAnimation(parent: _controller, curve: Curves.easeOut);

    _controller.forward();

    final totalSeconds = (widget.duration.inMilliseconds / 1000).ceil();
    _remainingSeconds = totalSeconds > 0 ? totalSeconds : 1;

    if (widget.showCountdown && totalSeconds > 1) {
      _countdownTimer = Timer.periodic(
        const Duration(seconds: 1),
        (_) {
          if (!mounted) return;
          if (_remainingSeconds > 1) {
            setState(() {
              _remainingSeconds--;
            });
          }
        },
      );
    }

    final stayDuration = widget.duration - widget.transitionDuration;
    _dismissTimer = Timer(
      stayDuration > Duration.zero ? stayDuration : Duration.zero,
      () {
        if (!mounted) return;
        _countdownTimer?.cancel();
        _controller.reverse().then((_) {
          if (mounted) widget.onRemove();
        });
      },
    );
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _dismissTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final content = widget.builder(
      context,
      widget.showCountdown ? _remainingSeconds : null,
    );
    if (MediaQuery.disableAnimationsOf(context)) return content;
    return FadeTransition(opacity: _opacity, child: content);
  }
}

class AppFeedbackSurface extends ConsumerWidget {
  const AppFeedbackSurface({
    super.key,
    required this.tone,
    required this.icon,
    required this.message,
    this.remainingSeconds,
    this.title,
    this.trailing,
    this.padding = const EdgeInsets.fromLTRB(10, 8, 14, 8),
    this.borderRadius,
    this.iconColor,
  });

  final AppFeedbackTone tone;
  final IconData icon;
  final String message;
  final int? remainingSeconds;
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
    final chipBackground = accent.withValues(alpha: 0.14);
    final resolvedBorderRadius = borderRadius ?? tokens.radiusCapsule;

    final isDark = theme.brightness == Brightness.dark;
    final baseSurfaceColor = isDark
        ? cs.surfaceBright
        : cs.surfaceContainerHigh;
    final surfaceColor = blurEnabled
        ? baseSurfaceColor.withValues(alpha: isDark ? 0.72 : 0.78)
        : baseSurfaceColor;

    final displayMessage = remainingSeconds != null
        ? '$message (${remainingSeconds}s)'
        : message;

    final surface = DecoratedBox(
      decoration: BoxDecoration(
        color: surfaceColor,
        borderRadius: BorderRadius.circular(resolvedBorderRadius),
        border: Border.all(
          color: cs.outlineVariant.withValues(alpha: isDark ? 0.24 : 0.42),
        ),
        boxShadow: [
          BoxShadow(
            color: cs.shadow.withValues(alpha: 0.14),
            blurRadius: 18,
            spreadRadius: -5,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Padding(
        padding: padding,
        child: Row(
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: chipBackground,
                shape: BoxShape.circle,
              ),
              child: Center(child: Icon(icon, size: 16, color: accent)),
            ),
            const SizedBox(width: 10),
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
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: cs.onSurface,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 1),
                  ],
                  Text(
                    displayMessage,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style:
                        (title != null
                                ? theme.textTheme.bodySmall
                                : theme.textTheme.labelLarge)
                            ?.copyWith(
                              color: title != null
                                  ? cs.onSurfaceVariant
                                  : cs.onSurface,
                              fontWeight: title != null
                                  ? FontWeight.w600
                                  : FontWeight.w700,
                              height: 1.25,
                            ),
                  ),
                ],
              ),
            ),
            if (trailing != null) ...[const SizedBox(width: 8), trailing!],
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
