import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'app_transitions.dart';

/// Animates mounted entries between their measured positions in a lazy list.
class AnimatedReorder extends StatefulWidget {
  const AnimatedReorder({super.key, required this.order, required this.child});

  final List<Object> order;
  final Widget child;

  static Animation<double>? animationOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_ReorderAnimationScope>()
      ?.animation;

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
  Widget build(BuildContext context) => _ReorderAnimationScope(
    animation: _controller,
    child: _ReorderViewport(
      controller: _controller,
      order: widget.order,
      enabled:
          !MediaQuery.disableAnimationsOf(context) &&
          TickerMode.valuesOf(context).enabled &&
          ModalRoute.isCurrentOf(context) != false,
      child: widget.child,
    ),
  );
}

class _ReorderAnimationScope extends InheritedWidget {
  const _ReorderAnimationScope({required this.animation, required super.child});

  final Animation<double> animation;

  @override
  bool updateShouldNotify(_ReorderAnimationScope oldWidget) =>
      animation != oldWidget.animation;
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

  static bool _hasRelativeOrderChange(
    List<Object> previous,
    List<Object> next,
  ) {
    final nextIds = next.toSet();
    final previousIds = previous.toSet();
    var i = 0;
    var j = 0;
    while (i < previous.length && j < next.length) {
      while (i < previous.length && !nextIds.contains(previous[i])) {
        i++;
      }
      while (j < next.length && !previousIds.contains(next[j])) {
        j++;
      }
      if (i < previous.length && j < next.length) {
        if (previous[i] != next[j]) return true;
        i++;
        j++;
      }
    }
    while (i < previous.length && !nextIds.contains(previous[i])) {
      i++;
    }
    while (j < next.length && !previousIds.contains(next[j])) {
      j++;
    }
    return i < previous.length || j < next.length;
  }

  void _settleImmediately() {
    _pending = false;
    _positions.clear();
    for (final item in _items) {
      if (item.delta == Offset.zero) continue;
      item.delta = Offset.zero;
      item.markNeedsPaint();
      item.markNeedsSemanticsUpdate();
    }
    controller.value = 1;
  }

  void update(List<Object> order, bool enabled) {
    if (identical(_order, order)) {
      if (!enabled && (controller.value != 1 || _pending)) {
        _settleImmediately();
      }
      return;
    }
    if (!listEquals(_order, order)) {
      // Expanding a tree or adding/removing entries owns its own size motion.
      // Only changes to the relative order of surviving entries are reorders.
      _pending = enabled && _hasRelativeOrderChange(_order, order);
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
      _order = order;
      if (_pending) {
        markNeedsPaint();
        for (final item in _items) {
          item.markNeedsPaint();
        }
        controller.forward(from: 0);
      }
    } else {
      _order = order;
    }
    // A tab transition mutes this list even when no reorder is running.
    // Keep the retained rows paintable without invalidating every row.
    if (!enabled && (controller.value != 1 || _pending)) {
      _settleImmediately();
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
    _viewport?.controller.addStatusListener(_handleStatus);
  }

  void _tick() {
    if (delta == Offset.zero) return;
    markNeedsPaint();
  }

  void _handleStatus(AnimationStatus status) {
    if ((status == AnimationStatus.completed ||
            status == AnimationStatus.dismissed) &&
        delta != Offset.zero) {
      delta = Offset.zero;
      markNeedsSemanticsUpdate();
    }
  }

  @override
  void detach() {
    _viewport?.controller.removeListener(_tick);
    _viewport?.controller.removeStatusListener(_handleStatus);
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
