import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../i18n/app_language_provider.dart';

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
  });

  final Widget child;
  final VoidCallback onRemove;
  final String actionLabel;
  final String removeTooltip;
  final ShapeBorder shape;
  final EdgeInsets margin;
  final VoidCallback? onWillReveal;

  @override
  State<SwipeRevealCard> createState() => _SwipeRevealCardState();
}

class _SwipeRevealCardState extends State<SwipeRevealCard> {
  static const double _actionWidth = 72;

  double _revealedWidth = 0;

  bool get _isOpen => _revealedWidth > (_actionWidth * 0.5);

  @override
  void didUpdateWidget(covariant SwipeRevealCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.key != widget.key && _revealedWidth != 0) {
      _revealedWidth = 0;
    }
  }

  void _closePane() {
    if (_revealedWidth == 0) return;
    setState(() {
      _revealedWidth = 0;
    });
  }

  void _handleHorizontalDragUpdate(DragUpdateDetails details) {
    // If vertical movement dominates, ignore the swipe (anti-accidental-touch)
    if (details.delta.dy.abs() > details.delta.dx.abs() * 1.5 && _revealedWidth < 10) {
      return;
    }
    if (_revealedWidth > 0 && details.delta.dy.abs() > 8) {
      _closePane();
      return;
    }
    final nextWidth = (_revealedWidth - details.delta.dx).clamp(
      0.0,
      _actionWidth,
    );
    if (nextWidth == _revealedWidth) return;
    if (_revealedWidth == 0 && nextWidth > 0) {
      HapticFeedback.selectionClick();
      widget.onWillReveal?.call();
    }
    setState(() {
      _revealedWidth = nextWidth;
    });
  }

  void _handleHorizontalDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    final shouldOpen =
        velocity < -180 || (velocity.abs() < 180 && _revealedWidth > 44);
    setState(() {
      _revealedWidth = shouldOpen ? _actionWidth : 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final i18n = context.watch<AppLanguageProvider>();
    final cs = Theme.of(context).colorScheme;
    final revealProgress = (_revealedWidth / _actionWidth).clamp(0.0, 1.0);
    final cardBorderRadius = widget.shape is RoundedRectangleBorder
        ? (widget.shape as RoundedRectangleBorder).borderRadius
        : BorderRadius.zero;

    return TapRegion(
      onTapOutside: (_) => _closePane(),
      child: Padding(
        padding: widget.margin,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragUpdate: _handleHorizontalDragUpdate,
          onHorizontalDragEnd: _handleHorizontalDragEnd,
          child: Stack(
            children: [
              Positioned.fill(
                child: DecoratedBox(
                  decoration: ShapeDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        cs.errorContainer.withValues(alpha: 0.94),
                        cs.errorContainer.withValues(alpha: 0.82),
                      ],
                    ),
                    shape: widget.shape,
                  ),
                  child: Stack(
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Padding(
                          padding: const EdgeInsets.only(left: 18, right: 86),
                          child: AnimatedOpacity(
                            opacity: 0.24 + (revealProgress * 0.76),
                            duration: const Duration(milliseconds: 160),
                            curve: Curves.easeOutCubic,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 5,
                                  ),
                                  decoration: BoxDecoration(
                                    color: cs.error.withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(999),
                                    border: Border.all(
                                      color: cs.error.withValues(alpha: 0.18),
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.swipe_left_rounded,
                                        size: 14,
                                        color: cs.error,
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        widget.actionLabel,
                                        style: Theme.of(context)
                                            .textTheme
                                            .labelMedium
                                            ?.copyWith(
                                              color: cs.error,
                                              fontWeight: FontWeight.w800,
                                            ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  widget.removeTooltip,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                        color: cs.onErrorContainer,
                                        fontWeight: FontWeight.w600,
                                      ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: Padding(
                          padding: const EdgeInsets.only(right: 14),
                          child: AnimatedScale(
                            scale: 0.92 + (revealProgress * 0.08),
                            duration: const Duration(milliseconds: 180),
                            curve: Curves.easeOutBack,
                            child: IconButton.filled(
                              onPressed: () {
                                Feedback.forTap(context);
                                HapticFeedback.mediumImpact();
                                _closePane();
                                widget.onRemove();
                              },
                              style: IconButton.styleFrom(
                                backgroundColor: cs.error,
                                foregroundColor: cs.onError,
                                minimumSize: const Size(54, 54),
                                maximumSize: const Size(54, 54),
                              ),
                              tooltip: i18n.tr('remove'),
                              icon: const Icon(Icons.delete_outline_rounded),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              TweenAnimationBuilder<double>(
                tween: Tween<double>(begin: 0, end: _revealedWidth),
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                builder: (context, value, child) {
                  return Transform.translate(
                    offset: Offset(-value, 0),
                    child: child,
                  );
                },
                child: IgnorePointer(ignoring: _isOpen, child: widget.child),
              ),
              if (_isOpen)
                Positioned.fill(
                  right: _actionWidth,
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: _closePane,
                  ),
                ),
              if (_revealedWidth > 0)
                Positioned.fill(
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: cardBorderRadius,
                        border: Border.all(
                          color: cs.outlineVariant.withValues(alpha: 0.18),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
