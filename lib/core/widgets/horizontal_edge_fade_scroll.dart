import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'windows_horizontal_wheel_scroll.dart';

class HorizontalEdgeFadeScroll extends StatefulWidget {
  const HorizontalEdgeFadeScroll({
    super.key,
    required this.builder,
    this.controller,
  });

  final Widget Function(ScrollController controller) builder;
  final ScrollController? controller;

  @override
  State<HorizontalEdgeFadeScroll> createState() =>
      _HorizontalEdgeFadeScrollState();
}

class _HorizontalEdgeFadeScrollState extends State<HorizontalEdgeFadeScroll> {
  final _ownedController = ScrollController();
  ScrollController get _controller => widget.controller ?? _ownedController;
  bool _fadeLeft = false;
  bool _fadeRight = false;

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
    return WindowsHorizontalWheelScroll(
      controller: _controller,
      builder: (controller) => ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(
          dragDevices: PointerDeviceKind.values.toSet(),
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
  }
}
