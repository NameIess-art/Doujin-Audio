import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme/app_design_tokens.dart';
import '../../app/theme/app_styles.dart';
import '../ui/app_interaction_feedback_settings.dart';
import '../ui/undoable_removal_service.dart';
import '../ui/ui_operation_service.dart';
import '../ui/ui_interaction_coordinator.dart';
import '../logging/app_log_service.dart';
import 'app_transitions.dart';
import 'mobile_overlay_inset.dart';

enum AppFeedbackTone { info, success, warning, destructive }

enum AppInteractionFeedbackType { tap, selection, confirmation, destructive }

enum AppFeedbackDismissReason { timeout, action, swipe, replaced, updated }

const Duration kUndoableRemovalFeedbackDuration = Duration(seconds: 5);
const String _undoableRemovalFeedbackGroup = 'undoable-removal';

class _FeedbackData {
  const _FeedbackData({
    required this.message,
    required this.tone,
    this.title,
    required this.icon,
    this.iconColor,
    required this.duration,
    this.actionLabel,
    this.onAction,
    required this.showCountdown,
    required this.showActionCountdown,
    required this.context,
    required this.dismissKey,
  });

  final String message;
  final AppFeedbackTone tone;
  final String? title;
  final IconData icon;
  final Color? iconColor;
  final Duration duration;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool showCountdown;
  final bool showActionCountdown;
  final BuildContext context;
  final Object dismissKey;

  _FeedbackData copyWith({
    String? message,
    AppFeedbackTone? tone,
    String? title,
    IconData? icon,
    Color? iconColor,
    Duration? duration,
    String? actionLabel,
    VoidCallback? onAction,
    bool? showCountdown,
    bool? showActionCountdown,
    BuildContext? context,
    Object? dismissKey,
  }) {
    return _FeedbackData(
      message: message ?? this.message,
      tone: tone ?? this.tone,
      title: title ?? this.title,
      icon: icon ?? this.icon,
      iconColor: iconColor ?? this.iconColor,
      duration: duration ?? this.duration,
      actionLabel: actionLabel ?? this.actionLabel,
      onAction: onAction ?? this.onAction,
      showCountdown: showCountdown ?? this.showCountdown,
      showActionCountdown: showActionCountdown ?? this.showActionCountdown,
      context: context ?? this.context,
      dismissKey: dismissKey ?? this.dismissKey,
    );
  }
}

OverlayEntry? _activeFeedbackEntry;
OverlayState? _activeFeedbackOverlay;
void Function(AppFeedbackDismissReason reason)? _activeFeedbackRemove;
void Function(_FeedbackData data)? _activeFeedbackUpdateData;
void Function([Duration? duration, bool? showCountdown])?
_activeFeedbackResetDuration;
ValueChanged<AppFeedbackDismissReason>? _activeFeedbackOnDismissed;
Object? _activeFeedbackReplacementGroup;
Object? _activeFeedbackReplacementOwner;
Object? _activeFeedbackDismissKey;
ValueNotifier<_FeedbackData>? _activeDataNotifier;

void Function(String message)? get _activeFeedbackUpdateMessage {
  if (_activeDataNotifier == null) return null;
  return (String nextMessage) {
    if (_activeDataNotifier != null &&
        _activeDataNotifier!.value.message != nextMessage) {
      _activeDataNotifier!.value = _activeDataNotifier!.value.copyWith(
        message: nextMessage,
      );
    }
  };
}

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
    if (defaultTargetPlatform == TargetPlatform.windows ||
        !hapticFeedbackEnabled) {
      return Future<void>.value();
    }
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
    if (defaultTargetPlatform == TargetPlatform.windows ||
        !hapticFeedbackEnabled) {
      return Future<void>.value();
    }
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
  Object? replacementOwner,
  ValueChanged<AppFeedbackDismissReason>? onDismissed,
  bool provideHapticFeedback = true,
  bool? showCountdown,
  bool? showActionCountdown,
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
            ? const Duration(seconds: 5)
            : const Duration(seconds: 2)),
    actionLabel: actionLabel,
    onAction: onAction,
    replacementGroup: replacementGroup,
    replacementOwner: replacementOwner,
    onDismissed: onDismissed,
    provideHapticFeedback: provideHapticFeedback,
    showCountdown:
        showCountdown ??
        (tone == AppFeedbackTone.destructive ||
            replacementGroup == _undoableRemovalFeedbackGroup ||
            showActionCountdown == true),
    showActionCountdown:
        showActionCountdown ??
        (replacementGroup == _undoableRemovalFeedbackGroup),
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
  final nextMessage = count == 1 ? message : batchMessage(count);
  if (_activeFeedbackReplacementGroup == _undoableRemovalFeedbackGroup &&
      identical(_activeFeedbackReplacementOwner, service) &&
      _activeFeedbackOverlay ==
          (MobileOverlayInset.menuOverlayOf(context) ?? Overlay.of(context)) &&
      _activeFeedbackUpdateMessage != null) {
    _activeFeedbackUpdateMessage!(nextMessage);
    _activeFeedbackResetDuration?.call();
    unawaited(
      AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection),
    );
    return;
  }
  showAppSnackBar(
    context,
    nextMessage,
    tone: AppFeedbackTone.destructive,
    icon: icon,
    duration: kUndoableRemovalFeedbackDuration,
    actionLabel: undoLabel,
    onAction: () => unawaited(service.undoPending()),
    replacementGroup: _undoableRemovalFeedbackGroup,
    replacementOwner: service,
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
  Object? replacementOwner,
  ValueChanged<AppFeedbackDismissReason>? onDismissed,
  required bool provideHapticFeedback,
  bool showCountdown = false,
  bool showActionCountdown = false,
}) {
  final overlay =
      MobileOverlayInset.menuOverlayOf(context) ?? Overlay.of(context);
  final resolvedIcon = icon ?? _defaultIconForTone(tone);
  if (provideHapticFeedback) {
    unawaited(
      AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection),
    );
  }

  final replacementReason =
      replacementGroup != null &&
          replacementGroup == _activeFeedbackReplacementGroup &&
          identical(replacementOwner, _activeFeedbackReplacementOwner)
      ? AppFeedbackDismissReason.updated
      : AppFeedbackDismissReason.replaced;

  if (_activeFeedbackEntry != null &&
      _activeFeedbackEntry!.mounted &&
      _activeFeedbackOverlay == overlay &&
      _activeFeedbackUpdateData != null &&
      _activeFeedbackResetDuration != null) {
    final previousOnDismissed = _activeFeedbackOnDismissed;
    _activeFeedbackOnDismissed = onDismissed;
    _activeFeedbackReplacementGroup = replacementGroup;
    _activeFeedbackReplacementOwner = replacementOwner;
    previousOnDismissed?.call(replacementReason);

    final updatedData = _FeedbackData(
      message: message,
      tone: tone,
      title: title,
      icon: resolvedIcon,
      iconColor: iconColor,
      duration: duration,
      actionLabel: actionLabel,
      onAction: onAction,
      showCountdown: showCountdown,
      showActionCountdown: showActionCountdown,
      context: context,
      dismissKey: _activeFeedbackDismissKey ?? Object(),
    );

    _activeFeedbackUpdateData!(updatedData);
    _activeFeedbackResetDuration!(duration, showCountdown);
    return;
  }

  _activeFeedbackRemove?.call(replacementReason);

  final dismissKey = Object();
  _activeFeedbackDismissKey = dismissKey;
  _activeFeedbackReplacementGroup = replacementGroup;
  _activeFeedbackReplacementOwner = replacementOwner;
  _activeFeedbackOnDismissed = onDismissed;

  final animationKey = GlobalKey<_FeedbackAnimationWrapperState>();
  final initialData = _FeedbackData(
    message: message,
    tone: tone,
    title: title,
    icon: resolvedIcon,
    iconColor: iconColor,
    duration: duration,
    actionLabel: actionLabel,
    onAction: onAction,
    showCountdown: showCountdown,
    showActionCountdown: showActionCountdown,
    context: context,
    dismissKey: dismissKey,
  );
  final dataNotifier = ValueNotifier<_FeedbackData>(initialData);
  _activeDataNotifier = dataNotifier;
  var dismissCallback = onDismissed;

  late final OverlayEntry entry;
  late final VoidCallback removeWhenUnmounted;
  var removed = false;
  var dismissed = false;
  void finishDismissal(AppFeedbackDismissReason reason) {
    if (dismissed) return;
    dismissed = true;
    if (_activeFeedbackEntry == entry) {
      _activeFeedbackEntry = null;
      _activeFeedbackOverlay = null;
      _activeFeedbackRemove = null;
      _activeFeedbackUpdateData = null;
      _activeFeedbackResetDuration = null;
      _activeFeedbackOnDismissed = null;
      _activeFeedbackReplacementGroup = null;
      _activeFeedbackReplacementOwner = null;
      _activeFeedbackDismissKey = null;
      _activeDataNotifier = null;
    }
    dismissCallback?.call(reason);
  }

  void removeEntry(AppFeedbackDismissReason reason) {
    if (removed) return;
    removed = true;
    finishDismissal(reason);
    dataNotifier.dispose();
    entry.removeListener(removeWhenUnmounted);
    entry.remove();
    entry.dispose();
  }

  void dismissEntry(AppFeedbackDismissReason reason) {
    if (removed || dismissed) return;
    // End the action/undo contract immediately; retain only its fading pixels.
    finishDismissal(reason);
    final state = animationKey.currentState;
    if (state == null) {
      removeEntry(reason);
    } else {
      state.dismiss(() => removeEntry(reason));
    }
  }

  removeWhenUnmounted = () {
    if (!entry.mounted) {
      // Overlay disposal also ends the undo window; finish outside teardown.
      scheduleMicrotask(() => removeEntry(AppFeedbackDismissReason.replaced));
    }
  };

  entry = OverlayEntry(
    builder: (overlayContext) {
      return ValueListenableBuilder<_FeedbackData>(
        valueListenable: dataNotifier,
        builder: (context, currentData, _) {
          final mediaQuery = MediaQuery.of(overlayContext);
          final isLandscape =
              mediaQuery.orientation == Orientation.landscape ||
              mediaQuery.size.width >= 980;
          final topInset =
              mediaQuery.padding.top +
              AppPageHeaderMetrics.mainTabPadding.top +
              36.0 +
              6.0;

          var leftInset = 16.0;
          var rightInset = 16.0;
          if (isLandscape && currentData.context.mounted) {
            RenderBox? targetBox;
            bool findCanvas(Element element) {
              final key = element.widget.key;
              if (key is ValueKey<String> && key.value == 'main_page_canvas') {
                final box = element.findRenderObject();
                if (box is RenderBox && box.hasSize) {
                  targetBox = box;
                  return false;
                }
              }
              return true;
            }

            currentData.context.visitAncestorElements(findCanvas);
            if (targetBox == null) {
              // Main-screen and navigation callbacks sit outside the page canvas.
              // Search only their own route so standalone pages keep their bounds.
              void visit(Element element) {
                if (targetBox != null) return;
                final widget = element.widget;
                if (widget is Offstage && widget.offstage) return;
                if (findCanvas(element)) element.visitChildren(visit);
              }

              final routeContext = readAppRoute(
                currentData.context,
              )?.subtreeContext;
              if (routeContext is Element) visit(routeContext);
            }
            final box = targetBox;
            final overlayBox = overlay.context.findRenderObject();
            if (box != null && overlayBox is RenderBox) {
              final origin = box.localToGlobal(
                Offset.zero,
                ancestor: overlayBox,
              );
              leftInset = origin.dx + 16.0;
              rightInset =
                  overlayBox.size.width - origin.dx - box.size.width + 16.0;
            }
          }

          final hasAction =
              currentData.actionLabel != null &&
              currentData.actionLabel!.trim().isNotEmpty &&
              currentData.onAction != null;

          return Positioned(
            top: topInset,
            left: leftInset,
            right: rightInset,
            child: _FeedbackAnimationWrapper(
              key: animationKey,
              duration: currentData.duration,
              transitionDuration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : kAppFadeDuration,
              showCountdown: currentData.showCountdown,
              onRemove: () => dismissEntry(AppFeedbackDismissReason.timeout),
              builder: (wrapperContext, remainingSeconds) {
                final isRemovalAction =
                    hasAction &&
                    currentData.showActionCountdown &&
                    remainingSeconds != null;
                final resolvedActionLabel = hasAction
                    ? (isRemovalAction
                          ? '${currentData.actionLabel!} (${remainingSeconds}s)'
                          : currentData.actionLabel!)
                    : null;
                return Dismissible(
                  key: ValueKey<Object>(currentData.dismissKey),
                  onDismissed: (_) =>
                      removeEntry(AppFeedbackDismissReason.swipe),
                  child: Material(
                    color: Colors.transparent,
                    child: AppFeedbackSurface(
                      tone: currentData.tone,
                      icon: currentData.icon,
                      iconColor: currentData.iconColor,
                      title: currentData.title,
                      message: currentData.message,
                      remainingSeconds: hasAction ? null : remainingSeconds,
                      trailing: hasAction
                          ? TextButton(
                              key: ValueKey((
                                currentData.message,
                                currentData.actionLabel,
                              )),
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
                                if (dismissed ||
                                    !identical(
                                      dataNotifier.value,
                                      currentData,
                                    )) {
                                  return;
                                }
                                dismissEntry(AppFeedbackDismissReason.action);
                                currentData.onAction!();
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
    },
  );

  overlay.insert(entry);
  _activeFeedbackEntry = entry;
  _activeFeedbackOverlay = overlay;
  _activeFeedbackRemove = dismissEntry;
  _activeFeedbackUpdateData = (nextData) {
    if (!removed && dataNotifier.value != nextData) {
      dismissCallback = _activeFeedbackOnDismissed;
      dataNotifier.value = nextData;
    }
  };
  _activeFeedbackResetDuration = ([dur, cd]) =>
      animationKey.currentState?.resetDuration(dur, cd);
  entry.addListener(removeWhenUnmounted);
}

class _FeedbackAnimationWrapper extends StatefulWidget {
  const _FeedbackAnimationWrapper({
    super.key,
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
  Timer? _expiryTimer;
  Timer? _countdownTimer;
  late int _remainingSeconds;
  late Duration _currentDuration;
  late bool _currentShowCountdown;
  bool _dismissing = false;
  bool _tickerModeEnabled = true;
  VoidCallback? _onDismissed;

  @override
  void initState() {
    super.initState();
    _currentDuration = widget.duration;
    _currentShowCountdown = widget.showCountdown;
    _controller = AnimationController(
      vsync: this,
      duration: widget.transitionDuration,
    )..addStatusListener(_handleAnimationStatus);
    _opacity = CurvedAnimation(parent: _controller, curve: kAppFadeCurve);

    _controller.forward();
    _startDuration(_currentDuration, _currentShowCountdown);
  }

  void _handleAnimationStatus(AnimationStatus status) {
    final interaction = UiInteractionCoordinator.instance;
    if (!_tickerModeEnabled || widget.transitionDuration == Duration.zero) {
      interaction.cancelInteraction(this);
      return;
    }
    if (status == AnimationStatus.forward ||
        status == AnimationStatus.reverse) {
      // Catalog/metadata notifications must not rebuild the list beneath a
      // completion message while that message is fading.
      interaction.beginInteraction(this);
    } else {
      interaction.endInteraction(this);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickerModeEnabled = TickerMode.valuesOf(context).enabled;
    _handleAnimationStatus(_controller.status);
    if (!_tickerModeEnabled && _dismissing) {
      final onDismissed = _onDismissed;
      _onDismissed = null;
      if (onDismissed != null) scheduleMicrotask(onDismissed);
    }
  }

  void _startDuration(Duration duration, bool showCountdown) {
    _expiryTimer?.cancel();
    _countdownTimer?.cancel();
    final totalSeconds = (duration.inMilliseconds / 1000).ceil();
    _remainingSeconds = totalSeconds > 0 ? totalSeconds : 1;

    if (showCountdown && totalSeconds > 1) {
      _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        if (_remainingSeconds > 1) {
          setState(() {
            _remainingSeconds--;
          });
        }
      });
    }

    // Undo expires on its wall-clock deadline even if rendering is paused.
    _expiryTimer = Timer(duration, () {
      if (mounted) widget.onRemove();
    });
  }

  void resetDuration([Duration? duration, bool? showCountdown]) {
    if (!mounted) return;
    if (duration != null) _currentDuration = duration;
    if (showCountdown != null) _currentShowCountdown = showCountdown;
    _startDuration(_currentDuration, _currentShowCountdown);
    if (!_controller.isCompleted) {
      _controller.forward();
    }
    setState(() {});
  }

  void dismiss(VoidCallback onComplete) {
    if (_dismissing) return;
    _expiryTimer?.cancel();
    _countdownTimer?.cancel();
    if (widget.transitionDuration == Duration.zero || !_tickerModeEnabled) {
      onComplete();
      return;
    }
    _onDismissed = onComplete;
    setState(() => _dismissing = true);
    _controller.reverse().then((_) {
      if (!mounted) return;
      final onDismissed = _onDismissed;
      _onDismissed = null;
      onDismissed?.call();
    });
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _expiryTimer?.cancel();
    _onDismissed = null;
    UiInteractionCoordinator.instance.cancelInteraction(this);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final content = widget.builder(
      context,
      _currentShowCountdown ? _remainingSeconds : null,
    );
    return IgnorePointer(
      ignoring: _dismissing,
      child: ExcludeFocus(
        excluding: _dismissing,
        child: ExcludeSemantics(
          excluding: _dismissing,
          child: MediaQuery.disableAnimationsOf(context)
              ? content
              : FadeTransition(opacity: _opacity, child: content),
        ),
      ),
    );
  }
}

class AppFeedbackSurface extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final tokens = AppDesignTokens.of(context);
    final accent = iconColor ?? _accentColor(context, tone);
    final chipBackground = accent.withValues(alpha: 0.14);
    final resolvedBorderRadius = borderRadius ?? tokens.radiusCapsule;

    final isDark = theme.brightness == Brightness.dark;
    final surfaceColor = isDark ? cs.surfaceBright : cs.surfaceContainerHigh;

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
            AnimatedContainer(
              duration: tokens.motionFast,
              curve: Curves.easeOutCubic,
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: chipBackground,
                shape: BoxShape.circle,
              ),
              child: Center(
                child: AnimatedSwitcher(
                  duration: MediaQuery.disableAnimationsOf(context)
                      ? Duration.zero
                      : kAppFadeDuration,
                  switchInCurve: kAppFadeCurve,
                  switchOutCurve: kAppFadeCurve,
                  child: Icon(
                    icon,
                    key: ValueKey<IconData>(icon),
                    size: 16,
                    color: accent,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: AnimatedSize(
                duration: tokens.motionFast,
                curve: Curves.easeOutCubic,
                alignment: Alignment.centerLeft,
                child: AnimatedSwitcher(
                  duration: MediaQuery.disableAnimationsOf(context)
                      ? Duration.zero
                      : kAppFadeDuration,
                  switchInCurve: kAppFadeCurve,
                  switchOutCurve: kAppFadeCurve,
                  layoutBuilder: _feedbackContentLayout,
                  child: Column(
                    key: ValueKey((message, title)),
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
              ),
            ),
            AnimatedSwitcher(
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : kAppFadeDuration,
              switchInCurve: kAppFadeCurve,
              switchOutCurve: kAppFadeCurve,
              layoutBuilder: _feedbackContentLayout,
              child: trailing == null
                  ? const SizedBox.shrink()
                  : Padding(
                      key: trailing!.key,
                      padding: const EdgeInsets.only(left: 8),
                      child: trailing!,
                    ),
            ),
          ],
        ),
      ),
    );

    return ClipRRect(
      borderRadius: BorderRadius.circular(resolvedBorderRadius),
      child: surface,
    );
  }
}

Widget _feedbackContentLayout(
  Widget? currentChild,
  List<Widget> previousChildren,
) {
  return Stack(
    alignment: Alignment.centerLeft,
    children: [
      for (final child in previousChildren)
        IgnorePointer(
          child: ExcludeFocus(child: ExcludeSemantics(child: child)),
        ),
      ?currentChild,
    ],
  );
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
