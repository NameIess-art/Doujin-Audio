import 'dart:async';
import 'package:flutter/material.dart';

class MarqueeText extends StatefulWidget {
  final String text;
  final TextStyle? style;
  final Duration pauseDuration;
  final double scrollSpeed;

  const MarqueeText({
    super.key,
    required this.text,
    this.style,
    this.pauseDuration = const Duration(milliseconds: 1500),
    this.scrollSpeed = 30.0,
  });

  @override
  State<MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<MarqueeText> {
  late ScrollController _scrollController;
  bool _isMounted = true;

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
        await Future<void>.delayed(const Duration(milliseconds: 100));
        continue;
      }

      final maxScroll = _scrollController.position.maxScrollExtent;
      if (maxScroll <= 0) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        continue;
      }

      // Initial pause at the start
      await Future<void>.delayed(widget.pauseDuration);
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
      await Future<void>.delayed(widget.pauseDuration);
      if (!_isMounted || !_scrollController.hasClients) break;

      // Jump back to start
      _scrollController.jumpTo(0);
    }
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
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      controller: _scrollController,
      scrollDirection: Axis.horizontal,
      physics: const NeverScrollableScrollPhysics(),
      child: Padding(
        padding: const EdgeInsets.only(right: 48),
        child: Text(widget.text, style: widget.style),
      ),
    );
  }
}
