import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Maps a Windows mouse wheel to a horizontal scrollable's existing position.
/// Keeps wheel input in that region even when the scrollable reaches an edge.
class WindowsHorizontalWheelScroll extends StatefulWidget {
  const WindowsHorizontalWheelScroll({
    super.key,
    required this.builder,
    this.controller,
  });

  final ScrollController? controller;
  final Widget Function(ScrollController controller) builder;

  @override
  State<WindowsHorizontalWheelScroll> createState() =>
      _WindowsHorizontalWheelScrollState();
}

class _WindowsHorizontalWheelScrollState
    extends State<WindowsHorizontalWheelScroll> {
  final ScrollController _ownedController = ScrollController();

  @override
  void dispose() {
    _ownedController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller ?? _ownedController;
    if (defaultTargetPlatform != TargetPlatform.windows) {
      return widget.builder(controller);
    }
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerSignal: (signal) {
        if (signal is! PointerScrollEvent) return;
        GestureBinding.instance.pointerSignalResolver.register(signal, (_) {
          final delta = signal.scrollDelta.dy;
          if (!mounted || delta == 0 || controller.positions.length != 1) {
            return;
          }
          final position = controller.position;
          final target = (position.pixels + delta).clamp(
            position.minScrollExtent,
            position.maxScrollExtent,
          );
          if (target != position.pixels) position.pointerScroll(delta);
        });
      },
      child: widget.builder(controller),
    );
  }
}
