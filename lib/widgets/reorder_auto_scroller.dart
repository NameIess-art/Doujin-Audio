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
    this.contentMarginTop = 0.0,
    this.contentMarginBottom = 0.0,
    this.maxVelocity = 1800.0,
  });

  final ScrollController scrollController;
  final Widget child;
  final bool isDragging;

  /// The distance from the top of this widget to the start of the visible content area
  /// (e.g., the bottom edge of the title bar).
  final double contentMarginTop;

  /// The distance from the bottom of this widget to the end of the visible content area
  /// (e.g., the top edge of the playback card).
  final double contentMarginBottom;

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
    
    // Define the usable content area height
    final contentHeight = height - widget.contentMarginTop - widget.contentMarginBottom;
    if (contentHeight <= 0) {
      _velocity = 0;
      return;
    }

    // Position relative to the content area top
    final relativeDy = localPos.dy - widget.contentMarginTop;
    
    // Trigger in the top 1/3 and bottom 1/3 of the content area
    final threshold = contentHeight / 3.0;

    if (relativeDy >= 0 && relativeDy < threshold) {
      // Near top of content area
      final intensity = 1.0 - (relativeDy / threshold);
      // Quadratic velocity ramp as requested
      final curve = intensity * intensity;
      _velocity = -widget.maxVelocity * curve;
    } else if (relativeDy > contentHeight - threshold && relativeDy <= contentHeight) {
      // Near bottom of content area
      final distFromBottom = contentHeight - relativeDy;
      final intensity = 1.0 - (distFromBottom / threshold);
      // Quadratic velocity ramp as requested
      final curve = intensity * intensity;
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
