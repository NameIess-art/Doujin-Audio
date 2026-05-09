import 'dart:async';
import 'package:flutter/material.dart';

class WaterfallFlowStagger extends StatefulWidget {
  const WaterfallFlowStagger({
    super.key,
    required this.index,
    required this.child,
    this.staggerDelay = const Duration(milliseconds: 50),
    this.animationDuration = const Duration(milliseconds: 450),
  });

  final int index;
  final Widget child;
  final Duration staggerDelay;
  final Duration animationDuration;

  @override
  State<WaterfallFlowStagger> createState() => _WaterfallFlowStaggerState();
}

class _WaterfallFlowStaggerState extends State<WaterfallFlowStagger>
    with SingleTickerProviderStateMixin {
  Timer? _staggerTimer;
  late AnimationController _controller;
  late Animation<double> _opacity;
  late Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.animationDuration,
    );

    _opacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );

    _slide = Tween<Offset>(begin: const Offset(0, 0.25), end: Offset.zero).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
    );

    // Cap the stagger index to ensure items lower in the list don't wait too long.
    final staggerIndex = widget.index.clamp(0, 12);
    _staggerTimer = Timer(widget.staggerDelay * staggerIndex, () {
      if (mounted) {
        _controller.forward();
      }
    });
  }

  @override
  void dispose() {
    _staggerTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacity,
      child: SlideTransition(
        position: _slide,
        child: widget.child,
      ),
    );
  }
}
