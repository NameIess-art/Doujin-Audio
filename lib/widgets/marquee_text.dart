import 'dart:async';
import 'package:flutter/material.dart';

class MarqueeText extends StatefulWidget {
  final String text;
  final TextStyle? style;
  final Duration pauseDuration;
  final double scrollSpeed;
  final double edgePadding;

  const MarqueeText({
    super.key,
    required this.text,
    this.style,
    this.pauseDuration = const Duration(milliseconds: 1500),
    this.scrollSpeed = 30.0,
    this.edgePadding = 8.0,
  });

  @override
  State<MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<MarqueeText> {
  late ScrollController _scrollController;
  bool _isMounted = true;
  Timer? _delayTimer;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    _isMounted = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startScrolling();
    });
  }

  void _startScrolling() async {
    if (!_isMounted) return;

    while (_isMounted) {
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
      if (!_isMounted || !_scrollController.hasClients) break;

      // Scroll to end
      final duration = Duration(
        milliseconds: (maxScroll / widget.scrollSpeed * 1000).toInt(),
      );

      await _scrollController.animateTo(
        maxScroll,
        duration: duration,
        curve: Curves.linear,
      );

      if (!_isMounted || !_scrollController.hasClients) break;

      // Pause at the end (as requested: 1.5s)
      await _delay(widget.pauseDuration);
      if (!_isMounted || !_scrollController.hasClients) break;

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
    final cs = Theme.of(context).colorScheme;
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
      child: SingleChildScrollView(
        controller: _scrollController,
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.symmetric(horizontal: widget.edgePadding),
        child: Text(widget.text, style: widget.style),
      ),
    );
  }
}
