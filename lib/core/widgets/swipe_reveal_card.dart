import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_feedback.dart';
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
    this.primaryActionTooltip,
    this.onTertiaryAction,
    this.tertiaryActionLabel,
    this.tertiaryActionTooltip,
    this.tertiaryActionIcon = Icons.download_rounded,
    this.destructive = true,
    this.verticalActions = false,
    this.enabled = true,
    this.color,
    this.closedColor,
    this.onLeadingAction,
    this.leadingActionLabel,
    this.leadingActionTooltip,
    this.leadingActionIcon = Icons.download_rounded,
    this.leadingActionIconWidget,
    this.onSecondaryLeadingAction,
    this.secondaryLeadingActionLabel,
    this.secondaryLeadingActionTooltip,
    this.secondaryLeadingActionIcon = Icons.download_rounded,
    this.secondaryLeadingActionIconWidget,
  });

  final Widget child;
  final VoidCallback onRemove;
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
  final String? primaryActionTooltip;
  final VoidCallback? onTertiaryAction;
  final String? tertiaryActionLabel;
  final String? tertiaryActionTooltip;
  final IconData tertiaryActionIcon;
  final bool destructive;
  final bool verticalActions;
  final bool enabled;
  final Color? color;
  final Color? closedColor;
  final VoidCallback? onLeadingAction;
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

class _SwipeRevealCardState extends State<SwipeRevealCard> {
  static const double _revealStartThreshold = 32;
  static const double _verticalRejectThreshold = 8;
  static const double _acceptSlopeRatio = 2.2;
  static const double _rejectSlopeRatio = 1.35;
  static const double _minOpenVelocity = 560;
  static const double _minOpenDistance = 44;
  double _revealedWidth = 0;
  double _dragStartRevealedWidth = 0;
  double _dragDx = 0;
  double _dragDy = 0;
  bool _dragAccepted = false;
  bool _dragRejected = false;
  bool _snapClosed = false;
  bool _actionPaneActive = false;
  bool _tickerModeEnabled = true;
  bool _revealedFromStart = false;
  bool _dragStartFromStart = false;

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
      : _hasSecondaryAction
      ? 144
      : 72;
  double get _leadingActionWidth =>
      widget.verticalActions && _leadingActionCount > 1
      ? 76
      : _leadingActionCount > 1
      ? 144
      : 72;
  double get _activeActionWidth =>
      _revealedFromStart ? _leadingActionWidth : _actionWidth;
  bool get _isOpen => _revealedWidth > (_activeActionWidth * 0.5);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final enabled = TickerMode.valuesOf(context).enabled;
    if (_tickerModeEnabled && !enabled) {
      _resetPaneState();
    }
    _tickerModeEnabled = enabled;
  }

  @override
  void didUpdateWidget(covariant SwipeRevealCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled && oldWidget.enabled) {
      _closePane(immediate: true);
    }
    if (oldWidget.key != widget.key &&
        (_revealedWidth != 0 || _actionPaneActive)) {
      _resetPaneState();
    }
  }

  void _resetPaneState() {
    _revealedWidth = 0;
    _dragStartRevealedWidth = 0;
    _dragDx = 0;
    _dragDy = 0;
    _dragAccepted = false;
    _dragRejected = false;
    _snapClosed = false;
    _actionPaneActive = false;
    _revealedFromStart = false;
    _dragStartFromStart = false;
  }

  void _closePane({bool immediate = false}) {
    if (_revealedWidth == 0) return;
    setState(() {
      _snapClosed = immediate;
      _revealedWidth = 0;
    });
  }

  void _runActionAfterPaneClose(VoidCallback? action) {
    if (action == null) return;
    _closePane(immediate: true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      action();
    });
  }

  Future<void> _showContextMenu([TapDownDetails? details]) async {
    if (!widget.enabled) return;
    widget.onWillReveal?.call();
    final box = context.findRenderObject()! as RenderBox;
    final action = await showUnifiedContextMenu<VoidCallback>(
      context: context,
      globalPosition:
          details?.globalPosition ??
          box.localToGlobal(box.size.center(Offset.zero)),
      entries: [
        if (_hasLeadingAction)
          UnifiedMenuEntry.action(
            value: widget.onLeadingAction!,
            label:
                widget.leadingActionLabel ?? widget.leadingActionTooltip ?? '',
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
                widget.tertiaryActionLabel ??
                widget.tertiaryActionTooltip ??
                '',
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
        UnifiedMenuEntry.action(
          value: widget.onRemove,
          label: widget.actionLabel,
          icon: widget.primaryActionIcon,
          destructive: widget.destructive,
        ),
      ],
    );
    if (mounted && widget.enabled) action?.call();
  }

  void _handleHorizontalDragStart(DragStartDetails details) {
    if (!widget.enabled) return;
    _dragStartRevealedWidth = _revealedWidth;
    _dragStartFromStart = _revealedFromStart;
    _dragDx = 0;
    _dragDy = 0;
    _dragAccepted = _revealedWidth > 0;
    _dragRejected = false;
  }

  void _handleHorizontalDragUpdate(DragUpdateDetails details) {
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
              (_dragDx > 0 && _leadingActionCount > 0)) &&
          horizontalDistance >= _revealStartThreshold &&
          horizontalDistance > verticalDistance * _acceptSlopeRatio;
      if (!isIntentionalSwipe) {
        return;
      }
      _revealedFromStart = _dragDx > 0;
      _dragStartFromStart = _revealedFromStart;
      _dragAccepted = true;
      AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection);
      widget.onWillReveal?.call();
    }

    // Post-acceptance: if the gesture veers too vertical, revoke acceptance.
    if (_dragAccepted &&
        _dragStartRevealedWidth == 0 &&
        verticalDistance > horizontalDistance * _rejectSlopeRatio) {
      _dragAccepted = false;
      _dragRejected = true;
      setState(() {
        _revealedWidth = 0;
      });
      return;
    }

    if (_dragStartRevealedWidth > 0 && verticalDistance > 18) {
      _closePane();
      _dragRejected = true;
      return;
    }

    final nextWidth =
        (_dragStartRevealedWidth + (_dragStartFromStart ? _dragDx : -_dragDx))
            .clamp(0.0, _activeActionWidth);
    if (nextWidth == _revealedWidth) return;
    setState(() {
      _actionPaneActive = true;
      _revealedWidth = nextWidth;
    });
  }

  void _handleHorizontalDragEnd(DragEndDetails details) {
    if (_dragRejected || !_dragAccepted) {
      _dragAccepted = false;
      _dragRejected = false;
      if (_dragStartRevealedWidth == 0 && _revealedWidth != 0) {
        setState(() {
          _revealedWidth = 0;
        });
      }
      return;
    }
    final velocity = details.primaryVelocity ?? 0;
    final distanceMet = _revealedWidth >= _minOpenDistance;
    final velocityMet = _revealedFromStart
        ? velocity >= _minOpenVelocity
        : velocity <= -_minOpenVelocity;
    final fullyRevealed = _revealedWidth >= _activeActionWidth * 0.88;
    final shouldOpen = (distanceMet && velocityMet) || fullyRevealed;
    setState(() {
      _revealedWidth = shouldOpen ? _activeActionWidth : 0;
    });
    _dragAccepted = false;
    _dragRejected = false;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final actionWidth = _activeActionWidth;
    final revealProgress = (_revealedWidth / actionWidth).clamp(0.0, 1.0);
    final actionLabel = _hasTertiaryAction
        ? [
            widget.tertiaryActionLabel ?? '',
            widget.secondaryActionLabel ?? '',
            widget.actionLabel,
          ].where((item) => item.trim().isNotEmpty).join(' / ')
        : _hasSecondaryAction
        ? '${widget.secondaryActionLabel ?? ''} / ${widget.actionLabel}'
        : widget.actionLabel;
    final actionTooltip = _hasTertiaryAction
        ? widget.tertiaryActionTooltip ?? widget.removeTooltip
        : _hasSecondaryAction
        ? widget.secondaryActionTooltip ?? widget.removeTooltip
        : widget.removeTooltip;
    final leadingActions = <SwipeRevealAction>[
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
    final trailingActions = <SwipeRevealAction>[
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
        tooltip: widget.primaryActionTooltip ?? widget.removeTooltip,
        onPressed: widget.onRemove,
        primary: true,
        destructive: widget.destructive,
        feedback: widget.destructive
            ? AppInteractionFeedbackType.destructive
            : AppInteractionFeedbackType.confirmation,
      ),
    ];
    Widget buildClosedContent(BuildContext context) {
      final content = ColoredBox(
        color: widget.closedColor ?? cs.surface,
        child: IgnorePointer(ignoring: _isOpen, child: widget.child),
      );

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

    final closedContent = Builder(builder: buildClosedContent);
    if (defaultTargetPlatform == TargetPlatform.windows) {
      return Padding(
        padding: widget.margin,
        child: CallbackShortcuts(
          bindings: widget.enabled
              ? {
                  const SingleActivator(LogicalKeyboardKey.f10, shift: true):
                      _showContextMenu,
                  const SingleActivator(LogicalKeyboardKey.contextMenu):
                      _showContextMenu,
                }
              : const {},
          child: Focus(
            canRequestFocus: widget.enabled,
            skipTraversal: true,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onSecondaryTapDown: widget.enabled ? _showContextMenu : null,
              child: closedContent,
            ),
          ),
        ),
      );
    }
    final cardWidget = RepaintBoundary(
      child: TapRegion(
        onTapOutside: (_) => _closePane(),
        child: Padding(
          padding: widget.margin,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragStart: _handleHorizontalDragStart,
            onHorizontalDragUpdate: _handleHorizontalDragUpdate,
            onHorizontalDragEnd: _handleHorizontalDragEnd,
            onSecondaryTap: () {
              setState(() {
                final opening = !_isOpen;
                _actionPaneActive = opening || _actionPaneActive;
                _revealedFromStart = false;
                _revealedWidth = opening ? _actionWidth : 0;
              });
            },
            onHorizontalDragCancel: () {
              _dragAccepted = false;
              _dragRejected = false;
            },
            child: Stack(
              children: [
                if (_actionPaneActive)
                  Positioned.fill(
                    child: SwipeRevealActionPane(
                      actions: _revealedFromStart
                          ? leadingActions
                          : trailingActions,
                      fromStart: _revealedFromStart,
                      vertical: widget.verticalActions,
                      width: actionWidth,
                      progress: revealProgress,
                      shape: widget.shape,
                      color: widget.color,
                      label: actionLabel,
                      tooltip: actionTooltip,
                      onAction: _runActionAfterPaneClose,
                    ),
                  ),
                if (!_actionPaneActive && _revealedWidth == 0)
                  closedContent
                else
                  TweenAnimationBuilder<double>(
                    tween: Tween<double>(begin: 0, end: _revealedWidth),
                    duration: _snapClosed
                        ? Duration.zero
                        : const Duration(milliseconds: 220),
                    curve: Curves.easeOutCubic,
                    onEnd: () {
                      if (!mounted) return;
                      if (!_snapClosed &&
                          (_revealedWidth != 0 || !_actionPaneActive)) {
                        return;
                      }
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (!mounted) return;
                        setState(() {
                          _snapClosed = false;
                          if (_revealedWidth == 0) {
                            _actionPaneActive = false;
                            _revealedFromStart = false;
                          }
                        });
                      });
                    },
                    builder: (context, value, child) {
                      return Transform.translate(
                        offset: Offset(_revealedFromStart ? value : -value, 0),
                        child: child,
                      );
                    },
                    child: closedContent,
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
      ),
    );

    return cardWidget;
  }
}
