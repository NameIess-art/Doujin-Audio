import 'dart:async';

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
  bool _pointerInside = false;
  ValueListenable<bool>? _scrollActivity;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bindScrollActivity();
  }

  @override
  void didUpdateWidget(covariant MarqueePauseScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.hoverToRun != oldWidget.hoverToRun) {
      _pointerInside = _hovered = false;
      _bindScrollActivity();
    }
  }

  void _bindScrollActivity() {
    final activity = widget.hoverToRun
        ? ScrollActivityGate.scrollingListenableOf(context)
        : null;
    if (!identical(activity, _scrollActivity)) {
      _scrollActivity?.removeListener(_syncHover);
      _scrollActivity = activity;
      _scrollActivity?.addListener(_syncHover);
    }
    _syncHover();
  }

  void _syncHover() {
    // Wheel scrolling moves cards beneath a stationary pointer. Keep the
    // existing text tree until idle instead of mounting horizontal viewports
    // for every card the pointer crosses; their tickers already pause on scroll.
    if (!widget.hoverToRun ||
        (_scrollActivity?.value ?? false) ||
        _hovered == _pointerInside) {
      return;
    }
    setState(() => _hovered = _pointerInside);
  }

  void _setPointerInside(bool value) {
    _pointerInside = value;
    _syncHover();
  }

  @override
  void dispose() {
    _scrollActivity?.removeListener(_syncHover);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final parentScope = context
        .dependOnInheritedWidgetOfExactType<_MarqueePauseScope>();
    final child = _MarqueePauseScope(
      isPaused:
          widget.isPaused ||
          (parentScope?.isPaused ?? false) ||
          (widget.hoverToRun && !_hovered),
      hoverToRun: widget.hoverToRun || (parentScope?.hoverToRun ?? false),
      child: widget.child,
    );
    return widget.hoverToRun
        ? MouseRegion(
            onEnter: (_) => _setPointerInside(true),
            onExit: (_) => _setPointerInside(false),
            child: child,
          )
        : child;
  }
}

class _MarqueePauseScope extends InheritedWidget {
  const _MarqueePauseScope({
    required this.isPaused,
    required this.hoverToRun,
    required super.child,
  });
  final bool isPaused;
  final bool hoverToRun;

  @override
  bool updateShouldNotify(_MarqueePauseScope oldWidget) =>
      isPaused != oldWidget.isPaused || hoverToRun != oldWidget.hoverToRun;
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
    this.animateOnAndroid = false,
    this.child,
  });

  final String text;
  final TextStyle? style;
  final Duration pauseDuration;
  final double scrollSpeed;
  final double edgePadding;
  final bool forceMarquee;
  final bool animateOnAndroid;
  final Widget? child;

  @override
  State<MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<MarqueeText>
    with SingleTickerProviderStateMixin {
  // Marquee progress must not share PageStorage offsets with the parent list.
  ScrollController? _controller;
  Ticker? _ticker;
  Timer? _pauseTimer;
  Duration? _previousTick;
  bool _atEnd = false;
  bool _canAnimate = false;
  bool _pausedHoverScope = false;
  bool _pointerDown = false;
  bool _userScrolling = false;
  bool _needsDependencySync = false;
  String? _measuredText;
  TextStyle? _measuredStyle;
  TextDirection? _measuredDirection;
  TextScaler? _measuredScaler;
  double? _measuredWidth;
  ValueListenable<bool>? _scrollActivity;
  ValueListenable<TickerModeData>? _tickerMode;

  ScrollController _ensureController() =>
      _controller ??= ScrollController(keepScrollOffset: false);

  Ticker _ensureTicker() => _ticker ??= createTicker(_tick);

  bool get _usesStaticAndroidText =>
      defaultTargetPlatform == TargetPlatform.android && !widget.animateOnAndroid;

  bool get _pauseRequested =>
      _usesStaticAndroidText || !_canAnimate || (_scrollActivity?.value ?? false);
  bool get _animationAllowed =>
      !_pauseRequested && (_tickerMode?.value.enabled ?? true);

  bool get _shouldRun {
    final controller = _controller;
    return _animationAllowed &&
        !_pointerDown &&
        !_userScrolling &&
        controller != null &&
        controller.hasClients &&
        controller.position.hasContentDimensions &&
        controller.position.maxScrollExtent > 0;
  }

  void _syncDependencies() {
    if (_usesStaticAndroidText) {
      _canAnimate = false;
      _pausedHoverScope = false;
      _tickerMode?.removeListener(_syncTicker);
      _tickerMode = null;
      _scrollActivity?.removeListener(_handleScrollActivity);
      _scrollActivity = null;
      _cancelPauseTimer();
      _ticker?.stop();
      return;
    }
    final pauseScope = context
        .dependOnInheritedWidgetOfExactType<_MarqueePauseScope>();
    final isPaused = pauseScope?.isPaused ?? false;
    final hoverToRun = pauseScope?.hoverToRun ?? false;
    _pausedHoverScope = isPaused && hoverToRun;
    if (_pausedHoverScope) {
      _canAnimate = false;
      _tickerMode?.removeListener(_syncTicker);
      _tickerMode = null;
      _scrollActivity?.removeListener(_handleScrollActivity);
      _scrollActivity = null;
      _cancelPauseTimer();
      _ticker?.stop();
      return;
    }
    _canAnimate = !MediaQuery.disableAnimationsOf(context) && !isPaused;
    final tickerMode = TickerMode.getValuesNotifier(context);
    if (!identical(tickerMode, _tickerMode)) {
      _tickerMode?.removeListener(_syncTicker);
      _tickerMode = tickerMode;
      tickerMode.addListener(_syncTicker);
    }
    final activity = ScrollActivityGate.scrollingListenableOf(context);
    if (!identical(activity, _scrollActivity)) {
      _scrollActivity?.removeListener(_handleScrollActivity);
      _scrollActivity = activity;
      _scrollActivity?.addListener(_handleScrollActivity);
    }
    _handleScrollActivity();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _needsDependencySync = false;
    _syncDependencies();
  }

  void _handleScrollActivity() {
    _syncTicker();
    final controller = _controller;
    if (_pauseRequested &&
        controller != null &&
        controller.hasClients &&
        controller.offset != 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final current = _controller;
        if (mounted &&
            _pauseRequested &&
            current != null &&
            current.hasClients) {
          current.jumpTo(0);
        }
      });
    }
  }

  @override
  void didUpdateWidget(MarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animateOnAndroid != widget.animateOnAndroid) {
      if (_usesStaticAndroidText) {
        _needsDependencySync = false;
        _syncDependencies();
      } else {
        _needsDependencySync = true;
      }
    }
    if (oldWidget.text != widget.text) {
      _cancelPauseTimer();
      _ticker?.stop();
      final controller = _controller;
      if (controller != null && controller.hasClients) controller.jumpTo(0);
      _atEnd = false;
    }
    _syncTicker();
  }

  void _cancelPauseTimer() {
    _pauseTimer?.cancel();
    _pauseTimer = null;
  }

  void _schedulePause(Duration duration) {
    _ticker?.stop();
    _cancelPauseTimer();
    _pauseTimer = Timer(duration, () {
      _pauseTimer = null;
      if (!mounted || !_shouldRun) return;
      final controller = _controller;
      if (_atEnd && controller != null) {
        controller.jumpTo(0);
        _atEnd = false;
        if (widget.pauseDuration > Duration.zero) {
          _schedulePause(widget.pauseDuration);
          return;
        }
      }
      _previousTick = null;
      _ensureTicker().start();
    });
  }

  void _syncTicker() {
    if (!mounted) return;
    final shouldRun = _shouldRun;
    if (shouldRun && !(_ticker?.isActive ?? false) && _pauseTimer == null) {
      _previousTick = null;
      final hoverToRun =
          context
              .getInheritedWidgetOfExactType<_MarqueePauseScope>()
              ?.hoverToRun ??
          false;
      final initialPause =
          defaultTargetPlatform == TargetPlatform.windows && hoverToRun
          ? Duration.zero
          : widget.pauseDuration;
      final controller = _controller!;
      _atEnd = controller.offset >= controller.position.maxScrollExtent;
      if (initialPause > Duration.zero) {
        _schedulePause(initialPause);
      } else {
        _ensureTicker().start();
      }
    } else if (!shouldRun) {
      _cancelPauseTimer();
      _ticker?.stop();
    }
  }

  void _tick(Duration elapsed) {
    final controller = _controller;
    if (controller == null || !controller.hasClients) {
      _ticker?.stop();
      return;
    }
    final previous = _previousTick;
    _previousTick = elapsed;
    if (previous == null) return;
    final seconds = (elapsed - previous).inMicroseconds / 1000000;
    if (_atEnd) {
      controller.jumpTo(0);
      _atEnd = false;
      if (widget.pauseDuration > Duration.zero) {
        _schedulePause(widget.pauseDuration);
      }
      return;
    }
    final position = controller.position;
    final target = (position.pixels + widget.scrollSpeed * seconds).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    controller.jumpTo(target);
    if (target == position.maxScrollExtent) {
      _atEnd = true;
      if (widget.pauseDuration > Duration.zero) {
        _schedulePause(widget.pauseDuration);
      }
    }
  }

  static TextStyle _metricsStyle(TextStyle style) => TextStyle(
    fontFamily: style.fontFamily,
    fontFamilyFallback: style.fontFamilyFallback,
    fontSize: style.fontSize,
    fontWeight: style.fontWeight,
    fontStyle: style.fontStyle,
    letterSpacing: style.letterSpacing,
    wordSpacing: style.wordSpacing,
    height: style.height,
    leadingDistribution: style.leadingDistribution,
    locale: style.locale,
    fontFeatures: style.fontFeatures,
    fontVariations: style.fontVariations,
    textBaseline: style.textBaseline,
  );

  double _measureTextWidth(BuildContext context) {
    final direction = Directionality.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final defaultStyle = DefaultTextStyle.of(context).style;
    final effectiveStyle = widget.style == null
        ? defaultStyle
        : defaultStyle.merge(widget.style);
    final metricsStyle = _metricsStyle(effectiveStyle);
    if (_measuredWidth != null &&
        _measuredText == widget.text &&
        _measuredStyle == metricsStyle &&
        _measuredDirection == direction &&
        _measuredScaler == scaler) {
      return _measuredWidth!;
    }
    final painter = TextPainter(
      text: TextSpan(text: widget.text, style: effectiveStyle),
      textDirection: direction,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    _measuredText = widget.text;
    _measuredStyle = metricsStyle;
    _measuredDirection = direction;
    _measuredScaler = scaler;
    _measuredWidth = width;
    return width;
  }

  @override
  void dispose() {
    _cancelPauseTimer();
    _scrollActivity?.removeListener(_handleScrollActivity);
    _tickerMode?.removeListener(_syncTicker);
    _ticker?.dispose();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_needsDependencySync) {
      _needsDependencySync = false;
      _syncDependencies();
    }
    if (_usesStaticAndroidText || _pausedHoverScope) {
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
        var needsMarquee = widget.forceMarquee;
        var displayText = widget.text;
        if (constraints.hasBoundedWidth) {
          final width = _measureTextWidth(context);
          if (width > constraints.maxWidth) {
            needsMarquee = true;
          } else if (widget.forceMarquee && width > 0) {
            displayText =
                '${widget.text}        ' *
                ((constraints.maxWidth / width).ceil() + 2);
          }
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
                controller: _ensureController(),
                absorbScrollNotifications: true,
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
                        physics: const NeverScrollableScrollPhysics(),
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
