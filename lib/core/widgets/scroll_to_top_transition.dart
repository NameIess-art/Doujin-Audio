import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Cross-fades the outgoing viewport while the same list returns near its top.
class ScrollToTopTransition extends StatefulWidget {
  const ScrollToTopTransition({
    super.key,
    required this.controller,
    required this.child,
  });

  final ScrollController Function() controller;
  final Widget child;

  @override
  State<ScrollToTopTransition> createState() => ScrollToTopTransitionState();
}

class ScrollToTopTransitionState extends State<ScrollToTopTransition> {
  final _boundaryKey = GlobalKey();
  ui.Image? _snapshot;
  ScrollPosition? _position;
  ScrollController? _activeController;
  ScrollPosition? _panZoomPosition;
  Size? _layoutSize;
  EdgeInsets _snapshotInsets = EdgeInsets.zero;
  double _start = 0;
  double _top = 0;
  int _generation = 0;
  bool _pending = false;

  Future<void> scrollToTop() async {
    if (_pending || _snapshot != null) return;
    final controller = widget.controller();
    if (!controller.hasClients) return;
    final position = controller.position;
    final offset = position.pixels;
    _position = position;
    _activeController = controller;
    _pending = true;
    final generation = ++_generation;
    controller.jumpTo(offset);

    // Capture a painted, stationary frame. The sync API returns an image handle
    // immediately and rasterizes on the raster thread, as SnapshotWidget does.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || generation != _generation) return;
    _pending = false;
    if (!controller.hasClients ||
        !identical(controller.position, position) ||
        position.pixels != offset) {
      cancel();
      return;
    }
    final boundary =
        _boundaryKey.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
    if (boundary.size.isEmpty) {
      cancel();
      return;
    }

    // Keep the live scrollbar outside the outgoing image, including hover width.
    final theme = ScrollbarTheme.of(context);
    final thickness =
        theme.thickness?.resolve({WidgetState.hovered, WidgetState.dragged}) ??
        8;
    final margin = thickness + (theme.crossAxisMargin ?? 0);
    final padding = MediaQuery.paddingOf(context);
    _snapshotInsets = Directionality.of(context) == TextDirection.rtl
        ? EdgeInsets.only(left: margin + padding.left)
        : EdgeInsets.only(right: margin + padding.right);
    final bounds = Offset.zero & boundary.size;
    final ratio = math.min(
      math.min(MediaQuery.devicePixelRatioOf(context), 2.0),
      math.sqrt(2000000 / (bounds.width * bounds.height)),
    );
    final image = boundary.toImageSync(pixelRatio: ratio);
    _top = position.minScrollExtent;
    _start = _top + position.viewportDimension * 2;
    setState(() => _snapshot = image);
    position.jumpTo(_start);
    await position.animateTo(
      _top,
      duration: const Duration(milliseconds: 480),
      curve: Curves.easeInOutCubic,
    );
    if (mounted && generation == _generation) cancel();
  }

  void cancel({bool notify = true}) {
    _generation++;
    _pending = false;
    _position = null;
    _activeController = null;
    _panZoomPosition = null;
    final image = _snapshot;
    _snapshot = null;
    image?.dispose();
    if (notify && image != null) setState(() {});
  }

  void _interrupt({bool notify = true}) {
    final position = _position;
    final controller = _activeController;
    cancel(notify: notify);
    if (position != null &&
        controller != null &&
        controller.hasClients &&
        identical(controller.position, position)) {
      position.jumpTo(position.pixels);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!TickerMode.valuesOf(context).enabled ||
        MediaQuery.disableAnimationsOf(context)) {
      _interrupt(notify: false);
    }
  }

  @override
  void didUpdateWidget(ScrollToTopTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_activeController != null &&
        !identical(_activeController, widget.controller())) {
      _interrupt(notify: false);
    }
  }

  @override
  void dispose() {
    cancel(notify: false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final size = constraints.biggest;
      if (_layoutSize != null && size != _layoutSize) {
        _interrupt(notify: false);
      }
      _layoutSize = size;
      return _buildContent(context);
    },
  );

  Widget _buildContent(BuildContext context) {
    final image = _snapshot;
    final position = _position;
    return Listener(
      onPointerDown: (_) => _interrupt(),
      onPointerSignal: (event) {
        final coveredPosition = _snapshot == null ? null : _position;
        _interrupt();
        if (event is PointerScrollEvent && coveredPosition != null) {
          GestureBinding.instance.pointerSignalResolver.register(event, (_) {
            if (mounted &&
                widget.controller().hasClients &&
                identical(widget.controller().position, coveredPosition)) {
              coveredPosition.pointerScroll(event.scrollDelta.dy);
            }
          });
        }
      },
      onPointerPanZoomStart: (_) {
        final coveredPosition = _snapshot == null ? null : _position;
        _interrupt();
        _panZoomPosition = coveredPosition;
      },
      onPointerPanZoomUpdate: (event) {
        final position = _panZoomPosition;
        if (position != null &&
            widget.controller().hasClients &&
            identical(widget.controller().position, position)) {
          position.pointerScroll(-event.panDelta.dy);
        }
      },
      onPointerPanZoomEnd: (_) => _panZoomPosition = null,
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          RepaintBoundary(key: _boundaryKey, child: widget.child),
          if (image != null && position != null)
            Positioned.fill(
              // Consume a touch on the old image so it cannot activate a new
              // row underneath. The outer listener cancels the motion at once.
              child: ClipRect(
                clipper: _SnapshotContentClipper(_snapshotInsets),
                child: AbsorbPointer(
                  child: AnimatedBuilder(
                    animation: position,
                    child: ColoredBox(
                      color: Theme.of(context).colorScheme.surface,
                      child: RawImage(image: image, fit: BoxFit.fill),
                    ),
                    builder: (context, child) {
                      final distance = (_start - position.pixels).clamp(
                        0.0,
                        _start - _top,
                      );
                      final progress = (distance / (_start - _top) / 0.8).clamp(
                        0.0,
                        1.0,
                      );
                      return Transform.translate(
                        offset: Offset(0, distance),
                        child: Opacity(
                          opacity: 1 - Curves.easeInOut.transform(progress),
                          child: child,
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SnapshotContentClipper extends CustomClipper<Rect> {
  const _SnapshotContentClipper(this.insets);

  final EdgeInsets insets;

  @override
  Rect getClip(Size size) => insets.deflateRect(Offset.zero & size);

  @override
  bool shouldReclip(_SnapshotContentClipper oldClipper) =>
      insets != oldClipper.insets;
}
