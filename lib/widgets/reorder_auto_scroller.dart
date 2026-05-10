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
    this.topTriggerOffset = 100.0,
    this.bottomTriggerOffset = 100.0,
    this.maxVelocity = 1500.0,
  });

  final ScrollController scrollController;
  final Widget child;
  final bool isDragging;
  final double topTriggerOffset;
  final double bottomTriggerOffset;
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
    
    // Use configurable offsets for triggering scroll
    final topThreshold = widget.topTriggerOffset;
    final bottomThreshold = widget.bottomTriggerOffset;

    if (localPos.dy < topThreshold) {
      // Near top - Using a curve that's more responsive at the boundary to avoid "dead" feel
      final dist = localPos.dy.clamp(0.0, topThreshold);
      final intensity = 1.0 - (dist / topThreshold);
      // Mix linear and cubic: more immediate response than pure quadratic
      final curve = intensity * 0.4 + intensity * intensity * intensity * 0.6;
      _velocity = -widget.maxVelocity * curve;
    } else if (localPos.dy > height - bottomThreshold) {
      // Near bottom
      final dist = (height - localPos.dy).clamp(0.0, bottomThreshold);
      final intensity = 1.0 - (dist / bottomThreshold);
      final curve = intensity * 0.4 + intensity * intensity * intensity * 0.6;
      _velocity = widget.maxVelocity * curve;
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
