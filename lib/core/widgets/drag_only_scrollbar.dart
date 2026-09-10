import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

class DragOnlyScrollbar extends RawScrollbar {
  const DragOnlyScrollbar({super.key, super.controller, required super.child})
    : super(thumbVisibility: true, interactive: true);

  @override
  RawScrollbarState<DragOnlyScrollbar> createState() =>
      _DragOnlyScrollbarState();
}

class _DragOnlyScrollbarState extends RawScrollbarState<DragOnlyScrollbar> {
  final _states = <WidgetState>{};

  // The default handler pages toward the pointer. Desktop navigation here is
  // limited to dragging the thumb, so intentionally omit that superclass action.
  @override
  // ignore: must_call_super
  void handleTrackTapDown(TapDownDetails details) {}

  @override
  void handleThumbPressStart(Offset localPosition) {
    super.handleThumbPressStart(localPosition);
    setState(() => _states.add(WidgetState.dragged));
  }

  @override
  void handleThumbPressEnd(Offset localPosition, Velocity velocity) {
    super.handleThumbPressEnd(localPosition, velocity);
    setState(() => _states.remove(WidgetState.dragged));
  }

  @override
  void handleHover(PointerHoverEvent event) {
    super.handleHover(event);
    final hovered = isPointerOverScrollbar(
      event.position,
      event.kind,
      forHover: true,
    );
    if (hovered != _states.contains(WidgetState.hovered)) {
      setState(() {
        if (hovered) {
          _states.add(WidgetState.hovered);
        } else {
          _states.remove(WidgetState.hovered);
        }
      });
    }
  }

  @override
  void handleHoverExit(PointerExitEvent event) {
    super.handleHoverExit(event);
    setState(() => _states.remove(WidgetState.hovered));
  }

  @override
  void updateScrollbarPainter() {
    super.updateScrollbarPainter();
    final theme = ScrollbarTheme.of(context);
    scrollbarPainter
      ..color =
          theme.thumbColor?.resolve(_states) ??
          Theme.of(context).colorScheme.outline
      ..thickness = theme.thickness?.resolve(_states) ?? 8
      ..radius = theme.radius ?? const Radius.circular(8)
      ..crossAxisMargin = theme.crossAxisMargin ?? 0
      ..mainAxisMargin = theme.mainAxisMargin ?? 0
      ..minLength = theme.minThumbLength ?? 48;
  }
}
