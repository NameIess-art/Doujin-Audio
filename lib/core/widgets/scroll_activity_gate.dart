import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../ui/ui_interaction_coordinator.dart';

class ScrollActivityGate extends StatefulWidget {
  const ScrollActivityGate({
    super.key,
    required this.child,
    this.idleDelay = const Duration(milliseconds: 160),
    this.maxNotificationDepth = 0,
    this.onMetricsChanged,
  }) : assert(maxNotificationDepth >= 0);

  final Widget child;
  final Duration idleDelay;
  final int maxNotificationDepth;
  final VoidCallback? onMetricsChanged;

  static bool isScrollingOf(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<_ScrollActivityScope>();
    return scope?.notifier?.value ?? false;
  }

  static bool isScrollingWithoutDependencyOf(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<_ScrollActivityScope>();
    return scope?.notifier?.value ?? false;
  }

  /// Animation owners can react directly without rebuilding their text/layout.
  static ValueListenable<bool>? scrollingListenableOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_ScrollActivityScope>()?.notifier;

  @override
  State<ScrollActivityGate> createState() => _ScrollActivityGateState();
}

class _ScrollActivityGateState extends State<ScrollActivityGate> {
  late final ValueNotifier<bool> _isScrolling = ValueNotifier<bool>(false);
  final Object _interactionSource = Object();
  Timer? _idleTimer;
  bool _tickerModeEnabled = true;
  bool _scrolling = false;
  bool _scrollingUpdateScheduled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickerModeEnabled = TickerMode.valuesOf(context).enabled;
    if (!_tickerModeEnabled) {
      _idleTimer?.cancel();
      _idleTimer = null;
      _scrolling = false;
      _publishScrolling();
      UiInteractionCoordinator.instance.cancelInteraction(_interactionSource);
    }
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    UiInteractionCoordinator.instance.cancelInteraction(_interactionSource);
    _isScrolling.dispose();
    super.dispose();
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    if (!_tickerModeEnabled ||
        notification.depth > widget.maxNotificationDepth) {
      return false;
    }

    if (notification is ScrollStartNotification ||
        notification is ScrollUpdateNotification ||
        notification is OverscrollNotification) {
      _idleTimer?.cancel();
      _idleTimer = null;
      _setScrolling(true);
    } else if (notification is ScrollEndNotification) {
      // A held drag can pause between updates without ending the interaction.
      // Arm one quiet-window timer at the end, rather than on every frame.
      _scheduleIdle();
    }
    return false;
  }

  void _setScrolling(bool value) {
    if (_scrolling == value) return;
    _scrolling = value;
    if (value) {
      UiInteractionCoordinator.instance.beginInteraction(_interactionSource);
    } else {
      UiInteractionCoordinator.instance.endInteraction(_interactionSource);
    }
    _publishScrolling();
  }

  void _publishScrolling() {
    if (SchedulerBinding.instance.schedulerPhase !=
        SchedulerPhase.persistentCallbacks) {
      _isScrolling.value = _scrolling;
      return;
    }
    if (_scrollingUpdateScheduled) return;
    _scrollingUpdateScheduled = true;
    // Resizing columns can start a ballistic correction during viewport layout.
    // Protect interaction immediately, but notify dependent widgets after layout.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollingUpdateScheduled = false;
      if (mounted) _isScrolling.value = _scrolling;
    });
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
        child: widget.onMetricsChanged == null
            ? widget.child
            : NotificationListener<ScrollMetricsNotification>(
                onNotification: (notification) {
                  if (notification.depth <= widget.maxNotificationDepth) {
                    widget.onMetricsChanged?.call();
                  }
                  return false;
                },
                child: widget.child,
              ),
      ),
    );
  }
}

class _ScrollActivityScope extends InheritedNotifier<ValueNotifier<bool>> {
  const _ScrollActivityScope({required super.notifier, required super.child});
}
