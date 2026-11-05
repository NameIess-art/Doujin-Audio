import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final sessionCoverTargetsProvider = Provider(
  (ref) => <SessionCoverAnchorState>{},
);

enum SessionCoverLocation { playlist, dock, routedDock }

/// Marks the artwork itself, inside any progress ring or card controls.
class SessionCoverAnchor extends ConsumerStatefulWidget {
  const SessionCoverAnchor({
    super.key,
    required this.sessionId,
    required this.radius,
    required this.child,
    this.location,
    this.enabled = true,
    this.imageKey,
  });

  final String sessionId;
  final double radius;
  final Widget child;
  final SessionCoverLocation? location;
  final bool enabled;
  final Key? imageKey;

  bool get isDock =>
      location == SessionCoverLocation.dock ||
      location == SessionCoverLocation.routedDock;

  @override
  ConsumerState<SessionCoverAnchor> createState() => SessionCoverAnchorState();
}

class SessionCoverAnchorState extends ConsumerState<SessionCoverAnchor> {
  late final Set<SessionCoverAnchorState> _targets;
  _CoverAnchorBox? _renderBox;
  _CoverAnchorBox? get _box =>
      _renderBox ??= context.findRenderObject() as _CoverAnchorBox?;

  @override
  void initState() {
    super.initState();
    _targets = ref.read(sessionCoverTargetsProvider);
    if (widget.location != null) _targets.add(this);
  }

  @override
  void didUpdateWidget(covariant SessionCoverAnchor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.location != oldWidget.location) {
      if (widget.location != null) {
        _targets.add(this);
      } else {
        _targets.remove(this);
      }
    }
  }

  @override
  void dispose() {
    _targets.remove(this);
    super.dispose();
  }

  Rect? bounds({RenderObject? within}) {
    if (!mounted || !widget.enabled) return null;
    final box = _box;
    if (box == null || !box.attached || !box.hasSize || box.size.isEmpty) {
      return null;
    }
    final rect = MatrixUtils.transformRect(
      box.getTransformTo(null),
      Offset.zero & box.size,
    );
    if (!rect.isFinite || rect.isEmpty) return null;
    // A PageView can keep adjacent cards laid out outside its viewport.
    for (RenderObject child = box; child.parent != null;) {
      final parent = child.parent!;
      if (parent == within) break;
      if (!parent.paintsChild(child)) return null;
      final clip = parent.describeApproximatePaintClip(child);
      if (clip != null) {
        final visible = MatrixUtils.transformRect(
          parent.getTransformTo(null),
          clip,
        );
        if (!visible.inflate(0.5).contains(rect.topLeft) ||
            !visible.inflate(0.5).contains(rect.bottomRight)) {
          return null;
        }
      }
      child = parent;
    }
    return rect;
  }

  ui.Image? get decodedImage {
    final box = _box;
    if (box == null || !widget.enabled) return null;
    final imageKey = widget.imageKey;
    if (imageKey == null) return _decodedImageBelow(box);
    RenderObject? imageBox;
    void visit(Element element) {
      if (imageBox != null) return;
      if (element.widget.key == imageKey) {
        imageBox = element.findRenderObject();
        return;
      }
      element.visitChildren(visit);
    }

    context.visitChildElements(visit);
    return imageBox == null ? null : _decodedImageBelow(imageBox!);
  }

  ui.Image? _decodedImageBelow(RenderObject root) {
    if (root is RenderImage) return root.image;
    ui.Image? image;
    root.visitChildren((child) {
      if (image == null && root.paintsChild(child)) {
        image = _decodedImageBelow(child);
      }
    });
    return image;
  }

  void setInFlight(bool value) {
    _renderBox?.hidden = value;
  }

  @override
  Widget build(BuildContext context) => _CoverAnchor(child: widget.child);
}

SessionCoverAnchorState? findSessionCoverAnchor(
  BuildContext origin,
  String sessionId,
) {
  SessionCoverAnchorState? anchor;
  void visit(Element element) {
    if (anchor != null) return;
    if (element case StatefulElement(
      state: final SessionCoverAnchorState state,
    )) {
      if (state.widget.sessionId == sessionId) anchor = state;
      return;
    }
    element.visitChildren(visit);
  }

  origin.visitChildElements(visit);
  return anchor;
}

class _CoverAnchor extends SingleChildRenderObjectWidget {
  const _CoverAnchor({required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => _CoverAnchorBox();
}

class _CoverAnchorBox extends RenderProxyBox {
  bool _hidden = false;

  set hidden(bool value) {
    if (_hidden == value) return;
    _hidden = value;
    if (attached) markNeedsPaint();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (!_hidden) super.paint(context, offset);
  }
}

class SessionCoverFlight extends CustomPainter {
  SessionCoverFlight({
    required this.image,
    required this.from,
    required this.to,
    required this.fromRadius,
    required this.toRadius,
    required this.progress,
    required this.reverse,
  }) : super(repaint: progress);

  final ui.Image image;
  final Rect from;
  final Rect to;
  final double fromRadius;
  final double toRadius;
  final Animation<double> progress;
  final bool reverse;

  @override
  void paint(Canvas canvas, Size size) {
    final t = reverse ? 1 - progress.value : progress.value;
    final bounds = Rect.lerp(from, to, t)!;
    final radius = ui.lerpDouble(fromRadius, toRadius, t)!;
    canvas.save();
    canvas.clipRRect(RRect.fromRectAndRadius(bounds, Radius.circular(radius)));
    paintImage(canvas: canvas, rect: bounds, image: image, fit: BoxFit.cover);
    canvas.restore();
  }

  @override
  bool shouldRepaint(SessionCoverFlight oldDelegate) =>
      oldDelegate.image != image ||
      oldDelegate.from != from ||
      oldDelegate.to != to ||
      oldDelegate.fromRadius != fromRadius ||
      oldDelegate.toRadius != toRadius ||
      oldDelegate.reverse != reverse ||
      oldDelegate.progress != progress;
}
