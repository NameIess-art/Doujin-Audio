import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'app_feedback.dart';

class AppFixedExtentWheel extends StatefulWidget {
  const AppFixedExtentWheel({
    super.key,
    required this.value,
    required this.itemCount,
    required this.labelAt,
    required this.onChanged,
    this.looping = false,
    this.selectionColor,
  });

  final int value;
  final int itemCount;
  final String Function(int) labelAt;
  final bool looping;
  final Color? selectionColor;
  final ValueChanged<int> onChanged;

  @override
  State<AppFixedExtentWheel> createState() => _AppFixedExtentWheelState();
}

class _AppFixedExtentWheelState extends State<AppFixedExtentWheel> {
  late final FixedExtentScrollController _controller;
  int _lastReportedValue = -1;
  int? _wheelTargetItem;

  @override
  void initState() {
    super.initState();
    _controller = FixedExtentScrollController(initialItem: widget.value);
    _lastReportedValue = widget.value;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context) &&
        _controller.hasClients &&
        _controller.position.isScrollingNotifier.value) {
      // Jump notifications can update the owner, which cannot rebuild during
      // this dependency change. Finish at the latest target after the frame.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted ||
            !_controller.hasClients ||
            !MediaQuery.disableAnimationsOf(context)) {
          return;
        }
        _scrollToItem(
          _wheelTargetItem ?? _controller.selectedItem,
          duration: Duration.zero,
        );
      });
    }
  }

  void _scrollToItem(int item, {required Duration duration}) {
    _wheelTargetItem = item;
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.jumpToItem(item);
      _wheelTargetItem = null;
    } else {
      _controller.animateToItem(
        item,
        duration: duration,
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  void didUpdateWidget(AppFixedExtentWheel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != oldWidget.value && widget.value != _lastReportedValue) {
      // The owner already supplied this value; a jump must not report it back
      // synchronously while that owner is building.
      _lastReportedValue = widget.value;
      if (_wheelTargetItem != null) {
        final targetLogicalIndex = _valueAt(_wheelTargetItem!);
        if (widget.value == targetLogicalIndex) {
          return;
        }
      }
      if (_controller.hasClients) {
        final currentLogicalIndex = _controller.selectedItem;
        var targetLogicalIndex = widget.value;
        if (widget.looping) {
          var delta = widget.value - _valueAt(currentLogicalIndex);
          if (delta > widget.itemCount ~/ 2) {
            delta -= widget.itemCount;
          } else if (delta < -(widget.itemCount ~/ 2)) {
            delta += widget.itemCount;
          }
          targetLogicalIndex = currentLogicalIndex + delta;
        }
        if (currentLogicalIndex != targetLogicalIndex) {
          _scrollToItem(
            targetLogicalIndex,
            duration: const Duration(milliseconds: 360),
          );
        }
      }
    }
  }

  int _valueAt(int item) => widget.looping ? item % widget.itemCount : item;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurface;
    final labels = List<Widget>.generate(
      widget.itemCount,
      (index) => Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            widget.labelAt(index),
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ),
      ),
    );
    return Stack(
      alignment: Alignment.center,
      children: [
        if (widget.selectionColor case final color?)
          Container(
            height: 42,
            margin: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(16),
            ),
          ),
        ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(
            dragDevices: {
              PointerDeviceKind.touch,
              PointerDeviceKind.mouse,
              PointerDeviceKind.trackpad,
            },
          ),
          child: NotificationListener<ScrollEndNotification>(
            onNotification: (_) {
              _wheelTargetItem = null;
              return false;
            },
            child: ListWheelScrollView.useDelegate(
              controller: _controller,
              itemExtent: 42,
              perspective: 0.005,
              diameterRatio: 1.5,
              physics: const FixedExtentScrollPhysics(),
              onSelectedItemChanged: (index) {
                final actualIndex = _valueAt(index);
                if (actualIndex != _lastReportedValue) {
                  _lastReportedValue = actualIndex;
                  AppInteractionFeedback.trigger(
                    AppInteractionFeedbackType.selection,
                  );
                  widget.onChanged(actualIndex);
                }
              },
              childDelegate: widget.looping
                  ? ListWheelChildLoopingListDelegate(children: labels)
                  : ListWheelChildListDelegate(children: labels),
            ),
          ),
        ),
        if (defaultTargetPlatform == TargetPlatform.windows)
          Positioned.fill(
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerSignal: (signal) {
                if (signal is PointerScrollEvent) {
                  GestureBinding.instance.pointerSignalResolver.register(
                    signal,
                    (event) {
                      final scrollEvent = event as PointerScrollEvent;
                      if (scrollEvent.scrollDelta.dy == 0) return;
                      final delta = scrollEvent.scrollDelta.dy > 0 ? 1 : -1;
                      final baseItem =
                          _wheelTargetItem ?? _controller.selectedItem;
                      final requestedItem = baseItem + delta;
                      final nextItem = widget.looping
                          ? requestedItem
                          : requestedItem.clamp(0, widget.itemCount - 1);
                      if (nextItem == baseItem) return;
                      _scrollToItem(
                        nextItem,
                        duration: const Duration(milliseconds: 200),
                      );
                    },
                  );
                }
              },
            ),
          ),
      ],
    );
  }
}
