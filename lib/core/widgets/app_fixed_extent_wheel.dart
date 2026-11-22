import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
  final FocusNode _focusNode = FocusNode();
  int _lastReportedValue = -1;
  int? _wheelTargetItem;
  bool _focused = false;

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

  void _stepBy(int delta) {
    if (delta == 0 || widget.itemCount <= 0 || !_controller.hasClients) return;
    final baseItem = _wheelTargetItem ?? _controller.selectedItem;
    final requestedItem = baseItem + delta;
    final nextItem = widget.looping
        ? requestedItem
        : requestedItem.clamp(0, widget.itemCount - 1);
    if (nextItem == baseItem) return;
    _scrollToItem(nextItem, duration: const Duration(milliseconds: 200));
  }

  void _selectIndex(int index) {
    if (!_controller.hasClients || widget.itemCount <= 0) return;
    final currentItem = _wheelTargetItem ?? _controller.selectedItem;
    var targetItem = index;
    if (widget.looping) {
      var delta = index - _valueAt(currentItem);
      if (delta > widget.itemCount ~/ 2) {
        delta -= widget.itemCount;
      } else if (delta < -(widget.itemCount ~/ 2)) {
        delta += widget.itemCount;
      }
      targetItem = currentItem + delta;
    }
    if (targetItem == currentItem) return;
    _scrollToItem(targetItem, duration: const Duration(milliseconds: 220));
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowUp) {
      _stepBy(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _stepBy(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.pageUp) {
      _stepBy(-5);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.pageDown) {
      _stepBy(5);
      return KeyEventResult.handled;
    }
    if (!widget.looping && widget.itemCount > 0) {
      if (key == LogicalKeyboardKey.home) {
        _selectIndex(0);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.end) {
        _selectIndex(widget.itemCount - 1);
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
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
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = cs.onSurface;
    final labels = List<Widget>.generate(
      widget.itemCount,
      (index) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          _focusNode.requestFocus();
          _selectIndex(index);
        },
        child: Center(
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
      ),
    );
    return Focus(
      focusNode: _focusNode,
      onFocusChange: (focused) {
        if (_focused != focused) setState(() => _focused = focused);
      },
      onKeyEvent: _handleKeyEvent,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (widget.selectionColor case final selectionColor?)
            Container(
              height: 42,
              margin: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: selectionColor,
                borderRadius: BorderRadius.circular(16),
                border: _focused
                    ? Border.all(
                        color: cs.primary.withValues(alpha: 0.7),
                        width: 1.5,
                      )
                    : null,
              ),
            )
          else if (_focused)
            IgnorePointer(
              child: Container(
                height: 42,
                margin: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: cs.primary.withValues(alpha: 0.5),
                    width: 1.5,
                  ),
                ),
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
                        final dy = scrollEvent.scrollDelta.dy;
                        if (dy == 0) return;
                        final steps = (dy.abs() / 100.0).round().clamp(1, 5);
                        _stepBy(dy > 0 ? steps : -steps);
                      },
                    );
                  }
                },
              ),
            ),
        ],
      ),
    );
  }
}
