import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'app_transitions.dart';

/// Animates mounted entries between their measured positions in a lazy list.
class AnimatedReorder extends StatefulWidget {
  const AnimatedReorder({super.key, required this.order, required this.child});

  final List<Object> order;
  final Widget child;

  @override
  State<AnimatedReorder> createState() => _AnimatedReorderState();
}

class _AnimatedReorderState extends State<AnimatedReorder>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: kAppMotionSlow,
    value: 1,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _ReorderViewport(
    controller: _controller,
    order: widget.order,
    enabled:
        !MediaQuery.disableAnimationsOf(context) &&
        TickerMode.valuesOf(context).enabled &&
        ModalRoute.isCurrentOf(context) != false,
    child: widget.child,
  );
}

class _ReorderViewport extends SingleChildRenderObjectWidget {
  const _ReorderViewport({
    required this.controller,
    required this.order,
    required this.enabled,
    required super.child,
  });

  final AnimationController controller;
  final List<Object> order;
  final bool enabled;

  @override
  _RenderReorderViewport createRenderObject(BuildContext context) =>
      _RenderReorderViewport(controller, order);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderReorderViewport renderObject,
  ) => renderObject.update(order, enabled);
}

class _RenderReorderViewport extends RenderProxyBox {
  _RenderReorderViewport(this.controller, this._order);

  final AnimationController controller;
  List<Object> _order;
  bool _pending = false;
  final Set<_RenderReorderItem> _items = {};
  final Map<Object, Offset> _positions = {};

  double get remaining => 1 - Curves.easeOutCubic.transform(controller.value);

  void update(List<Object> order, bool enabled) {
    if (!listEquals(_order, order)) {
      // Expanding a tree or adding/removing entries owns its own size motion.
      // Only changes to the relative order of surviving entries are reorders.
      final previousIds = _order.toSet();
      final nextIds = order.toSet();
      _pending =
          enabled &&
          !listEquals(
            _order.where(nextIds.contains).toList(),
            order.where(previousIds.contains).toList(),
          );
      if (_pending) {
        // Capture before the descendants rebuild and lay out in their new order.
        // Measuring here also includes scrolling and any unfinished transition.
        _positions.clear();
        for (final item in _items) {
          if (item.hasSize) {
            _positions[item.id] =
                item.localToGlobal(Offset.zero, ancestor: this) +
                item.translation;
          }
        }
      }
      _order = List.of(order);
      markNeedsPaint();
      for (final item in _items) {
        item.markNeedsPaint();
      }
      if (_pending) controller.forward(from: 0);
    }
    if (!enabled) {
      _pending = false;
      _positions.clear();
      for (final item in _items) {
        item.delta = Offset.zero;
        item.markNeedsPaint();
        item.markNeedsSemanticsUpdate();
      }
      controller.value = 1;
    }
  }

  void _prepareReorder() {
    if (!_pending) return;
    _pending = false;
    for (final item in _items) {
      final previous = _positions[item.id];
      item.delta = previous != null && item.hasSize
          ? previous - item.localToGlobal(Offset.zero, ancestor: this)
          : Offset.zero;
      item.markNeedsSemanticsUpdate();
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    _prepareReorder();
    super.paint(context, offset);
  }
}

class AnimatedReorderItem extends SingleChildRenderObjectWidget {
  const AnimatedReorderItem({
    super.key,
    required this.id,
    required super.child,
  });

  final Object id;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderReorderItem(id);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    final item = renderObject as _RenderReorderItem;
    if (item.id != id) {
      item.id = id;
      item.delta = Offset.zero;
      item.markNeedsPaint();
      item.markNeedsSemanticsUpdate();
    }
  }
}

class _RenderReorderItem extends RenderProxyBox {
  _RenderReorderItem(this.id);

  Object id;
  Offset delta = Offset.zero;
  _RenderReorderViewport? _viewport;
  Offset get translation => delta * (_viewport?.remaining ?? 0);

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    RenderObject? ancestor = parent;
    while (ancestor != null && ancestor is! _RenderReorderViewport) {
      ancestor = ancestor.parent;
    }
    _viewport = ancestor as _RenderReorderViewport?;
    _viewport?._items.add(this);
    _viewport?.controller.addListener(_tick);
  }

  void _tick() {
    if (delta == Offset.zero) return;
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  @override
  void detach() {
    _viewport?.controller.removeListener(_tick);
    _viewport?._items.remove(this);
    _viewport = null;
    super.detach();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    _viewport?._prepareReorder();
    super.paint(context, offset + translation);
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    super.applyPaintTransform(child, transform);
    final offset = translation;
    transform.translateByDouble(offset.dx, offset.dy, 0, 1);
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) =>
      result.addWithPaintOffset(
        offset: translation,
        position: position,
        hitTest: (result, position) =>
            super.hitTest(result, position: position),
      );
}
