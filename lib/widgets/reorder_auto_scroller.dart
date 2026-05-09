import 'dart:async';
import 'package:flutter/material.dart';

/// A wrapper that provides enhanced auto-scroll behavior for reorderable lists.
/// 
/// It implements a quadratic velocity ramp based on the distance of the pointer
/// from the viewport edges, providing a more dynamic and responsive "speed change"
/// effect during drag-to-reorder interactions.
class ReorderAutoScroller extends StatefulWidget {
  const ReorderAutoScroller({
    super.key,
    required this.scrollController,
    required this.child,
    this.isDragging = false,
    this.edgeThreshold = 100.0,
    this.maxVelocity = 1200.0,
  });

  final ScrollController scrollController;
  final Widget child;
  final bool isDragging;
  final double edgeThreshold;
  final double maxVelocity;

  @override
  State<ReorderAutoScroller> createState() => _ReorderAutoScrollerState();
}

class _ReorderAutoScrollerState extends State<ReorderAutoScroller> {
  Timer? _timer;
  double _velocity = 0;

  void _onPointerMove(PointerMoveEvent event) {
    if (!widget.isDragging) {
      if (_velocity != 0) {
        _velocity = 0;
        _stopTimer();
      }
      return;
    }

    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;

    final localPos = box.globalToLocal(event.position);
    final height = box.size.height;
    final threshold = widget.edgeThreshold;

    if (localPos.dy < threshold) {
      // Near top - Velocity increases quadratically as we get closer to the edge
      final dist = localPos.dy.clamp(0.0, threshold);
      final intensity = 1.0 - (dist / threshold);
      _velocity = -widget.maxVelocity * (intensity * intensity);
    } else if (localPos.dy > height - threshold) {
      // Near bottom
      final dist = (height - localPos.dy).clamp(0.0, threshold);
      final intensity = 1.0 - (dist / threshold);
      _velocity = widget.maxVelocity * (intensity * intensity);
    } else {
      _velocity = 0;
    }

    if (_velocity != 0 && _timer == null) {
      _startTimer();
    }
  }

  void _onPointerUp(PointerEvent event) {
    _velocity = 0;
    _stopTimer();
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 16), (timer) {
      if (_velocity == 0 || !widget.isDragging) {
        _stopTimer();
        return;
      }

      if (!widget.scrollController.hasClients) return;

      final pos = widget.scrollController.position;
      final delta = _velocity * 0.016;
      final newOffset = (pos.pixels + delta).clamp(
        pos.minScrollExtent,
        pos.maxScrollExtent,
      );

      if (newOffset != pos.pixels) {
        widget.scrollController.jumpTo(newOffset);
      }
    });
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void didUpdateWidget(ReorderAutoScroller oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.isDragging && oldWidget.isDragging) {
      _velocity = 0;
      _stopTimer();
    }
  }

  @override
  void dispose() {
    _stopTimer();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerUp,
      behavior: HitTestBehavior.translucent,
      child: widget.child,
    );
  }
}
