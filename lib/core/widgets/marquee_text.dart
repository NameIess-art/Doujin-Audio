import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import 'horizontal_edge_fade_scroll.dart';
import 'scroll_activity_gate.dart';

class MarqueePauseScope extends StatefulWidget {
  const MarqueePauseScope({
    super.key,
    required this.isPaused,
    required this.child,
    this.hoverToRun = false,
  });

  final bool isPaused;
  final Widget child;
  final bool hoverToRun;

  static bool isPausedOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_MarqueePauseScope>()
          ?.isPaused ??
      false;

  @override
  State<MarqueePauseScope> createState() => _MarqueePauseScopeState();
}

class _MarqueePauseScopeState extends State<MarqueePauseScope> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final child = _MarqueePauseScope(
      isPaused:
          widget.isPaused ||
          MarqueePauseScope.isPausedOf(context) ||
          (widget.hoverToRun && !_hovered),
      child: widget.child,
    );
    return widget.hoverToRun
        ? MouseRegion(
            onEnter: (_) => setState(() => _hovered = true),
            onExit: (_) => setState(() => _hovered = false),
            child: child,
          )
        : child;
  }
}

class _MarqueePauseScope extends InheritedWidget {
  const _MarqueePauseScope({required this.isPaused, required super.child});
  final bool isPaused;

  @override
  bool updateShouldNotify(_MarqueePauseScope oldWidget) =>
      isPaused != oldWidget.isPaused;
}

class MarqueeText extends StatefulWidget {
  const MarqueeText({
    super.key,
    required this.text,
    this.style,
    this.pauseDuration = const Duration(milliseconds: 1500),
    this.scrollSpeed = 30.0,
    this.edgePadding = 8.0,
    this.forceMarquee = false,
    this.allowManualScroll = false,
    this.child,
  });

  final String text;
  final TextStyle? style;
  final Duration pauseDuration;
  final double scrollSpeed;
  final double edgePadding;
  final bool forceMarquee;
  final bool allowManualScroll;
  final Widget? child;

  @override
  State<MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<MarqueeText>
    with SingleTickerProviderStateMixin {
  // Marquee progress must not share PageStorage offsets with the parent list.
  final _controller = ScrollController(keepScrollOffset: false);
  late final Ticker _ticker = createTicker(_tick);
  Duration? _previousTick;
  double _pauseSeconds = 0;
  bool _atEnd = false;
  bool _canAnimate = false;
  bool _pointerDown = false;
  bool _userScrolling = false;

  double get _pauseDuration => widget.pauseDuration.inMicroseconds / 1000000;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _canAnimate =
        defaultTargetPlatform != TargetPlatform.android &&
        TickerMode.valuesOf(context).enabled &&
        !MediaQuery.disableAnimationsOf(context) &&
        !MarqueePauseScope.isPausedOf(context) &&
        !ScrollActivityGate.isScrollingOf(context);
    _syncTicker();
    if (!_canAnimate && _controller.hasClients && _controller.offset != 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_canAnimate && _controller.hasClients) {
          _controller.jumpTo(0);
        }
      });
    }
  }

  @override
  void didUpdateWidget(MarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text && _controller.hasClients) {
      _controller.jumpTo(0);
      _atEnd = false;
      _pauseSeconds = _pauseDuration;
    }
    _syncTicker();
  }

  void _syncTicker() {
    final shouldRun =
        _canAnimate &&
        !_pointerDown &&
        !_userScrolling &&
        _controller.hasClients &&
        _controller.position.hasContentDimensions &&
        _controller.position.maxScrollExtent > 0;
    if (shouldRun && !_ticker.isActive) {
      _previousTick = null;
      _pauseSeconds = _pauseDuration;
      _atEnd = _controller.offset >= _controller.position.maxScrollExtent;
      _ticker.start();
    } else if (!shouldRun && _ticker.isActive) {
      _ticker.stop();
    }
  }

  void _tick(Duration elapsed) {
    if (!_controller.hasClients) {
      _ticker.stop();
      return;
    }
    final previous = _previousTick;
    _previousTick = elapsed;
    if (previous == null) return;
    var seconds = (elapsed - previous).inMicroseconds / 1000000;
    if (_pauseSeconds > 0) {
      final remaining = seconds - _pauseSeconds;
      _pauseSeconds = (_pauseSeconds - seconds).clamp(0, _pauseDuration);
      if (remaining <= 0) return;
      seconds = remaining;
    }
    if (_atEnd) {
      _controller.jumpTo(0);
      _atEnd = false;
      _pauseSeconds = _pauseDuration;
      return;
    }
    final position = _controller.position;
    final target = (position.pixels + widget.scrollSpeed * seconds).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    _controller.jumpTo(target);
    if (target == position.maxScrollExtent) {
      _atEnd = true;
      _pauseSeconds = _pauseDuration;
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform == TargetPlatform.android) {
      return widget.child ??
          Text(
            widget.text,
            style: widget.style,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        var needsMarquee = widget.forceMarquee || widget.allowManualScroll;
        var displayText = widget.text;
        if (constraints.hasBoundedWidth) {
          final painter = TextPainter(
            text: TextSpan(text: widget.text, style: widget.style),
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
            maxLines: 1,
          )..layout();
          if (painter.width > constraints.maxWidth) {
            needsMarquee = true;
          } else if (widget.forceMarquee && painter.width > 0) {
            displayText =
                '${widget.text}        ' *
                ((constraints.maxWidth / painter.width).ceil() + 2);
          }
          painter.dispose();
        }
        if (!needsMarquee) {
          return widget.child ??
              Text(
                widget.text,
                style: widget.style,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              );
        }
        return RepaintBoundary(
          child: NotificationListener<ScrollMetricsNotification>(
            onNotification: (_) {
              _syncTicker();
              return false;
            },
            child: Listener(
              onPointerDown: (_) {
                _pointerDown = true;
                _syncTicker();
              },
              onPointerUp: (_) {
                _pointerDown = false;
                _syncTicker();
              },
              onPointerCancel: (_) {
                _pointerDown = false;
                _syncTicker();
              },
              child: HorizontalEdgeFadeScroll(
                controller: _controller,
                builder: (controller) =>
                    NotificationListener<ScrollNotification>(
                      onNotification: (notification) {
                        if (notification is UserScrollNotification) {
                          _userScrolling =
                              notification.direction != ScrollDirection.idle;
                          _syncTicker();
                        }
                        return false;
                      },
                      child: SingleChildScrollView(
                        controller: controller,
                        scrollDirection: Axis.horizontal,
                        physics: widget.allowManualScroll
                            ? null
                            : const NeverScrollableScrollPhysics(),
                        padding: EdgeInsets.symmetric(
                          horizontal: widget.edgePadding,
                        ),
                        child:
                            widget.child ??
                            Text(displayText, style: widget.style),
                      ),
                    ),
              ),
            ),
          ),
        );
      },
    );
  }
}
