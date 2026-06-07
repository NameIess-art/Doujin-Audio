import 'dart:async';

import 'package:flutter/widgets.dart';

import '../services/ui_interaction_coordinator.dart';

class ScrollActivityGate extends StatefulWidget {
  const ScrollActivityGate({
    super.key,
    required this.child,
    this.idleDelay = const Duration(milliseconds: 160),
  });

  final Widget child;
  final Duration idleDelay;

  static bool isScrollingOf(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<_ScrollActivityScope>();
    return scope?.notifier?.value ?? false;
  }

  static bool isScrollingWithoutDependencyOf(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<_ScrollActivityScope>();
    return scope?.notifier?.value ?? false;
  }

  @override
  State<ScrollActivityGate> createState() => _ScrollActivityGateState();
}

class _ScrollActivityGateState extends State<ScrollActivityGate> {
  late final ValueNotifier<bool> _isScrolling = ValueNotifier<bool>(false);
  final Object _interactionSource = Object();
  Timer? _idleTimer;

  @override
  void dispose() {
    _idleTimer?.cancel();
    UiInteractionCoordinator.instance.cancelInteraction(_interactionSource);
    _isScrolling.dispose();
    super.dispose();
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    if (notification.depth != 0) return false;

    if (notification is ScrollStartNotification ||
        notification is ScrollUpdateNotification ||
        notification is OverscrollNotification) {
      _setScrolling(true);
      _scheduleIdle();
    } else if (notification is ScrollEndNotification) {
      _scheduleIdle();
    }
    return false;
  }

  void _setScrolling(bool value) {
    if (_isScrolling.value == value) return;
    _isScrolling.value = value;
    if (value) {
      UiInteractionCoordinator.instance.beginInteraction(_interactionSource);
    } else {
      UiInteractionCoordinator.instance.endInteraction(_interactionSource);
    }
  }

  void _scheduleIdle() {
    _idleTimer?.cancel();
    _idleTimer = Timer(widget.idleDelay, () {
      _idleTimer = null;
      _setScrolling(false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return _ScrollActivityScope(
      notifier: _isScrolling,
      child: NotificationListener<ScrollNotification>(
        onNotification: _handleScrollNotification,
        child: widget.child,
      ),
    );
  }
}

class _ScrollActivityScope extends InheritedNotifier<ValueNotifier<bool>> {
  const _ScrollActivityScope({required super.notifier, required super.child});
}
