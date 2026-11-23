import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../ui/ui_interaction_coordinator.dart';
import 'app_feedback.dart';
import 'app_transitions.dart';
import 'swipe_reveal_action_pane.dart';
import 'unified_popup_menu.dart';

export 'push_pin_off_icon.dart' show PushPinOffIcon, PushPinOffPainter;

/// Card shell whose action pane is revealed by a horizontal swipe.
///
/// The closed background is opaque, so a tappable child must host its own ink
/// surface (a `Card`/`Material`) inside this shell. An `InkWell` wrapped around
/// the shell paints its highlight and ripple below the closed background, which
/// makes presses invisible.
class SwipeRevealCard extends StatefulWidget {
  const SwipeRevealCard({
    super.key,
    required this.child,
    required this.onRemove,
    required this.actionLabel,
    required this.removeTooltip,
    required this.shape,
    this.margin = EdgeInsets.zero,
    this.onWillReveal,
    this.onSecondaryAction,
    this.secondaryActionLabel,
    this.secondaryActionTooltip,
    this.secondaryActionIcon = Icons.info_outline_rounded,
    this.secondaryActionIconWidget,
    this.primaryActionIcon = Icons.delete_outline_rounded,
    this.primaryActionIconWidget,
    this.primaryActionTooltip,
    this.onTertiaryAction,
    this.tertiaryActionLabel,
    this.tertiaryActionTooltip,
    this.tertiaryActionIcon = Icons.download_rounded,
    this.destructive = true,
    this.verticalActions = false,
    this.swipeEnabled = true,
    this.leadingSwipeEnabled = true,
    this.enabled = true,
    this.onSelectMultiple,
    this.selectMultipleLabel,
    this.color,
    this.closedColor,
    this.onLeadingAction,
    this.animateLeadingActionClose = false,
    this.leadingActionLabel,
    this.leadingActionTooltip,
    this.leadingActionIcon = Icons.download_rounded,
    this.leadingActionIconWidget,
    this.onSecondaryLeadingAction,
    this.secondaryLeadingActionLabel,
    this.secondaryLeadingActionTooltip,
    this.secondaryLeadingActionIcon = Icons.download_rounded,
    this.secondaryLeadingActionIconWidget,
  }) : assert(onSelectMultiple == null || selectMultipleLabel != null);

  final Widget child;
  final FutureOr<void> Function() onRemove;
  final String actionLabel;
  final String removeTooltip;
  final ShapeBorder shape;
  final EdgeInsets margin;
  final VoidCallback? onWillReveal;
  final VoidCallback? onSecondaryAction;
  final String? secondaryActionLabel;
  final String? secondaryActionTooltip;
  final IconData secondaryActionIcon;
  final Widget? secondaryActionIconWidget;
  final IconData primaryActionIcon;
  final Widget? primaryActionIconWidget;
  final String? primaryActionTooltip;
  final VoidCallback? onTertiaryAction;
  final String? tertiaryActionLabel;
  final String? tertiaryActionTooltip;
  final IconData tertiaryActionIcon;
  final bool destructive;
  final bool verticalActions;

  /// Leaves the desktop context menu available when swipe actions are absent.
  final bool swipeEnabled;

  /// Leading actions can remain in the context menu without a swipe entry.
  final bool leadingSwipeEnabled;
  final bool enabled;
  final VoidCallback? onSelectMultiple;
  final String? selectMultipleLabel;
  final Color? color;
  final Color? closedColor;
  final VoidCallback? onLeadingAction;
  final bool animateLeadingActionClose;
  final String? leadingActionLabel;
  final String? leadingActionTooltip;
  final IconData leadingActionIcon;
  final Widget? leadingActionIconWidget;
  final VoidCallback? onSecondaryLeadingAction;
  final String? secondaryLeadingActionLabel;
  final String? secondaryLeadingActionTooltip;
  final IconData secondaryLeadingActionIcon;
  final Widget? secondaryLeadingActionIconWidget;

  @override
  State<SwipeRevealCard> createState() => _SwipeRevealCardState();
}

class _SwipeRevealCardState extends State<SwipeRevealCard>
    with SingleTickerProviderStateMixin {
  static const double _revealStartThreshold = 4;
  static const double _verticalRejectThreshold = 8;
  static const double _acceptSlopeRatio = 2.2;
  static const double _rejectSlopeRatio = 1.35;
  static const double _minOpenVelocity = 560;
  static const double _minOpenDistance = 44;
  static final SpringDescription _settleSpring =
      SpringDescription.withDampingRatio(mass: 1.0, stiffness: 520.0);

  AnimationController? _controller;
  double _dragStartRevealedWidth = 0;
  double _dragDx = 0;
  double _dragDy = 0;
  bool _dragAccepted = false;
  bool _dragRejected = false;
  bool _actionPaneActive = false;
  bool _isOpen = false;
  bool _tickerModeEnabled = true;
  ValueListenable<TickerModeData>? _tickerModeNotifier;
  bool _revealedFromStart = false;
  bool _dragStartFromStart = false;
  bool _overscrollHapticFired = false;
  int _settleGeneration = 0;
  VoidCallback? _actionAfterClose;
  late final _contentKey = GlobalKey();
  final Object _interactionSource = Object();

  AnimationController _ensureController() => _controller ??=
      AnimationController(vsync: this, duration: kAppMotionStandard);

  double get _currentProgress => _controller?.value ?? 0.0;
  double get _currentWidth => _currentProgress * _activeActionWidth;

  void _beginMotion() {
    UiInteractionCoordinator.instance.beginInteraction(_interactionSource);
  }

  void _finishMotion() {
    UiInteractionCoordinator.instance.endInteraction(_interactionSource);
  }

  @override
  void dispose() {
    _settleGeneration++;
    _tickerModeNotifier?.removeListener(_handleTickerModeChanged);
    UiInteractionCoordinator.instance.cancelInteraction(_interactionSource);
    _controller?.dispose();
    super.dispose();
  }

  bool get _hasSecondaryAction => widget.onSecondaryAction != null;
  bool get _hasTertiaryAction => widget.onTertiaryAction != null;
  bool get _hasLeadingAction => widget.onLeadingAction != null;
  bool get _hasSecondaryLeadingAction =>
      widget.onSecondaryLeadingAction != null;
  int get _actionCount =>
      1 + (_hasSecondaryAction ? 1 : 0) + (_hasTertiaryAction ? 1 : 0);
  int get _leadingActionCount =>
      (_hasLeadingAction ? 1 : 0) + (_hasSecondaryLeadingAction ? 1 : 0);
  double get _actionWidth => widget.verticalActions && _actionCount > 1
      ? 76
      : _actionCount * 72.0;
  double get _leadingActionWidth =>
      widget.verticalActions && _leadingActionCount > 1
      ? 76
      : _leadingActionCount > 1
      ? 144
      : 72;
  double get _activeActionWidth =>
      _revealedFromStart ? _leadingActionWidth : _actionWidth;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (defaultTargetPlatform == TargetPlatform.windows) {
      _tickerModeNotifier?.removeListener(_handleTickerModeChanged);
      _tickerModeNotifier = null;
      return;
    }
    final notifier = TickerMode.getValuesNotifier(context);
    if (!identical(notifier, _tickerModeNotifier)) {
      _tickerModeNotifier?.removeListener(_handleTickerModeChanged);
      _tickerModeNotifier = notifier;
      notifier.addListener(_handleTickerModeChanged);
    }
    _handleTickerModeChanged();
  }

  void _handleTickerModeChanged() {
    final enabled = _tickerModeNotifier!.value.enabled;
    // A modal action can cover this route while retaining the revealed card.
    if (_tickerModeEnabled && !enabled) {
      final needsRebuild =
          _currentProgress != 0 || _actionPaneActive || _isOpen;
      _resetPaneState();
      if (needsRebuild) setState(() {});
    }
    _tickerModeEnabled = enabled;
  }

  @override
  void didUpdateWidget(covariant SwipeRevealCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((!widget.enabled && oldWidget.enabled) ||
        (!widget.swipeEnabled && oldWidget.swipeEnabled)) {
      _resetPaneState();
    }
    if (oldWidget.key != widget.key &&
        (_currentProgress != 0 || _actionPaneActive)) {
      _resetPaneState();
    }
  }

  void _resetPaneState() {
    _settleGeneration++;
    _actionAfterClose = null;
    UiInteractionCoordinator.instance.cancelInteraction(_interactionSource);
    _controller?.stop();
    if (_controller != null) _controller!.value = 0;
    _dragStartRevealedWidth = 0;
    _dragDx = 0;
    _dragDy = 0;
    _dragAccepted = false;
    _dragRejected = false;
    _actionPaneActive = false;
    _isOpen = false;
    _revealedFromStart = false;
    _dragStartFromStart = false;
    _overscrollHapticFired = false;
  }

  void _settleTo(
    double target, {
    double? velocity,
    bool immediate = false,
  }) {
    final controller = _ensureController();
    final generation = ++_settleGeneration;
    final reducedMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final nextOpen = target > 0.5;
    if (nextOpen && !_actionPaneActive) {
      setState(() {
        _actionPaneActive = true;
        _isOpen = nextOpen;
      });
    } else if (_isOpen != nextOpen) {
      setState(() => _isOpen = nextOpen);
    }

    if (immediate || reducedMotion) {
      controller.stop();
      controller.value = target;
      _completeSettle(target, immediate: immediate);
      return;
    }

    final atTarget =
        (controller.value - target).abs() < 1e-4 &&
        (velocity == null || (target == 0 ? velocity <= 0 : velocity >= 0));
    if (atTarget) {
      controller.stop();
      controller.value = target;
      _completeSettle(target, immediate: false);
      return;
    }

    final TickerFuture future;
    if (velocity != null) {
      future = controller.animateWith(
        SpringSimulation(
          _settleSpring,
          controller.value,
          target,
          velocity,
          tolerance: const Tolerance(velocity: 0.01),
        ),
      );
    } else {
      future = controller.animateTo(
        target,
        duration: kAppMotionStandard,
        curve: kAppSpringCurve,
      );
    }
    unawaited(
      future.then<void>(
        (_) {
          if (!mounted || generation != _settleGeneration) return;
          controller.value = target;
          _completeSettle(target, immediate: false);
        },
        onError: (_) {},
      ),
    );
  }

  void _completeSettle(double target, {required bool immediate}) {
    if (!mounted) return;
    if (!_dragAccepted) {
      if (immediate) {
        UiInteractionCoordinator.instance.cancelInteraction(_interactionSource);
      } else {
        _finishMotion();
      }
    }
    if (target == 0 && !_dragAccepted) {
      if (_actionPaneActive || _isOpen || _revealedFromStart) {
        setState(() {
          _actionPaneActive = false;
          _isOpen = false;
          _revealedFromStart = false;
        });
      }
      if (!immediate && _actionAfterClose != null) {
        _runClosedAction();
      }
    }
  }

  void _closePane({bool immediate = false}) {
    if (_currentProgress == 0 && !_actionPaneActive && !_isOpen) {
      if (immediate) {
        UiInteractionCoordinator.instance.cancelInteraction(_interactionSource);
      }
      return;
    }
    if (immediate) {
      UiInteractionCoordinator.instance.cancelInteraction(_interactionSource);
    } else {
      _beginMotion();
    }
    _settleTo(0.0, immediate: immediate);
  }

  void _runActionAfterPaneClose(VoidCallback? action) {
    if (action == null || _actionAfterClose != null) return;
    _actionAfterClose = action;
    if (!widget.animateLeadingActionClose ||
        action != widget.onLeadingAction ||
        _currentProgress == 0) {
      _closePane(immediate: true);
      _runClosedAction();
    } else {
      _closePane();
    }
  }

  void _runClosedAction() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final action = _actionAfterClose;
      _actionAfterClose = null;
      action?.call();
    });
  }

  List<UnifiedMenuEntry<VoidCallback>> _buildContextMenuEntries() {
    widget.onWillReveal?.call();
    return [
      if (_hasLeadingAction)
        UnifiedMenuEntry.action(
          value: widget.onLeadingAction!,
          label: widget.leadingActionLabel ?? widget.leadingActionTooltip ?? '',
          icon: widget.leadingActionIcon,
          iconWidget: widget.leadingActionIconWidget,
        ),
      if (_hasSecondaryLeadingAction)
        UnifiedMenuEntry.action(
          value: widget.onSecondaryLeadingAction!,
          label:
              widget.secondaryLeadingActionLabel ??
              widget.secondaryLeadingActionTooltip ??
              '',
          icon: widget.secondaryLeadingActionIcon,
          iconWidget: widget.secondaryLeadingActionIconWidget,
        ),
      if (_hasTertiaryAction)
        UnifiedMenuEntry.action(
          value: widget.onTertiaryAction!,
          label:
              widget.tertiaryActionLabel ?? widget.tertiaryActionTooltip ?? '',
          icon: widget.tertiaryActionIcon,
        ),
      if (_hasSecondaryAction)
        UnifiedMenuEntry.action(
          value: widget.onSecondaryAction!,
          label:
              widget.secondaryActionLabel ??
              widget.secondaryActionTooltip ??
              '',
          icon: widget.secondaryActionIcon,
          iconWidget: widget.secondaryActionIconWidget,
        ),
      if (widget.onSelectMultiple != null)
        UnifiedMenuEntry.action(
          value: widget.onSelectMultiple!,
          label: widget.selectMultipleLabel!,
          icon: Icons.checklist_rounded,
        ),
      UnifiedMenuEntry.action(
        value: widget.onRemove,
        label: widget.actionLabel,
        icon: widget.primaryActionIcon,
        iconWidget: widget.primaryActionIconWidget,
        destructive: widget.destructive,
      ),
    ];
  }

  void _handleHorizontalDragStart(DragStartDetails details) {
    if (!widget.enabled || !_tickerModeEnabled || _actionAfterClose != null) {
      return;
    }
    _settleGeneration++;
    _controller?.stop();
    // The controller value always reflects the exact live painted position.
    _dragStartRevealedWidth = _currentWidth;
    _dragStartFromStart = _revealedFromStart;
    _overscrollHapticFired = false;
    _dragDx = 0;
    _dragDy = 0;
    _dragAccepted = _currentProgress > 0;
    _dragRejected = false;
    if (_dragAccepted) _beginMotion();
  }

  void _handleHorizontalDragUpdate(DragUpdateDetails details) {
    if (!widget.enabled || !_tickerModeEnabled || _actionAfterClose != null) {
      return;
    }
    _dragDx += details.delta.dx;
    _dragDy += details.delta.dy;

    if (_dragRejected) {
      return;
    }

    final horizontalDistance = _dragDx.abs();
    final verticalDistance = _dragDy.abs();

    if (!_dragAccepted) {
      if (verticalDistance > _verticalRejectThreshold &&
          verticalDistance >= horizontalDistance * _rejectSlopeRatio) {
        _dragRejected = true;
        return;
      }
      final isIntentionalSwipe =
          ((_dragDx < 0 && _actionCount > 0) ||
              (_dragDx > 0 &&
                  widget.leadingSwipeEnabled &&
                  _leadingActionCount > 0)) &&
          horizontalDistance >= _revealStartThreshold &&
          horizontalDistance > verticalDistance * _acceptSlopeRatio;
      if (!isIntentionalSwipe) {
        return;
      }
      _revealedFromStart = _dragDx > 0;
      _dragStartFromStart = _revealedFromStart;
      _dragAccepted = true;
      _settleGeneration++;
      _ensureController().stop();
      _beginMotion();
      AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection);
      widget.onWillReveal?.call();
      if (!_actionPaneActive) {
        setState(() => _actionPaneActive = true);
      }
    }

    // Post-acceptance: if the gesture veers too vertical, revoke acceptance.
    if (_dragAccepted &&
        _dragStartRevealedWidth == 0 &&
        verticalDistance > horizontalDistance * _rejectSlopeRatio) {
      _dragAccepted = false;
      _dragRejected = true;
      _closePane();
      return;
    }

    if (_dragStartRevealedWidth > 0 && verticalDistance > 18) {
      _dragAccepted = false;
      _dragRejected = true;
      _closePane();
      return;
    }

    final actionWidth = _activeActionWidth;
    final nextWidth =
        (_dragStartRevealedWidth + (_dragStartFromStart ? _dragDx : -_dragDx))
            .clamp(0.0, actionWidth);
    if (!_overscrollHapticFired &&
        _dragStartRevealedWidth < _minOpenDistance &&
        nextWidth >= _minOpenDistance) {
      _overscrollHapticFired = true;
      AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection);
    } else if (nextWidth < _minOpenDistance * 0.85) {
      _overscrollHapticFired = false;
    }
    final nextProgress = actionWidth > 0
        ? (nextWidth / actionWidth).clamp(0.0, 1.0)
        : 0.0;
    final controller = _ensureController();
    if (controller.value != nextProgress) {
      controller.value = nextProgress;
    }
  }

  void _handleHorizontalDragEnd(DragEndDetails details) {
    if (_dragRejected || !_dragAccepted) {
      _dragAccepted = false;
      _dragRejected = false;
      if (_dragStartRevealedWidth == 0 && _currentProgress != 0) {
        _closePane();
      } else if (!(_controller?.isAnimating ?? false)) {
        _finishMotion();
      }
      return;
    }
    final velocity = details.primaryVelocity ?? 0;
    final currentWidth = _currentWidth;
    final distanceMet = currentWidth >= _minOpenDistance;
    final velocityMet = _revealedFromStart
        ? velocity >= _minOpenVelocity
        : velocity <= -_minOpenVelocity;
    final closingVelocityMet = _revealedFromStart
        ? velocity <= -_minOpenVelocity
        : velocity >= _minOpenVelocity;
    final fullyRevealed = currentWidth >= _activeActionWidth * 0.88;
    final shouldOpen =
        !closingVelocityMet &&
        ((distanceMet && velocityMet) || fullyRevealed);
    _dragAccepted = false;
    _dragRejected = false;
    final signedVelocity = _revealedFromStart ? velocity : -velocity;
    final normalizedVelocity = _activeActionWidth > 0
        ? (signedVelocity / _activeActionWidth).clamp(-10.0, 10.0)
        : 0.0;
    _settleTo(shouldOpen ? 1.0 : 0.0, velocity: normalizedVelocity);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Widget buildClosedContent(Widget child, {required bool clip}) {
      final surfaceColor = widget.closedColor ?? cs.surface;
      if (!clip) {
        if (widget.shape.runtimeType == RoundedRectangleBorder) {
          final roundedShape = widget.shape as RoundedRectangleBorder;
          if (roundedShape.borderRadius == BorderRadius.zero) {
            return ColoredBox(color: surfaceColor, child: child);
          }
          // Paint the rounded surface without creating a GPU ClipRRect layer
          // while the card is at rest; clip only when actively swiping/revealed.
          return DecoratedBox(
            decoration: BoxDecoration(
              color: surfaceColor,
              borderRadius: roundedShape.borderRadius,
            ),
            child: child,
          );
        }
        return ClipPath(
          clipBehavior: Clip.hardEdge,
          clipper: ShapeBorderClipper(shape: widget.shape),
          child: ColoredBox(color: surfaceColor, child: child),
        );
      }
      final content = ColoredBox(color: surfaceColor, child: child);

      if (widget.shape.runtimeType == RoundedRectangleBorder) {
        final roundedShape = widget.shape as RoundedRectangleBorder;
        return ClipRRect(
          borderRadius: roundedShape.borderRadius.resolve(
            Directionality.of(context),
          ),
          child: content,
        );
      }
      return ClipPath(
        clipBehavior: Clip.hardEdge,
        clipper: ShapeBorderClipper(shape: widget.shape),
        child: content,
      );
    }

    if (defaultTargetPlatform == TargetPlatform.windows) {
      return Padding(
        padding: widget.margin,
        child: UnifiedContextMenuRegion(
          buildEntries: _buildContextMenuEntries,
          shape: widget.shape,
          enabled: widget.enabled,
          skipTraversal: true,
          child: buildClosedContent(widget.child, clip: false),
        ),
      );
    }
    final keyedChild = KeyedSubtree(key: _contentKey, child: widget.child);
    if (!widget.swipeEnabled || !widget.enabled) {
      return Padding(
        padding: widget.margin,
        child: buildClosedContent(keyedChild, clip: false),
      );
    }
    final actionWidth = _activeActionWidth;
    final controller = _controller;
    // Lists own per-card repaint isolation. Adding it here duplicates the
    // same full-card layer for every visible library and playlist entry.
    final paneActive = _actionPaneActive || _currentProgress > 0;
    // Preserve child animations when the swipe transform and clip layer are
    // added on swipe start and removed on close.
    final closedContent = buildClosedContent(keyedChild, clip: paneActive);
    return TapRegion(
      enabled: paneActive,
      onTapOutside: paneActive ? (_) => _closePane() : null,
      child: Padding(
        padding: widget.margin,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragStart: _handleHorizontalDragStart,
          onHorizontalDragUpdate: _handleHorizontalDragUpdate,
          onHorizontalDragEnd: _handleHorizontalDragEnd,
          onSecondaryTap: () {
            if (_actionAfterClose != null) return;
            _beginMotion();
            final opening = !_isOpen;
            if (_currentProgress == 0) _revealedFromStart = false;
            _settleTo(opening ? 1.0 : 0.0);
          },
          onHorizontalDragCancel: () {
            // An action tap also cancels the competing drag recognizer.
            final wasAccepted = _dragAccepted;
            _dragAccepted = false;
            _dragRejected = false;
            if (wasAccepted) {
              _closePane();
            } else if (!(_controller?.isAnimating ?? false)) {
              _finishMotion();
            }
          },
          child: Stack(
            children: [
              if (paneActive && controller != null)
                Positioned.fill(
                  child: ClipRect(
                    clipper: _SwipeRevealPaneClipper(
                      fromStart: _revealedFromStart,
                      actionWidth: actionWidth,
                    ),
                    child: SwipeRevealActionPane(
                      actions: _revealedFromStart
                          ? _buildLeadingActions()
                          : _buildTrailingActions(),
                      fromStart: _revealedFromStart,
                      vertical: widget.verticalActions,
                      width: actionWidth,
                      progress: controller.value,
                      progressAnimation: controller,
                      shape: widget.shape,
                      color: widget.color,
                      label: _buildActionLabel(),
                      tooltip: _buildActionTooltip(),
                      dragging: _dragAccepted,
                      onAction: _runActionAfterPaneClose,
                    ),
                  ),
                ),
              if (!paneActive || controller == null)
                closedContent
              else
                AnimatedBuilder(
                  animation: controller,
                  child: IgnorePointer(ignoring: _isOpen, child: closedContent),
                  builder: (context, child) {
                    final offsetWidth = (controller.value * actionWidth).clamp(
                      0.0,
                      actionWidth,
                    );
                    return Transform.translate(
                      offset: Offset(
                        _revealedFromStart ? offsetWidth : -offsetWidth,
                        0,
                      ),
                      child: child,
                    );
                  },
                ),
              if (_isOpen)
                Positioned.fill(
                  right: _revealedFromStart ? 0 : actionWidth,
                  left: _revealedFromStart ? actionWidth : 0,
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: _closePane,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _buildActionLabel() => _hasTertiaryAction
      ? [
          widget.tertiaryActionLabel ?? '',
          widget.secondaryActionLabel ?? '',
          widget.actionLabel,
        ].where((item) => item.trim().isNotEmpty).join(' / ')
      : _hasSecondaryAction
      ? '${widget.secondaryActionLabel ?? ''} / ${widget.actionLabel}'
      : widget.actionLabel;

  String _buildActionTooltip() => _hasTertiaryAction
      ? widget.tertiaryActionTooltip ?? widget.removeTooltip
      : _hasSecondaryAction
      ? widget.secondaryActionTooltip ?? widget.removeTooltip
      : widget.removeTooltip;

  List<SwipeRevealAction> _buildLeadingActions() => <SwipeRevealAction>[
    if (_hasLeadingAction)
      SwipeRevealAction(
        icon: widget.leadingActionIcon,
        iconWidget: widget.leadingActionIconWidget,
        tooltip: widget.leadingActionTooltip ?? widget.leadingActionLabel,
        onPressed: widget.onLeadingAction!,
        primary: true,
        feedback: AppInteractionFeedbackType.confirmation,
      ),
    if (_hasSecondaryLeadingAction)
      SwipeRevealAction(
        icon: widget.secondaryLeadingActionIcon,
        iconWidget: widget.secondaryLeadingActionIconWidget,
        tooltip:
            widget.secondaryLeadingActionTooltip ??
            widget.secondaryLeadingActionLabel,
        onPressed: widget.onSecondaryLeadingAction!,
        primary: true,
        feedback: AppInteractionFeedbackType.confirmation,
      ),
  ];

  List<SwipeRevealAction> _buildTrailingActions() => <SwipeRevealAction>[
    if (_hasTertiaryAction)
      SwipeRevealAction(
        icon: widget.tertiaryActionIcon,
        tooltip: widget.tertiaryActionTooltip ?? widget.tertiaryActionLabel,
        onPressed: widget.onTertiaryAction!,
      ),
    if (_hasSecondaryAction)
      SwipeRevealAction(
        icon: widget.secondaryActionIcon,
        iconWidget: widget.secondaryActionIconWidget,
        tooltip: widget.secondaryActionTooltip ?? widget.secondaryActionLabel,
        onPressed: widget.onSecondaryAction!,
      ),
    SwipeRevealAction(
      icon: widget.primaryActionIcon,
      iconWidget: widget.primaryActionIconWidget,
      tooltip: widget.primaryActionTooltip ?? widget.removeTooltip,
      onPressed: widget.onRemove,
      primary: true,
      destructive: widget.destructive,
      feedback: widget.destructive
          ? AppInteractionFeedbackType.destructive
          : AppInteractionFeedbackType.confirmation,
    ),
  ];
}

class _SwipeRevealPaneClipper extends CustomClipper<Rect> {
  const _SwipeRevealPaneClipper({
    required this.fromStart,
    required this.actionWidth,
  });

  final bool fromStart;
  final double actionWidth;

  @override
  Rect getClip(Size size) {
    // Keep the opposite antialiased edge hidden as the foreground returns to
    // zero, while leaving room for its rounded end beyond the action buttons.
    final inset = (size.width - actionWidth).clamp(0.0, size.width) / 2;
    return Rect.fromLTRB(
      fromStart ? 0 : inset,
      0,
      fromStart ? size.width - inset : size.width,
      size.height,
    );
  }

  @override
  bool shouldReclip(_SwipeRevealPaneClipper oldClipper) =>
      fromStart != oldClipper.fromStart ||
      actionWidth != oldClipper.actionWidth;
}
