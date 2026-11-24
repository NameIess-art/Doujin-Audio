import 'dart:async';
import 'dart:math' as math;

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
import 'app_buttons.dart';
import 'app_glass_surface.dart';
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
    this.iconWidget,
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
  final Widget? iconWidget;
  final Color? iconColor;
  final Duration? duration;
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
    Widget? iconWidget,
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
      iconWidget: iconWidget ?? this.iconWidget,
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
void Function(Duration? duration, bool showCountdown)?
_activeFeedbackResetDuration;
ValueChanged<AppFeedbackDismissReason>? _activeFeedbackOnDismissed;
Object? _activeFeedbackReplacementGroup;
Object? _activeFeedbackReplacementOwner;
Object? _activeFeedbackDismissKey;
ValueNotifier<_FeedbackData>? _activeDataNotifier;
_QueuedFeedback? _queuedFeedback;

class _QueuedFeedback {
  const _QueuedFeedback({
    required this.overlay,
    required this.context,
    required this.message,
    required this.tone,
    this.title,
    this.icon,
    this.iconWidget,
    this.iconColor,
    required this.duration,
    this.actionLabel,
    this.onAction,
    this.replacementGroup,
    this.replacementOwner,
    this.onDismissed,
    required this.provideHapticFeedback,
    required this.showCountdown,
    required this.showActionCountdown,
  });

  final OverlayState overlay;
  final BuildContext context;
  final String message;
  final AppFeedbackTone tone;
  final String? title;
  final IconData? icon;
  final Widget? iconWidget;
  final Color? iconColor;
  final Duration? duration;
  final String? actionLabel;
  final VoidCallback? onAction;
  final Object? replacementGroup;
  final Object? replacementOwner;
  final ValueChanged<AppFeedbackDismissReason>? onDismissed;
  final bool provideHapticFeedback;
  final bool showCountdown;
  final bool showActionCountdown;
}

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

  static Future<void> trigger(AppInteractionFeedbackType type) {
    if (defaultTargetPlatform == TargetPlatform.windows ||
        !hapticFeedbackEnabled) {
      return Future<void>.value();
    }
    switch (type) {
      case AppInteractionFeedbackType.tap:
        return HapticFeedback.lightImpact();
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
  Widget? iconWidget,
  Color? iconColor,
  Duration? duration,
  String? actionLabel,
  VoidCallback? onAction,
  Object? replacementGroup,
  Object? replacementOwner,
  ValueChanged<AppFeedbackDismissReason>? onDismissed,
  bool? provideHapticFeedback,
  bool? showCountdown,
  bool isUndoAction = false,
}) {
  _showTopFeedback(
    context,
    message,
    tone: tone,
    title: title,
    icon: icon,
    iconWidget: iconWidget,
    iconColor: iconColor,
    duration: isUndoAction
        ? kUndoableRemovalFeedbackDuration
        : duration ??
              (tone == AppFeedbackTone.destructive
                  ? const Duration(seconds: 5)
                  : const Duration(seconds: 2)),
    actionLabel: actionLabel,
    onAction: onAction,
    replacementGroup: replacementGroup,
    replacementOwner: replacementOwner,
    onDismissed: onDismissed,
    provideHapticFeedback:
        provideHapticFeedback ??
        (!isUndoAction &&
            (tone == AppFeedbackTone.warning ||
                tone == AppFeedbackTone.destructive)),
    showCountdown:
        isUndoAction ||
        (showCountdown ?? (tone == AppFeedbackTone.destructive)),
    showActionCountdown: isUndoAction,
  );
}

VoidCallback showAppProgressFeedback(
  BuildContext context,
  String message, {
  String? title,
  IconData? icon,
}) {
  final owner = Object();
  _showTopFeedback(
    context,
    message,
    tone: AppFeedbackTone.info,
    title: title,
    icon: icon,
    duration: null,
    replacementOwner: owner,
    provideHapticFeedback: false,
  );
  return () {
    if (identical(_queuedFeedback?.replacementOwner, owner)) {
      _queuedFeedback = null;
      return;
    }
    if (identical(_activeFeedbackReplacementOwner, owner)) {
      _activeFeedbackRemove?.call(AppFeedbackDismissReason.replaced);
    }
  };
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
  final fallbackOverlay =
      Overlay.maybeOf(context, rootOverlay: true) ??
      MobileOverlayInset.menuOverlayOf(context) ??
      Overlay.maybeOf(context);
  final staged = await service.stage(action);
  if (!staged) {
    if (context.mounted) {
      showAppSnackBar(
        context,
        failureMessage,
        tone: AppFeedbackTone.destructive,
        icon: Icons.error_outline_rounded,
      );
    } else if (fallbackOverlay != null && fallbackOverlay.mounted) {
      _showTopFeedback(
        fallbackOverlay.context,
        failureMessage,
        tone: AppFeedbackTone.destructive,
        icon: Icons.error_outline_rounded,
        duration: const Duration(seconds: 5),
        provideHapticFeedback: true,
        showCountdown: true,
        explicitOverlay: fallbackOverlay,
      );
    }
    return false;
  }
  if (context.mounted) {
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
  if (fallbackOverlay != null && fallbackOverlay.mounted) {
    _showPendingUndoableRemovalOnOverlay(
      fallbackOverlay.context,
      explicitOverlay: fallbackOverlay,
      service: service,
      message: message,
      batchMessage: batchMessage,
      undoLabel: undoLabel,
      failureMessage: failureMessage,
      icon: icon,
    );
    return true;
  }
  await service.commitPending();
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
  _showPendingUndoableRemovalOnOverlay(
    context,
    service: service,
    message: message,
    batchMessage: batchMessage,
    undoLabel: undoLabel,
    failureMessage: failureMessage,
    icon: icon,
  );
}

void _showPendingUndoableRemovalOnOverlay(
  BuildContext context, {
  OverlayState? explicitOverlay,
  required UndoableRemovalService service,
  required String message,
  required String Function(int count) batchMessage,
  required String undoLabel,
  required String failureMessage,
  IconData icon = Icons.delete_outline_rounded,
}) {
  final count = service.state.pendingCount;
  if (count == 0) return;
  final fallbackOverlay =
      explicitOverlay ??
      Overlay.maybeOf(context, rootOverlay: true) ??
      MobileOverlayInset.menuOverlayOf(context) ??
      Overlay.maybeOf(context);
  void showFailure() {
    if (context.mounted && explicitOverlay == null) {
      showAppSnackBar(
        context,
        failureMessage,
        tone: AppFeedbackTone.destructive,
        icon: Icons.error_outline_rounded,
      );
      return;
    }
    if (fallbackOverlay != null && fallbackOverlay.mounted) {
      _showTopFeedback(
        fallbackOverlay.context,
        failureMessage,
        tone: AppFeedbackTone.destructive,
        icon: Icons.error_outline_rounded,
        duration: const Duration(seconds: 5),
        provideHapticFeedback: true,
        showCountdown: true,
        explicitOverlay: fallbackOverlay,
      );
    }
  }

  final targetOverlay =
      explicitOverlay ??
      MobileOverlayInset.menuOverlayOf(context) ??
      Overlay.of(context);
  final nextMessage = count == 1 ? message : batchMessage(count);
  if (_activeFeedbackReplacementGroup == _undoableRemovalFeedbackGroup &&
      identical(_activeFeedbackReplacementOwner, service) &&
      _activeFeedbackOverlay == targetOverlay &&
      _activeFeedbackUpdateMessage != null) {
    _activeFeedbackUpdateMessage!(nextMessage);
    _activeFeedbackResetDuration?.call(kUndoableRemovalFeedbackDuration, true);
    return;
  }
  _showTopFeedback(
    context,
    nextMessage,
    tone: AppFeedbackTone.destructive,
    icon: icon,
    duration: kUndoableRemovalFeedbackDuration,
    actionLabel: undoLabel,
    onAction: () => unawaited(
      service.undoPending().then((failures) {
        if (failures > 0) showFailure();
      }),
    ),
    replacementGroup: _undoableRemovalFeedbackGroup,
    replacementOwner: service,
    provideHapticFeedback: false,
    showCountdown: true,
    showActionCountdown: true,
    explicitOverlay: targetOverlay,
    onDismissed: (reason) {
      if (reason == AppFeedbackDismissReason.action ||
          reason == AppFeedbackDismissReason.updated) {
        return;
      }
      unawaited(
        service.commitPending().then((failures) {
          if (failures > 0) showFailure();
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
  Widget? iconWidget,
  Color? iconColor,
  required Duration? duration,
  String? actionLabel,
  VoidCallback? onAction,
  Object? replacementGroup,
  Object? replacementOwner,
  ValueChanged<AppFeedbackDismissReason>? onDismissed,
  required bool provideHapticFeedback,
  bool showCountdown = false,
  bool showActionCountdown = false,
  OverlayState? explicitOverlay,
}) {
  final overlay =
      explicitOverlay ??
      MobileOverlayInset.menuOverlayOf(context) ??
      Overlay.of(context);
  final activeUndoService =
      _activeFeedbackReplacementOwner is UndoableRemovalService
      ? _activeFeedbackReplacementOwner as UndoableRemovalService
      : null;
  final undoBannerActive =
      _activeFeedbackEntry != null &&
      _activeFeedbackEntry!.mounted &&
      _activeFeedbackReplacementGroup == _undoableRemovalFeedbackGroup &&
      (activeUndoService == null || activeUndoService.state.pendingCount > 0);
  if (undoBannerActive && replacementGroup != _undoableRemovalFeedbackGroup) {
    final previousQueued = _queuedFeedback;
    _queuedFeedback = _QueuedFeedback(
      overlay: overlay,
      context: context,
      message: message,
      tone: tone,
      title: title,
      icon: icon,
      iconWidget: iconWidget,
      iconColor: iconColor,
      duration: duration,
      actionLabel: actionLabel,
      onAction: onAction,
      replacementGroup: replacementGroup,
      replacementOwner: replacementOwner,
      onDismissed: onDismissed,
      provideHapticFeedback: provideHapticFeedback,
      showCountdown: showCountdown,
      showActionCountdown: showActionCountdown,
    );
    previousQueued?.onDismissed?.call(AppFeedbackDismissReason.replaced);
    return;
  }
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
      iconWidget: iconWidget,
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
    iconWidget: iconWidget,
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
    final wasUndoBanner =
        _activeFeedbackEntry == entry &&
        _activeFeedbackReplacementGroup == _undoableRemovalFeedbackGroup;
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
    if (wasUndoBanner &&
        _activeFeedbackEntry == null &&
        _queuedFeedback != null) {
      final queued = _queuedFeedback!;
      _queuedFeedback = null;
      if (queued.overlay.mounted) {
        final nextContext = queued.context.mounted
            ? queued.context
            : queued.overlay.context;
        _showTopFeedback(
          nextContext,
          queued.message,
          tone: queued.tone,
          title: queued.title,
          icon: queued.icon,
          iconWidget: queued.iconWidget,
          iconColor: queued.iconColor,
          duration: queued.duration,
          actionLabel: queued.actionLabel,
          onAction: queued.onAction,
          replacementGroup: queued.replacementGroup,
          replacementOwner: queued.replacementOwner,
          onDismissed: queued.onDismissed,
          provideHapticFeedback: queued.provideHapticFeedback,
          showCountdown: queued.showCountdown,
          showActionCountdown: queued.showActionCountdown,
          explicitOverlay: queued.overlay,
        );
      } else {
        queued.onDismissed?.call(AppFeedbackDismissReason.replaced);
      }
    }
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
          const headerPadding = AppPageHeaderMetrics.mainTabPadding;
          var headerTop = mediaQuery.padding.top;
          var leftInset = headerPadding.left;
          var rightInset = headerPadding.right;
          if (currentData.context.mounted) {
            RenderBox? targetBox;
            var canvasTopPadding = mediaQuery.padding.top;
            bool findCanvas(Element element) {
              final key = element.widget.key;
              if (key is ValueKey<String> && key.value == 'main_page_canvas') {
                final box = element.findRenderObject();
                if (box is RenderBox && box.hasSize) {
                  targetBox = box;
                  canvasTopPadding =
                      element
                          .getInheritedWidgetOfExactType<MediaQuery>()
                          ?.data
                          .padding
                          .top ??
                      canvasTopPadding;
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
              headerTop = origin.dy + canvasTopPadding;
              leftInset = origin.dx + headerPadding.left;
              rightInset =
                  overlayBox.size.width -
                  origin.dx -
                  box.size.width +
                  headerPadding.right;
            }
          }

          final hasAction =
              currentData.actionLabel != null &&
              currentData.actionLabel!.trim().isNotEmpty &&
              currentData.onAction != null;

          return Positioned(
            top:
                headerTop +
                headerPadding.top +
                AppPageHeaderMetrics.secondRowOffset,
            left: leftInset,
            right: rightInset,
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 500),
                child: _FeedbackAnimationWrapper(
                  key: animationKey,
                  duration: currentData.duration,
                  transitionDuration: MediaQuery.disableAnimationsOf(context)
                      ? Duration.zero
                      : kAppMotionStandard,
                  showCountdown: currentData.showCountdown,
                  onRemove: () =>
                      dismissEntry(AppFeedbackDismissReason.timeout),
                  builder:
                      (
                        remainingSeconds,
                        countdownFraction,
                        appearance,
                        onPauseChanged,
                      ) {
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
                          child: _VerticalSwipeDismissWrapper(
                            onDragActiveChanged: onPauseChanged,
                            onDismissed: () =>
                                dismissEntry(AppFeedbackDismissReason.swipe),
                            child: Material(
                              color: Colors.transparent,
                              child: AppFeedbackSurface(
                                tone: currentData.tone,
                                icon: currentData.icon,
                                iconWidget: currentData.iconWidget,
                                iconColor: currentData.iconColor,
                                title: currentData.title,
                                message: currentData.message,
                                appearance: appearance,
                                countdownFraction: countdownFraction,
                                remainingSeconds: hasAction
                                    ? null
                                    : remainingSeconds,
                                padding: hasAction
                                    ? const EdgeInsets.fromLTRB(10, 1, 10, 1)
                                    : const EdgeInsets.fromLTRB(
                                        10,
                                        AppFeedbackSurface._verticalPadding,
                                        14,
                                        AppFeedbackSurface._verticalPadding,
                                      ),
                                trailing: hasAction
                                    ? TextButton(
                                        key: ValueKey((
                                          currentData.message,
                                          currentData.actionLabel,
                                        )),
                                        style: appTextButtonStyle(
                                          style: TextButton.styleFrom(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 12,
                                            ),
                                            minimumSize: const Size(0, 36),
                                            tapTargetSize:
                                                MaterialTapTargetSize.shrinkWrap,
                                            shape: const StadiumBorder(),
                                          ),
                                        ),
                                        onPressed: () {
                                          if (dismissed ||
                                              !identical(
                                                dataNotifier.value,
                                                currentData,
                                              )) {
                                            return;
                                          }
                                          dismissEntry(
                                            AppFeedbackDismissReason.action,
                                          );
                                          currentData.onAction!();
                                        },
                                        child: Text(
                                          resolvedActionLabel!,
                                          style: const TextStyle(
                                            fontFeatures: [
                                              FontFeature.tabularFigures(),
                                            ],
                                          ),
                                        ),
                                      )
                                    : currentData.duration == null
                                    ? const SizedBox.square(
                                        dimension: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : null,
                              ),
                            ),
                          ),
                        );
                      },
                ),
              ),
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
  _activeFeedbackResetDuration = (duration, showCountdown) =>
      animationKey.currentState?.resetDuration(duration, showCountdown);
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

  final Widget Function(
    int? remainingSeconds,
    double? countdownFraction,
    Animation<double>? appearance,
    ValueChanged<bool> onPauseChanged,
  )
  builder;
  final Duration? duration;
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
  late final Animation<Offset> _slide;
  late final Animation<double> _scale;
  Timer? _expiryTimer;
  Timer? _countdownTimer;
  late int _remainingSeconds;
  int _totalSeconds = 1;
  Duration? _remainingDuration;
  final Stopwatch _activeDurationStopwatch = Stopwatch();
  bool _pausedByDrag = false;
  late bool _currentShowCountdown;
  bool _dismissing = false;
  bool _tickerModeEnabled = true;
  VoidCallback? _onDismissed;

  @override
  void initState() {
    super.initState();
    _currentShowCountdown = widget.showCountdown;
    _controller = AnimationController(
      vsync: this,
      duration: widget.transitionDuration,
    )..addStatusListener(_handleAnimationStatus);
    _opacity = CurvedAnimation(
      parent: _controller,
      curve: kAppSpringCurve,
      reverseCurve: Curves.easeInCubic,
    );
    _slide = Tween<Offset>(
      begin: const Offset(0, -0.26),
      end: Offset.zero,
    ).animate(_opacity);
    _scale = Tween<double>(begin: 0.94, end: 1).animate(_opacity);

    _controller.forward();
    _startDuration(widget.duration, _currentShowCountdown);
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

  void _startDuration(Duration? duration, bool showCountdown) {
    _expiryTimer?.cancel();
    _countdownTimer?.cancel();
    _activeDurationStopwatch
      ..stop()
      ..reset();
    _remainingDuration = duration;
    if (duration == null) return;
    final totalSeconds = (duration.inMilliseconds / 1000).ceil();
    _totalSeconds = totalSeconds > 0 ? totalSeconds : 1;
    _remainingSeconds = _totalSeconds;
    if (!_pausedByDrag) {
      _scheduleActiveTimers(duration, showCountdown);
    }
  }

  void _scheduleActiveTimers(Duration remaining, bool showCountdown) {
    _expiryTimer?.cancel();
    _countdownTimer?.cancel();
    _activeDurationStopwatch
      ..reset()
      ..start();
    if (showCountdown && _totalSeconds > 1) {
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
    _expiryTimer = Timer(remaining, () {
      if (mounted) widget.onRemove();
    });
  }

  void _handlePauseChanged(bool paused) {
    if (_pausedByDrag == paused || _dismissing || _remainingDuration == null) {
      return;
    }
    _pausedByDrag = paused;
    if (paused) {
      _activeDurationStopwatch.stop();
      final elapsed = _activeDurationStopwatch.elapsed;
      final left = _remainingDuration! - elapsed;
      _remainingDuration = left > const Duration(milliseconds: 250)
          ? left
          : const Duration(milliseconds: 250);
      _expiryTimer?.cancel();
      _countdownTimer?.cancel();
    } else {
      _scheduleActiveTimers(_remainingDuration!, _currentShowCountdown);
    }
  }

  void resetDuration(Duration? duration, bool showCountdown) {
    if (!mounted) return;
    _currentShowCountdown = showCountdown;
    _startDuration(duration, showCountdown);
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
    final appearance = MediaQuery.disableAnimationsOf(context)
        ? null
        : _opacity;
    final countdownFraction = _currentShowCountdown && _totalSeconds > 0
        ? (_remainingSeconds / _totalSeconds).clamp(0.0, 1.0)
        : null;
    final content = widget.builder(
      _currentShowCountdown ? _remainingSeconds : null,
      countdownFraction,
      appearance,
      _handlePauseChanged,
    );
    return IgnorePointer(
      ignoring: _dismissing,
      child: ExcludeFocus(
        excluding: _dismissing,
        child: ExcludeSemantics(
          excluding: _dismissing,
          child: appearance == null
              ? content
              : SlideTransition(
                  position: _slide,
                  child: ScaleTransition(scale: _scale, child: content),
                ),
        ),
      ),
    );
  }
}

class _VerticalSwipeDismissWrapper extends StatefulWidget {
  const _VerticalSwipeDismissWrapper({
    required this.onDismissed,
    this.onDragActiveChanged,
    required this.child,
  });

  final VoidCallback onDismissed;
  final ValueChanged<bool>? onDragActiveChanged;
  final Widget child;

  @override
  State<_VerticalSwipeDismissWrapper> createState() =>
      _VerticalSwipeDismissWrapperState();
}

class _VerticalSwipeDismissWrapperState
    extends State<_VerticalSwipeDismissWrapper>
    with SingleTickerProviderStateMixin {
  late final AnimationController _resetController;
  Animation<double>? _resetAnimation;
  final ValueNotifier<double> _offsetY = ValueNotifier<double>(0);
  late final Animation<double> _dragOpacity = Animation<double>.fromValueListenable(
    _offsetY,
    transformer: (value) => (1.0 + value / 100.0).clamp(0.0, 1.0),
  );
  bool _isOffsetActive = false;

  @override
  void initState() {
    super.initState();
    _resetController =
        AnimationController(vsync: this, duration: kAppMotionFast)
          ..addListener(() {
            final animation = _resetAnimation;
            if (animation != null && mounted) {
              _setOffset(animation.value);
            }
          });
  }

  void _setOffset(double next) {
    if (_offsetY.value == next) return;
    _offsetY.value = next;
    final active = next != 0;
    if (active != _isOffsetActive && mounted) {
      setState(() => _isOffsetActive = active);
    }
  }

  @override
  void dispose() {
    _resetController.dispose();
    _offsetY.dispose();
    super.dispose();
  }

  void _handleDragStart(DragStartDetails _) {
    widget.onDragActiveChanged?.call(true);
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    _resetController.stop();
    widget.onDragActiveChanged?.call(true);
    final next = (_offsetY.value + details.delta.dy).clamp(-120.0, 0.0);
    _setOffset(next);
  }

  void _handleDragEnd(DragEndDetails details) {
    widget.onDragActiveChanged?.call(false);
    final velocity = details.velocity.pixelsPerSecond.dy;
    final currentOffset = _offsetY.value;
    if (currentOffset <= -28 || (currentOffset < 0 && velocity <= -350)) {
      widget.onDismissed();
      return;
    }
    if (currentOffset == 0) return;
    if (MediaQuery.disableAnimationsOf(context) ||
        !TickerMode.valuesOf(context).enabled) {
      _setOffset(0);
      return;
    }
    _resetAnimation = Tween<double>(
      begin: currentOffset,
      end: 0,
    ).chain(CurveTween(curve: kAppSpringCurve)).animate(_resetController);
    _resetController.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final child = !_isOffsetActive
        ? widget.child
        : FadeTransition(
            opacity: _dragOpacity,
            child: ValueListenableBuilder<double>(
              valueListenable: _offsetY,
              child: widget.child,
              builder: (context, offsetY, innerChild) => Transform.translate(
                offset: Offset(0, offsetY),
                child: innerChild,
              ),
            ),
          );
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragStart: _handleDragStart,
      onVerticalDragUpdate: _handleDragUpdate,
      onVerticalDragEnd: _handleDragEnd,
      onVerticalDragCancel: () =>
          _handleDragEnd(DragEndDetails()),
      child: child,
    );
  }
}

class AppFeedbackSurface extends StatelessWidget {
  const AppFeedbackSurface({
    super.key,
    required this.tone,
    required this.icon,
    this.iconWidget,
    required this.message,
    this.remainingSeconds,
    this.countdownFraction,
    this.appearance,
    this.title,
    this.trailing,
    this.padding = const EdgeInsets.fromLTRB(
      10,
      _verticalPadding,
      14,
      _verticalPadding,
    ),
    this.borderRadius,
    this.iconColor,
  });

  static const double _iconChipSize = 24;
  static const double _verticalPadding =
      (AppPageHeaderMetrics.contentHeight - _iconChipSize) / 2;

  final AppFeedbackTone tone;
  final IconData icon;
  final Widget? iconWidget;
  final String message;
  final int? remainingSeconds;
  final double? countdownFraction;
  final Animation<double>? appearance;
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

    final iconChip = AnimatedContainer(
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : tokens.motionFast,
      curve: Curves.easeOutCubic,
      width: _iconChipSize,
      height: _iconChipSize,
      decoration: BoxDecoration(color: chipBackground, shape: BoxShape.circle),
      child: Center(
        child: AnimatedSwitcher(
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : tokens.motionFast,
          switchInCurve: kAppSpringCurve,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, animation) =>
              MediaQuery.disableAnimationsOf(context)
              ? child
              : FadeTransition(
                  opacity: animation,
                  child: ScaleTransition(
                    scale: animation.drive(Tween<double>(begin: 0.85, end: 1)),
                    child: child,
                  ),
                ),
          child: iconWidget != null
              ? IconTheme.merge(
                  key: const ValueKey<String>('feedback_custom_icon'),
                  data: IconThemeData(size: 16, color: accent),
                  child: iconWidget!,
                )
              : Icon(
                  icon,
                  key: ValueKey<IconData>(icon),
                  size: AppDesignTokens.opticalIconSize(icon, 16),
                  color: accent,
                ),
        ),
      ),
    );
    final Widget leadingIcon = countdownFraction == null
        ? iconChip
        : TweenAnimationBuilder<double>(
            tween: Tween<double>(
              begin: countdownFraction,
              end: countdownFraction,
            ),
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            child: iconChip,
            builder: (context, fraction, child) => CustomPaint(
              foregroundPainter: _FeedbackCountdownRingPainter(
                fraction: fraction,
                color: accent,
              ),
              child: child,
            ),
          );

    final surface = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(resolvedBorderRadius),
        border: Border.all(
          color: appOverlayBorderColor(cs, tokens, elevated: true),
        ),
      ),
      child: Padding(
        padding: padding,
        child: Row(
          children: [
            leadingIcon,
            const SizedBox(width: 10),
            Expanded(
              child: Padding(
                padding: EdgeInsets.symmetric(
                  vertical: math.max(
                    0.0,
                    _verticalPadding - padding.vertical / 2,
                  ),
                ),
                child: AnimatedSize(
                  duration: MediaQuery.disableAnimationsOf(context)
                      ? Duration.zero
                      : tokens.motionFast,
                  curve: kAppSpringCurve,
                  alignment: Alignment.centerLeft,
                  child: AnimatedSwitcher(
                    duration: MediaQuery.disableAnimationsOf(context)
                        ? Duration.zero
                        : tokens.motionFast,
                    switchInCurve: kAppSpringCurve,
                    switchOutCurve: Curves.easeInCubic,
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
                                    fontFeatures: const [
                                      FontFeature.tabularFigures(),
                                    ],
                                  ),
                        ),
                      ],
                    ),
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

    Widget buildSurface(double opacity, Widget foreground) => DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(resolvedBorderRadius),
        boxShadow: [
          BoxShadow(
            color: cs.shadow.withValues(alpha: 0.14 * opacity),
            blurRadius: 18,
            spreadRadius: -5,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: AppGlassSurface(
        enabled: tokens.barGlassEnabled,
        backgroundColor: surfaceColor.withValues(
          alpha: surfaceColor.a * opacity,
        ),
        borderRadius: BorderRadius.circular(resolvedBorderRadius),
        blurProgress: opacity,
        child: foreground,
      ),
    );

    final animation = appearance;
    final Widget result;
    if (animation == null) {
      result = buildSurface(1, surface);
    } else if (!tokens.barGlassEnabled) {
      result = FadeTransition(
        opacity: animation,
        child: buildSurface(1, surface),
      );
    } else {
      // A fade around the backdrop can isolate it from the page behind it.
      result = AnimatedBuilder(
        animation: animation,
        child: FadeTransition(opacity: animation, child: surface),
        builder: (_, child) => buildSurface(animation.value, child!),
      );
    }
    return Semantics(liveRegion: true, child: result);
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

class _FeedbackCountdownRingPainter extends CustomPainter {
  const _FeedbackCountdownRingPainter({
    required this.fraction,
    required this.color,
  });

  final double fraction;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final sweep = (fraction.clamp(0.0, 1.0)) * 2 * math.pi;
    if (sweep <= 0) return;
    const strokeWidth = 1.6;
    final rect = (Offset.zero & size).deflate(strokeWidth / 2);
    final trackPaint = Paint()
      ..color = color.withValues(alpha: 0.16)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..isAntiAlias = true;
    final arcPaint = Paint()
      ..color = color.withValues(alpha: 0.78)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;
    canvas.drawOval(rect, trackPaint);
    canvas.drawArc(rect, -math.pi / 2, sweep, false, arcPaint);
  }

  @override
  bool shouldRepaint(covariant _FeedbackCountdownRingPainter oldDelegate) {
    return oldDelegate.fraction != fraction || oldDelegate.color != color;
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
