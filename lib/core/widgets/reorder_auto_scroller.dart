import 'package:flutter/scheduler.dart';
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

class _ReorderAutoScrollerState extends State<ReorderAutoScroller>
    with SingleTickerProviderStateMixin {
  Ticker? _ticker;
  Duration? _lastTickElapsed;
  double _velocity = 0;
  RenderBox? _dragBox;
  Offset? _pendingPointerPosition;
  bool _pointerSampleScheduled = false;

  void _onPointerMove(PointerMoveEvent event) {
    if (!widget.isDragging) {
      _stopDragActivity();
      return;
    }
    _pendingPointerPosition = event.position;
    if (_pointerSampleScheduled) return;
    _pointerSampleScheduled = true;
    SchedulerBinding.instance.scheduleFrameCallback((_) {
      _pointerSampleScheduled = false;
      if (!mounted || !widget.isDragging) return;
      final position = _pendingPointerPosition;
      if (position == null) return;
      _updateVelocity(position);
    });
    SchedulerBinding.instance.scheduleFrame();
  }

  void _updateVelocity(Offset globalPosition) {
    final box = _dragBox ??= context.findRenderObject() as RenderBox?;
    if (box == null) return;

    final localPos = box.globalToLocal(globalPosition);
    final height = box.size.height;

    // Define the usable content area height
    final contentHeight =
        height - widget.contentMarginTop - widget.contentMarginBottom;
    if (contentHeight <= 0) {
      _velocity = 0;
      _stopTicker();
      return;
    }

    // Position relative to the content area top
    final relativeDy = localPos.dy - widget.contentMarginTop;

    // Trigger in the top 1/3 and bottom 1/3 of the content area
    final threshold = contentHeight / 3.0;

    if (relativeDy < threshold) {
      // Near top of content area or above it
      double intensity = 1.0;
      if (relativeDy >= 0) {
        intensity = 1.0 - (relativeDy / threshold);
      }
      // Quadratic velocity ramp as requested
      final curve = intensity * intensity;
      _velocity = -widget.maxVelocity * curve;
    } else if (relativeDy > contentHeight - threshold) {
      // Near bottom of content area or below it
      double intensity = 1.0;
      if (relativeDy <= contentHeight) {
        final distFromBottom = contentHeight - relativeDy;
        intensity = 1.0 - (distFromBottom / threshold);
      }
      // Quadratic velocity ramp as requested
      final curve = intensity * intensity;
      _velocity = widget.maxVelocity * curve;
    } else {
      _velocity = 0;
      _stopTicker();
    }

    if (_velocity != 0 && _ticker?.isActive != true) {
      _startTicker();
    }
  }

  void _onPointerUp(PointerEvent event) {
    _stopDragActivity();
  }

  void _startTicker() {
    _ticker ??= createTicker(_handleTick);
    _lastTickElapsed = null;
    _ticker!.start();
  }

  void _handleTick(Duration elapsed) {
    if (_velocity == 0 || !widget.isDragging) {
      _stopTicker();
      return;
    }

    if (!widget.scrollController.hasClients) return;
    final previousElapsed = _lastTickElapsed;
    _lastTickElapsed = elapsed;
    final deltaSeconds = previousElapsed == null
        ? 0.016
        : (elapsed - previousElapsed).inMicroseconds /
              Duration.microsecondsPerSecond;
    if (deltaSeconds <= 0) return;

    final pos = widget.scrollController.position;
    final delta = _velocity * deltaSeconds;
    final newOffset = (pos.pixels + delta).clamp(
      pos.minScrollExtent,
      pos.maxScrollExtent,
    );

    if (newOffset != pos.pixels) {
      widget.scrollController.jumpTo(newOffset);
    }
  }

  void _stopDragActivity() {
    _pendingPointerPosition = null;
    _dragBox = null;
    _velocity = 0;
    _stopTicker();
  }

  void _stopTicker() {
    _ticker?.stop();
    _lastTickElapsed = null;
  }

  @override
  void didUpdateWidget(ReorderAutoScroller oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.isDragging && oldWidget.isDragging) {
      _stopDragActivity();
    } else if (widget.isDragging && !oldWidget.isDragging) {
      _dragBox = null;
    }
  }

  @override
  void dispose() {
    _stopDragActivity();
    _ticker?.dispose();
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
