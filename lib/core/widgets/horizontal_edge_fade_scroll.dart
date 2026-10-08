import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'windows_horizontal_wheel_scroll.dart';

class HorizontalEdgeFadeScroll extends StatefulWidget {
  const HorizontalEdgeFadeScroll({
    super.key,
    required this.builder,
    this.controller,
    this.deferDragAtEdges = false,
  });

  final Widget Function(ScrollController controller) builder;
  final ScrollController? controller;
  final bool deferDragAtEdges;

  @override
  State<HorizontalEdgeFadeScroll> createState() =>
      _HorizontalEdgeFadeScrollState();
}

class _HorizontalEdgeFadeScrollState extends State<HorizontalEdgeFadeScroll> {
  // Inline rows share the enclosing list's PageStorage key, not its offset.
  final _ownedController = ScrollController(keepScrollOffset: false);
  ScrollController get _controller => widget.controller ?? _ownedController;
  bool _fadeLeft = false;
  bool _fadeRight = false;
  Drag? _drag;
  ScrollHoldController? _hold;

  bool _canDrag(double delta) {
    if (!_controller.hasClients) return false;
    final position = _controller.position;
    final scrollDelta = position.axisDirection == AxisDirection.left
        ? delta
        : -delta;
    return scrollDelta > 0
        ? position.extentAfter > 0
        : scrollDelta < 0 && position.extentBefore > 0;
  }

  void _cancelDrag() {
    _hold?.cancel();
    _drag?.cancel();
  }

  @override
  void dispose() {
    _ownedController.dispose();
    super.dispose();
  }

  void _updateEdges(ScrollMetrics metrics) {
    if (metrics.axis != Axis.horizontal) return;
    final reversed = metrics.axisDirection == AxisDirection.left;
    final fadeLeft =
        (reversed ? metrics.extentAfter : metrics.extentBefore) > 0.5;
    final fadeRight =
        (reversed ? metrics.extentBefore : metrics.extentAfter) > 0.5;
    if (_fadeLeft == fadeLeft && _fadeRight == fadeRight) return;
    setState(() {
      _fadeLeft = fadeLeft;
      _fadeRight = fadeRight;
    });
  }

  @override
  Widget build(BuildContext context) {
    final content = WindowsHorizontalWheelScroll(
      controller: _controller,
      builder: (controller) => ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(
          dragDevices: widget.deferDragAtEdges
              ? const <PointerDeviceKind>{}
              : PointerDeviceKind.values.toSet(),
          scrollbars: false,
        ),
        child: NotificationListener<ScrollMetricsNotification>(
          onNotification: (notification) {
            if (notification.depth == 0) _updateEdges(notification.metrics);
            return false;
          },
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification.depth != 0) return false;
              _updateEdges(notification.metrics);
              return true;
            },
            child: ShaderMask(
              blendMode: BlendMode.dstIn,
              shaderCallback: (bounds) => LinearGradient(
                colors: [
                  _fadeLeft ? Colors.transparent : Colors.black,
                  Colors.black,
                  Colors.black,
                  _fadeRight ? Colors.transparent : Colors.black,
                ],
                stops: const [0, 0.06, 0.94, 1],
              ).createShader(bounds),
              child: widget.builder(controller),
            ),
          ),
        ),
      ),
    );
    if (!widget.deferDragAtEdges) return content;
    return RawGestureDetector(
      gestures: {
        _EdgeAwareHorizontalDragGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<
              _EdgeAwareHorizontalDragGestureRecognizer
            >(
              () => _EdgeAwareHorizontalDragGestureRecognizer(debugOwner: this),
              (recognizer) => recognizer
                ..gestureSettings = MediaQuery.maybeGestureSettingsOf(context)
                ..onlyAcceptDragOnThreshold = true
                ..canDrag = _canDrag
                ..onDown = (_) {
                  _hold = _controller.position.hold(() => _hold = null);
                }
                ..onStart = (details) {
                  _drag = _controller.position.drag(
                    details,
                    () => _drag = null,
                  );
                  _hold = null;
                }
                ..onUpdate = (details) {
                  _drag?.update(details);
                }
                ..onEnd = (details) {
                  _drag?.end(details);
                }
                ..onCancel = _cancelDrag,
            ),
      },
      child: content,
    );
  }
}

// Only accept a drag when it can move the text in that direction.
// The enclosing card can then win outward drags at either edge.
class _EdgeAwareHorizontalDragGestureRecognizer
    extends HorizontalDragGestureRecognizer {
  _EdgeAwareHorizontalDragGestureRecognizer({super.debugOwner});

  bool Function(double delta)? canDrag;
  double _delta = 0;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _delta = 0;
    super.addAllowedPointer(event);
  }

  @override
  void addAllowedPointerPanZoom(PointerPanZoomStartEvent event) {
    _delta = 0;
    super.addAllowedPointerPanZoom(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerMoveEvent) _delta += event.localDelta.dx;
    if (event is PointerPanZoomUpdateEvent) _delta += event.localPanDelta.dx;
    super.handleEvent(event);
  }

  @override
  bool hasSufficientGlobalDistanceToAccept(
    PointerDeviceKind pointerDeviceKind,
    double? deviceTouchSlop,
  ) =>
      super.hasSufficientGlobalDistanceToAccept(
        pointerDeviceKind,
        deviceTouchSlop,
      ) &&
      canDrag!(_delta);
}
