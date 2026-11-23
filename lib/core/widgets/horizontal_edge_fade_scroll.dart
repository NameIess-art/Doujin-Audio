import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'windows_horizontal_wheel_scroll.dart';
import 'windows_smooth_scroll_controller.dart';

class HorizontalEdgeFadeScroll extends StatefulWidget {
  const HorizontalEdgeFadeScroll({
    super.key,
    required this.builder,
    this.controller,
    this.absorbScrollNotifications = false,
  });

  final Widget Function(ScrollController controller) builder;
  final ScrollController? controller;
  final bool absorbScrollNotifications;

  @override
  State<HorizontalEdgeFadeScroll> createState() =>
      _HorizontalEdgeFadeScrollState();
}

class _HorizontalEdgeFadeScrollState extends State<HorizontalEdgeFadeScroll> {
  // Inline rows share the enclosing list's PageStorage key, not its offset.
  ScrollController? _ownedController;
  ScrollController get _controller =>
      widget.controller ??
      (_ownedController ??= WindowsSmoothScrollController(
        keepScrollOffset: false,
      ));
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
            return widget.absorbScrollNotifications;
          },
          child: _HorizontalEdgeMask(
            enabled: _fadeLeft || _fadeRight,
            fadeLeft: _fadeLeft,
            fadeRight: _fadeRight,
            blendMode: BlendMode.dstIn,
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

const _edgeMaskStops = <double>[0, 0.06, 0.94, 1];
const _neitherEdgeGradient = LinearGradient(
  colors: [Colors.black, Colors.black, Colors.black, Colors.black],
  stops: _edgeMaskStops,
);
const _leftEdgeGradient = LinearGradient(
  colors: [Colors.transparent, Colors.black, Colors.black, Colors.black],
  stops: _edgeMaskStops,
);
const _rightEdgeGradient = LinearGradient(
  colors: [Colors.black, Colors.black, Colors.black, Colors.transparent],
  stops: _edgeMaskStops,
);
const _bothEdgeGradient = LinearGradient(
  colors: [Colors.transparent, Colors.black, Colors.black, Colors.transparent],
  stops: _edgeMaskStops,
);

Shader _createNeitherEdgeShader(Rect bounds) =>
    _neitherEdgeGradient.createShader(bounds);
Shader _createLeftEdgeShader(Rect bounds) =>
    _leftEdgeGradient.createShader(bounds);
Shader _createRightEdgeShader(Rect bounds) =>
    _rightEdgeGradient.createShader(bounds);
Shader _createBothEdgeShader(Rect bounds) =>
    _bothEdgeGradient.createShader(bounds);

ShaderCallback _edgeShaderCallbackFor(bool fadeLeft, bool fadeRight) =>
    switch ((fadeLeft, fadeRight)) {
      (false, false) => _createNeitherEdgeShader,
      (true, false) => _createLeftEdgeShader,
      (false, true) => _createRightEdgeShader,
      (true, true) => _createBothEdgeShader,
    };

// Keep the scrollable's element and position when resizing removes overflow.
// Fully visible rows can paint directly without an offscreen shader layer.
class _HorizontalEdgeMask extends ShaderMask {
  _HorizontalEdgeMask({
    required this.enabled,
    required this.fadeLeft,
    required this.fadeRight,
    required super.blendMode,
    required super.child,
  }) : super(shaderCallback: _edgeShaderCallbackFor(fadeLeft, fadeRight));

  final bool enabled;
  final bool fadeLeft;
  final bool fadeRight;

  @override
  RenderShaderMask createRenderObject(BuildContext context) =>
      _RenderHorizontalEdgeMask(
        enabled: enabled,
        fadeLeft: fadeLeft,
        fadeRight: fadeRight,
        shaderCallback: shaderCallback,
        blendMode: blendMode,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderHorizontalEdgeMask renderObject,
  ) {
    renderObject
      ..blendMode = blendMode
      ..enabled = enabled
      ..fadeLeft = fadeLeft
      ..fadeRight = fadeRight;
  }
}

class _RenderHorizontalEdgeMask extends RenderShaderMask {
  _RenderHorizontalEdgeMask({
    required bool enabled,
    required bool fadeLeft,
    required bool fadeRight,
    required super.shaderCallback,
    required super.blendMode,
  }) : _enabled = enabled,
       _fadeLeft = fadeLeft,
       _fadeRight = fadeRight;

  bool _enabled;
  bool _fadeLeft;
  bool _fadeRight;
  Shader? _cachedShader;
  Size? _cachedSize;
  bool? _cachedFadeLeft;
  bool? _cachedFadeRight;

  set enabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    markNeedsCompositingBitsUpdate();
    markNeedsPaint();
  }

  set fadeLeft(bool value) {
    if (_fadeLeft == value) return;
    _fadeLeft = value;
    _cachedShader = null;
    markNeedsPaint();
  }

  set fadeRight(bool value) {
    if (_fadeRight == value) return;
    _fadeRight = value;
    _cachedShader = null;
    markNeedsPaint();
  }

  @override
  bool get alwaysNeedsCompositing => _enabled && super.alwaysNeedsCompositing;

  @override
  void paint(PaintingContext context, Offset offset) {
    final content = child;
    if (!_enabled || content == null) {
      layer = null;
      if (content != null) context.paintChild(content, offset);
      return;
    }

    // Rasterization can round the viewport clip and the mask rectangle
    // differently. Cover the boundary pixels without moving the gradient.
    const overlap = 1.0;
    if (_cachedShader == null ||
        _cachedSize != size ||
        _cachedFadeLeft != _fadeLeft ||
        _cachedFadeRight != _fadeRight) {
      _cachedShader = _edgeShaderCallbackFor(
        _fadeLeft,
        _fadeRight,
      )(const Offset(overlap, overlap) & size);
      _cachedSize = size;
      _cachedFadeLeft = _fadeLeft;
      _cachedFadeRight = _fadeRight;
    }
    layer ??= ShaderMaskLayer();
    layer!
      ..shader = _cachedShader
      ..maskRect = (offset & size).inflate(overlap)
      ..blendMode = blendMode;
    context.pushLayer(layer!, (context, offset) {
      context.paintChild(content, offset);
    }, offset);
  }
}
