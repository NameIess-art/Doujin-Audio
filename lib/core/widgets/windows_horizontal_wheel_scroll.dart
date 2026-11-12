import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'windows_smooth_scroll_controller.dart';

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
  final ScrollController _ownedController = WindowsSmoothScrollController();

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
          controller.position.pointerScroll(delta);
        });
      },
      child: widget.builder(controller),
    );
  }
}
