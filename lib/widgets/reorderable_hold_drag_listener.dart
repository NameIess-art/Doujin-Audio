import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

class ReorderableHoldDragStartListener extends ReorderableDragStartListener {
  const ReorderableHoldDragStartListener({
    super.key,
    required super.index,
    required super.child,
    this.delay = const Duration(milliseconds: 360),
  });

  final Duration delay;

  @override
  MultiDragGestureRecognizer createRecognizer() {
    return DelayedMultiDragGestureRecognizer(delay: delay);
  }
}
