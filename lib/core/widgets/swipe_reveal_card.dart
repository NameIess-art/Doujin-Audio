import 'package:flutter/material.dart';

import 'app_feedback.dart';

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
    this.primaryActionIcon = Icons.delete_outline_rounded,
    this.primaryActionTooltip,
    this.onTertiaryAction,
    this.tertiaryActionLabel,
    this.tertiaryActionTooltip,
    this.tertiaryActionIcon = Icons.download_rounded,
    this.destructive = true,
    this.verticalActions = false,
    this.color,
    this.closedColor,
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
  final IconData primaryActionIcon;
  final String? primaryActionTooltip;
  final VoidCallback? onTertiaryAction;
  final String? tertiaryActionLabel;
  final String? tertiaryActionTooltip;
  final IconData tertiaryActionIcon;
  final bool destructive;
  final bool verticalActions;
  final Color? color;
  final Color? closedColor;

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

  bool get _hasSecondaryAction => widget.onSecondaryAction != null;
  bool get _hasTertiaryAction => widget.onTertiaryAction != null;
  int get _actionCount =>
      1 + (_hasSecondaryAction ? 1 : 0) + (_hasTertiaryAction ? 1 : 0);
  double get _actionWidth => widget.verticalActions && _actionCount > 1
      ? 76
      : _hasSecondaryAction
      ? 144
      : 72;
  bool get _isOpen => _revealedWidth > (_actionWidth * 0.5);

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

  void _handleHorizontalDragStart(DragStartDetails details) {
    _dragStartRevealedWidth = _revealedWidth;
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
      final isIntentionalLeftSwipe =
          _dragDx < 0 &&
          horizontalDistance >= _revealStartThreshold &&
          horizontalDistance > verticalDistance * _acceptSlopeRatio;
      if (!isIntentionalLeftSwipe) {
        return;
      }
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

    final nextWidth = (_dragStartRevealedWidth - _dragDx).clamp(
      0.0,
      _actionWidth,
    );
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
    final velocityMet = velocity <= -_minOpenVelocity;
    final fullyRevealed = _revealedWidth >= _actionWidth * 0.88;
    final shouldOpen = (distanceMet && velocityMet) || fullyRevealed;
    setState(() {
      _revealedWidth = shouldOpen ? _actionWidth : 0;
    });
    _dragAccepted = false;
    _dragRejected = false;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final revealProgress = (_revealedWidth / _actionWidth).clamp(0.0, 1.0);
    final baseColor =
        widget.color ?? (widget.destructive ? cs.error : cs.primary);
    final isBgDark =
        ThemeData.estimateBrightnessForColor(baseColor) == Brightness.dark;
    final onColor = isBgDark
        ? const Color(0xFFF8F5F7)
        : const Color(0xFF211F23);
    final revealShape = switch (widget.shape) {
      final OutlinedBorder shape => shape.copyWith(side: BorderSide.none),
      final ShapeBorder shape => shape,
    };

    final paneStartColor = Color.lerp(baseColor, onColor, 0.08)!;
    final paneEndColor = baseColor;

    final accentColor = onColor;
    final accentContainerOnColor = onColor;

    final tertiaryBg = onColor.withValues(alpha: 0.18);
    final tertiaryFg = onColor;
    final secondaryBg = onColor.withValues(alpha: 0.18);
    final secondaryFg = onColor;
    final primaryBg = widget.destructive
        ? onColor
        : onColor.withValues(alpha: 0.3);
    final primaryFg = widget.destructive ? baseColor : onColor;
    final showVerticalActions = widget.verticalActions && _actionCount > 1;
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
    Widget buildClosedContent(BuildContext context) {
      final content = ColoredBox(
        color: widget.closedColor ?? cs.surface,
        child: Stack(
          children: [IgnorePointer(ignoring: _isOpen, child: widget.child)],
        ),
      );

      if (widget.shape case final RoundedRectangleBorder roundedShape) {
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
    return RepaintBoundary(
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
                    child: DecoratedBox(
                      decoration: ShapeDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [paneStartColor, paneEndColor],
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
                                right: showVerticalActions
                                    ? _actionWidth + 26
                                    : _hasTertiaryAction
                                    ? 216
                                    : _hasSecondaryAction
                                    ? 158
                                    : 86,
                              ),
                              child: revealProgress == 0
                                  ? const SizedBox.shrink()
                                  : AnimatedOpacity(
                                      opacity: 0.24 + (revealProgress * 0.76),
                                      duration: const Duration(
                                        milliseconds: 160,
                                      ),
                                      curve: Curves.easeOutCubic,
                                      child: LayoutBuilder(
                                        builder: (context, constraints) {
                                          final compact =
                                              constraints.maxHeight < 64;
                                          return Column(
                                            mainAxisSize: MainAxisSize.min,
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 10,
                                                      vertical: 5,
                                                    ),
                                                decoration: BoxDecoration(
                                                  color: accentColor.withValues(
                                                    alpha: 0.12,
                                                  ),
                                                  borderRadius:
                                                      BorderRadius.circular(
                                                        999,
                                                      ),
                                                  border: Border.all(
                                                    color: accentColor
                                                        .withValues(
                                                          alpha: 0.18,
                                                        ),
                                                  ),
                                                ),
                                                child: Row(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    Icon(
                                                      Icons.swipe_left_rounded,
                                                      size: 14,
                                                      color: accentColor,
                                                    ),
                                                    const SizedBox(width: 4),
                                                    Text(
                                                      actionLabel,
                                                      style: Theme.of(context)
                                                          .textTheme
                                                          .labelMedium
                                                          ?.copyWith(
                                                            color: accentColor,
                                                            fontWeight:
                                                                FontWeight.w800,
                                                          ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                              if (!compact) ...[
                                                const SizedBox(height: 8),
                                                Text(
                                                  actionTooltip,
                                                  maxLines: 2,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: Theme.of(context)
                                                      .textTheme
                                                      .bodySmall
                                                      ?.copyWith(
                                                        color:
                                                            accentContainerOnColor,
                                                        fontWeight:
                                                            FontWeight.w600,
                                                      ),
                                                ),
                                              ],
                                            ],
                                          );
                                        },
                                      ),
                                    ),
                            ),
                          ),
                          Align(
                            alignment: Alignment.centerRight,
                            child: Padding(
                              padding: EdgeInsets.only(
                                top: showVerticalActions ? 10 : 0,
                                right: showVerticalActions ? 10 : 14,
                                bottom: showVerticalActions ? 10 : 0,
                              ),
                              child: AnimatedScale(
                                scale: 0.92 + (revealProgress * 0.08),
                                duration: const Duration(milliseconds: 180),
                                curve: Curves.easeOutBack,
                                child: showVerticalActions
                                    ? SizedBox(
                                        width: _actionWidth - 20,
                                        child: LayoutBuilder(
                                          builder: (context, constraints) {
                                            final gap = _actionCount > 1
                                                ? 6.0
                                                : 0.0;
                                            final availableHeight =
                                                constraints.maxHeight;
                                            final buttonSize =
                                                ((availableHeight -
                                                            gap *
                                                                (_actionCount -
                                                                    1)) /
                                                        _actionCount)
                                                    .clamp(34.0, 48.0);
                                            return Column(
                                              mainAxisAlignment:
                                                  MainAxisAlignment.center,
                                              children: [
                                                if (_hasTertiaryAction) ...[
                                                  _SwipeRevealActionButton(
                                                    onPressed: () {
                                                      AppInteractionFeedback.trigger(
                                                        AppInteractionFeedbackType
                                                            .selection,
                                                      );
                                                      _runActionAfterPaneClose(
                                                        widget.onTertiaryAction,
                                                      );
                                                    },
                                                    backgroundColor: tertiaryBg,
                                                    foregroundColor: tertiaryFg,
                                                    tooltip:
                                                        widget
                                                            .tertiaryActionTooltip ??
                                                        widget
                                                            .tertiaryActionLabel,
                                                    icon: widget
                                                        .tertiaryActionIcon,
                                                    tonal: true,
                                                    size: buttonSize,
                                                  ),
                                                  SizedBox(height: gap),
                                                ],
                                                if (_hasSecondaryAction) ...[
                                                  _SwipeRevealActionButton(
                                                    onPressed: () {
                                                      AppInteractionFeedback.trigger(
                                                        AppInteractionFeedbackType
                                                            .selection,
                                                      );
                                                      _runActionAfterPaneClose(
                                                        widget
                                                            .onSecondaryAction,
                                                      );
                                                    },
                                                    backgroundColor:
                                                        secondaryBg,
                                                    foregroundColor:
                                                        secondaryFg,
                                                    tooltip:
                                                        widget
                                                            .secondaryActionTooltip ??
                                                        widget
                                                            .secondaryActionLabel,
                                                    icon: widget
                                                        .secondaryActionIcon,
                                                    tonal: true,
                                                    size: buttonSize,
                                                  ),
                                                  SizedBox(height: gap),
                                                ],
                                                _SwipeRevealActionButton(
                                                  onPressed: () {
                                                    AppInteractionFeedback.trigger(
                                                      widget.destructive
                                                          ? AppInteractionFeedbackType
                                                                .destructive
                                                          : AppInteractionFeedbackType
                                                                .confirmation,
                                                    );
                                                    _runActionAfterPaneClose(
                                                      widget.onRemove,
                                                    );
                                                  },
                                                  backgroundColor: primaryBg,
                                                  foregroundColor: primaryFg,
                                                  tooltip:
                                                      widget
                                                          .primaryActionTooltip ??
                                                      widget.removeTooltip,
                                                  icon:
                                                      widget.primaryActionIcon,
                                                  tonal: !widget.destructive,
                                                  size: buttonSize,
                                                ),
                                              ],
                                            );
                                          },
                                        ),
                                      )
                                    : LayoutBuilder(
                                        builder: (context, constraints) {
                                          final buttonSize =
                                              constraints.maxHeight.isFinite
                                              ? (constraints.maxHeight - 20)
                                                    .clamp(34.0, 54.0)
                                              : 54.0;
                                          return Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              if (_hasTertiaryAction) ...[
                                                _SwipeRevealActionButton(
                                                  onPressed: () {
                                                    AppInteractionFeedback.trigger(
                                                      AppInteractionFeedbackType
                                                          .selection,
                                                    );
                                                    _runActionAfterPaneClose(
                                                      widget.onTertiaryAction,
                                                    );
                                                  },
                                                  backgroundColor: tertiaryBg,
                                                  foregroundColor: tertiaryFg,
                                                  tooltip:
                                                      widget
                                                          .tertiaryActionTooltip ??
                                                      widget
                                                          .tertiaryActionLabel,
                                                  icon:
                                                      widget.tertiaryActionIcon,
                                                  tonal: true,
                                                  size: buttonSize,
                                                ),
                                                const SizedBox(width: 8),
                                              ],
                                              if (_hasSecondaryAction) ...[
                                                _SwipeRevealActionButton(
                                                  onPressed: () {
                                                    AppInteractionFeedback.trigger(
                                                      AppInteractionFeedbackType
                                                          .selection,
                                                    );
                                                    _runActionAfterPaneClose(
                                                      widget.onSecondaryAction,
                                                    );
                                                  },
                                                  backgroundColor: secondaryBg,
                                                  foregroundColor: secondaryFg,
                                                  tooltip:
                                                      widget
                                                          .secondaryActionTooltip ??
                                                      widget
                                                          .secondaryActionLabel,
                                                  icon: widget
                                                      .secondaryActionIcon,
                                                  tonal: true,
                                                  size: buttonSize,
                                                ),
                                                const SizedBox(width: 8),
                                              ],
                                              _SwipeRevealActionButton(
                                                onPressed: () {
                                                  AppInteractionFeedback.trigger(
                                                    widget.destructive
                                                        ? AppInteractionFeedbackType
                                                              .destructive
                                                        : AppInteractionFeedbackType
                                                              .confirmation,
                                                  );
                                                  _runActionAfterPaneClose(
                                                    widget.onRemove,
                                                  );
                                                },
                                                backgroundColor: primaryBg,
                                                foregroundColor: primaryFg,
                                                tooltip:
                                                    widget
                                                        .primaryActionTooltip ??
                                                    widget.removeTooltip,
                                                icon: widget.primaryActionIcon,
                                                tonal: !widget.destructive,
                                                size: buttonSize,
                                              ),
                                            ],
                                          );
                                        },
                                      ),
                              ),
                            ),
                          ),
                        ],
                      ),
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
                      setState(() {
                        _snapClosed = false;
                        if (_revealedWidth == 0) {
                          _actionPaneActive = false;
                        }
                      });
                    },
                    builder: (context, value, child) {
                      return Transform.translate(
                        offset: Offset(-value, 0),
                        child: child,
                      );
                    },
                    child: closedContent,
                  ),
                if (_isOpen)
                  Positioned.fill(
                    right: _actionWidth,
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
  }
}

class _SwipeRevealActionButton extends StatelessWidget {
  const _SwipeRevealActionButton({
    required this.onPressed,
    required this.backgroundColor,
    required this.foregroundColor,
    required this.tooltip,
    required this.icon,
    this.tonal = false,
    this.size = 54,
  });

  final VoidCallback onPressed;
  final Color backgroundColor;
  final Color foregroundColor;
  final String? tooltip;
  final IconData icon;
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
    return tonal
        ? IconButton.filledTonal(
            onPressed: onPressed,
            style: style,
            tooltip: tooltip,
            icon: Icon(icon, size: iconSize),
          )
        : IconButton.filled(
            onPressed: onPressed,
            style: style,
            tooltip: tooltip,
            icon: Icon(icon, size: iconSize),
          );
  }
}
