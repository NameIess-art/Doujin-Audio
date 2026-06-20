import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'scroll_activity_gate.dart';

class MarqueeText extends StatefulWidget {
  final String text;
  final TextStyle? style;
  final Duration pauseDuration;
  final double scrollSpeed;
  final double edgePadding;
  final bool forceMarquee;
  final bool allowAndroidMarquee;

  const MarqueeText({
    super.key,
    required this.text,
    this.style,
    this.pauseDuration = const Duration(milliseconds: 1500),
    this.scrollSpeed = 30.0,
    this.edgePadding = 8.0,
    this.forceMarquee = false,
    this.allowAndroidMarquee = false,
  });

  @override
  State<MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<MarqueeText> {
  late ScrollController _scrollController;
  bool _isMounted = true;
  bool _isScrolling = false;
  bool _tickerEnabled = true;
  Timer? _delayTimer;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    _isMounted = true;
    if (defaultTargetPlatform == TargetPlatform.android &&
        !widget.allowAndroidMarquee) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startScrolling();
    });
  }

  void _startScrolling() async {
    if (!_isMounted) return;

    while (_isMounted) {
      if (_isScrolling || !_tickerEnabled) {
        await _delay(const Duration(milliseconds: 160));
        continue;
      }
      if (!_scrollController.hasClients) {
        await _delay(const Duration(milliseconds: 100));
        continue;
      }

      final maxScroll = _scrollController.position.maxScrollExtent;
      if (maxScroll <= 0) {
        await _delay(const Duration(milliseconds: 500));
        continue;
      }

      // Initial pause at the start
      await _delay(widget.pauseDuration);
      if (!_isMounted ||
          _isScrolling ||
          !_tickerEnabled ||
          !_scrollController.hasClients) {
        continue;
      }

      // Scroll to end
      final duration = Duration(
        milliseconds: (maxScroll / widget.scrollSpeed * 1000).toInt(),
      );

      await _scrollController.animateTo(
        maxScroll,
        duration: duration,
        curve: Curves.linear,
      );

      if (!_isMounted) break;
      if (_isScrolling || !_tickerEnabled || !_scrollController.hasClients) {
        continue;
      }

      // Pause at the end (as requested: 1.5s)
      await _delay(widget.pauseDuration);
      if (!_isMounted) break;
      if (_isScrolling || !_tickerEnabled || !_scrollController.hasClients) {
        continue;
      }

      // Jump back to start
      _scrollController.jumpTo(0);
    }
  }

  Future<void> _delay(Duration duration) {
    if (!_isMounted) return Future<void>.value();
    final completer = Completer<void>();
    _delayTimer?.cancel();
    _delayTimer = Timer(duration, () {
      _delayTimer = null;
      if (!completer.isCompleted) {
        completer.complete();
      }
    });
    return completer.future;
  }

  @override
  void didUpdateWidget(MarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(0);
      }
    }
  }

  @override
  void dispose() {
    _isMounted = false;
    _delayTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform == TargetPlatform.android &&
        !widget.allowAndroidMarquee) {
      return Text(
        widget.text,
        style: widget.style,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    }
    _isScrolling = ScrollActivityGate.isScrollingOf(context);
    _tickerEnabled = TickerMode.valuesOf(context).enabled;
    if (_isScrolling && _scrollController.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_isMounted || !_scrollController.hasClients) return;
        _scrollController.jumpTo(0);
      });
    }
    final cs = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        bool needsMarquee = widget.forceMarquee;
        String displayText = widget.text;

        if (constraints.maxWidth < double.infinity) {
          final textPainter = TextPainter(
            text: TextSpan(text: widget.text, style: widget.style),
            textDirection: Directionality.of(context),
            maxLines: 1,
          )..layout();

          if (textPainter.width > constraints.maxWidth) {
            needsMarquee = true;
          } else if (widget.forceMarquee && textPainter.width > 0) {
            final duplicateCount =
                (constraints.maxWidth / textPainter.width).ceil() + 2;
            final spacedText = '${widget.text}        ';
            displayText = spacedText * duplicateCount;
          }
        }

        if (!needsMarquee) {
          return Text(
            widget.text,
            style: widget.style,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          );
        }

        return ShaderMask(
          shaderCallback: (Rect bounds) {
            return LinearGradient(
              colors: [
                cs.surface.withValues(alpha: 0.0),
                cs.surface,
                cs.surface,
                cs.surface.withValues(alpha: 0.0),
              ],
              stops: const [0.0, 0.05, 0.95, 1.0],
            ).createShader(bounds);
          },
          blendMode: BlendMode.dstIn,
          child: NotificationListener<ScrollNotification>(
            onNotification: (_) => true,
            child: SingleChildScrollView(
              controller: _scrollController,
              scrollDirection: Axis.horizontal,
              physics: const NeverScrollableScrollPhysics(),
              padding: EdgeInsets.symmetric(horizontal: widget.edgePadding),
              child: Text(displayText, style: widget.style),
            ),
          ),
        );
      },
    );
  }
}
