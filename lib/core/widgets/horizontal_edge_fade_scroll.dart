import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

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
  // Inline rows share the enclosing list's PageStorage key, not its offset.
  ScrollController? _ownedController;
  ScrollController get _controller =>
      widget.controller ??
      (_ownedController ??= ScrollController(keepScrollOffset: false));
  bool _fadeLeft = false;
  bool _fadeRight = false;
  @override
  void dispose() {
    _ownedController?.dispose();
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
    Widget buildContent(ScrollController controller) => ScrollConfiguration(
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
          child: _HorizontalEdgeMask(
            enabled: _fadeLeft || _fadeRight,
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
    );
    return defaultTargetPlatform == TargetPlatform.windows
        ? WindowsHorizontalWheelScroll(
            controller: _controller,
            builder: buildContent,
          )
        : buildContent(_controller);
  }
}

// Keep the scrollable's element and position when resizing removes overflow.
// Fully visible rows can paint directly without an offscreen shader layer.
class _HorizontalEdgeMask extends ShaderMask {
  const _HorizontalEdgeMask({
    required this.enabled,
    required super.shaderCallback,
    required super.blendMode,
    required super.child,
  });

  final bool enabled;

  @override
  RenderShaderMask createRenderObject(BuildContext context) =>
      _RenderHorizontalEdgeMask(
        enabled: enabled,
        shaderCallback: shaderCallback,
        blendMode: blendMode,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderHorizontalEdgeMask renderObject,
  ) {
    super.updateRenderObject(context, renderObject);
    renderObject.enabled = enabled;
  }
}

class _RenderHorizontalEdgeMask extends RenderShaderMask {
  _RenderHorizontalEdgeMask({
    required bool enabled,
    required super.shaderCallback,
    required super.blendMode,
  }) : _enabled = enabled;

  bool _enabled;
  set enabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    markNeedsCompositingBitsUpdate();
    markNeedsPaint();
  }

  @override
  bool get alwaysNeedsCompositing => _enabled && super.alwaysNeedsCompositing;

  @override
  void paint(PaintingContext context, Offset offset) {
    if (_enabled) {
      super.paint(context, offset);
    } else {
      layer = null;
      if (child != null) context.paintChild(child!, offset);
    }
  }
}
