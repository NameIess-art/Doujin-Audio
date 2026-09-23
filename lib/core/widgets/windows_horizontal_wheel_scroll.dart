import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Maps a Windows mouse wheel to a horizontal scrollable's existing position.
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
    return Listener(
      onPointerSignal: (signal) {
        if (defaultTargetPlatform != TargetPlatform.windows ||
            signal is! PointerScrollEvent ||
            signal.scrollDelta.dy == 0 ||
            controller.positions.length != 1) {
          return;
        }
        final position = controller.position;
        final target = (position.pixels + signal.scrollDelta.dy).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        );
        if (target == position.pixels) return;
        GestureBinding.instance.pointerSignalResolver.register(signal, (event) {
          if (!mounted || controller.positions.length != 1) return;
          controller.position.pointerScroll(
            (event as PointerScrollEvent).scrollDelta.dy,
          );
        });
      },
      child: widget.builder(controller),
    );
  }
}
