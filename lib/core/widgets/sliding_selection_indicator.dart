import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app_transitions.dart';

class SlidingSelectionIndicator extends StatelessWidget {
  const SlidingSelectionIndicator({
    super.key,
    required this.index,
    required this.layoutKey,
    required this.builder,
    required this.child,
  });

  final int index;
  final Object layoutKey;
  final ValueWidgetBuilder<double> builder;
  final Widget child;

  static const shape = StadiumBorder();

  static Color fill(Color accent) => accent.withValues(alpha: 0.19);

  static Rect? rectAt(double position, Rect? Function(int) slotAt) {
    final lower = position.floor();
    final from = slotAt(lower);
    final to = slotAt(position.ceil());
    if (from == null || to == null) return null;
    return Rect.lerp(from, to, position - lower);
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion =
        MediaQuery.disableAnimationsOf(context) ||
        !TickerMode.valuesOf(context).enabled;
    return TweenAnimationBuilder<double>(
      key: ValueKey((layoutKey, reduceMotion)),
      tween: Tween(end: index < 0 ? 0.0 : index.toDouble()),
      duration: reduceMotion ? Duration.zero : kAppMotionFast,
      curve: Curves.easeOutCubic,
      builder: builder,
      child: child,
    );
  }
}

class SlidingSelectionPainter extends CustomPainter {
  SlidingSelectionPainter({
    required this.containerKey,
    required this.slots,
    required this.position,
    required this.accentColor,
    this.visible = true,
    this.layoutSignature,
    this.width,
    this.scrollOffset,
  }) : super(repaint: scrollOffset);

  final GlobalKey containerKey;
  final List<GlobalKey> slots;
  final double position;
  final Color accentColor;
  final bool visible;
  final Object? layoutSignature;
  final double? width;
  final ValueListenable<double>? scrollOffset;

  @override
  void paint(Canvas canvas, Size size) {
    if (!visible) return;
    final container = containerKey.currentContext?.findRenderObject();
    if (container is! RenderBox || !container.attached || !container.hasSize) {
      return;
    }

    Rect? slotAt(int index) {
      if (index < 0 || index >= slots.length) return null;
      final box = slots[index].currentContext?.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) return null;
      return box.localToGlobal(Offset.zero, ancestor: container) & box.size;
    }

    final slot = SlidingSelectionIndicator.rectAt(position, slotAt);
    if (slot == null) return;
    final rect = Rect.fromLTWH(
      slot.left,
      slot.top,
      width ?? slot.width,
      slot.height,
    );
    canvas.save();
    final scroll = scrollOffset;
    if (scroll != null) {
      final first = slotAt(0);
      if (first != null) {
        // The rail's fixed controls sit above its scroll viewport.
        final top = (first.top + scroll.value).clamp(0.0, size.height);
        canvas.clipRect(Rect.fromLTRB(0, top, size.width, size.height));
      }
    }
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(rect.shortestSide / 2)),
      Paint()..color = SlidingSelectionIndicator.fill(accentColor),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(SlidingSelectionPainter oldDelegate) =>
      oldDelegate.containerKey != containerKey ||
      oldDelegate.position != position ||
      oldDelegate.accentColor != accentColor ||
      oldDelegate.visible != visible ||
      oldDelegate.layoutSignature != layoutSignature ||
      oldDelegate.width != width ||
      oldDelegate.scrollOffset != scrollOffset ||
      !listEquals(oldDelegate.slots, slots);
}
