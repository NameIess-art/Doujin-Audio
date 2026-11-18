import 'package:flutter/material.dart';

import 'app_transitions.dart';

/// Projects one transitioning branch without building its offscreen rows.
final class FileTreeExpansionMotion<Branch extends Object, Entry> {
  FileTreeExpansionMotion(TickerProvider vsync, VoidCallback onSettled)
    : _controller = AnimationController(
        vsync: vsync,
        duration: kAppFadeDuration,
        reverseDuration: kAppMotionFast,
      ) {
    _controller.addStatusListener((status) {
      final settled = _outgoing == null
          ? status.isCompleted
          : status.isDismissed;
      if (settled && _branch != null) onSettled();
    });
    _factor = _controller.drive(CurveTween(curve: kAppFadeCurve));
  }

  final AnimationController _controller;
  late final Animation<double> _factor;
  Branch? _branch;
  List<Entry>? _outgoing;
  VoidCallback? _onFinish;
  int _start = 0;
  int _end = 0;

  Branch? get branch => _branch;
  double? progressFor(Branch branch) =>
      _branch == branch ? _controller.value : null;
  bool isClosing(Branch branch) => _branch == branch && _outgoing != null;

  void start(
    Branch branch, {
    List<Entry>? outgoing,
    double? from,
    VoidCallback? onFinish,
  }) {
    final opening = outgoing == null;
    final initial = from ?? (opening ? 0.0 : 1.0);
    if (initial == (opening ? 1.0 : 0.0)) {
      onFinish?.call();
      return;
    }
    _branch = branch;
    _outgoing = outgoing;
    _onFinish = onFinish;
    if (opening) {
      _controller.forward(from: initial);
    } else {
      _controller.reverse(from: initial);
    }
  }

  /// A parent index of -1 animates the entire projection. Null means the
  /// branch is absent from the current projection.
  List<Entry> project(
    BuildContext context,
    List<Entry> rows, {
    required int? Function(List<Entry>, Branch) parentIndex,
    required int Function(Entry) depth,
    required double minRowHeight,
  }) {
    final branch = _branch;
    if (branch == null) return rows;
    final projected = _outgoing ?? rows;
    final parent = parentIndex(projected, branch);
    if (parent == null) {
      _start = _end = 0;
      return projected;
    }
    _start = parent + 1;
    if (parent == -1) {
      _end = projected.length;
    } else {
      _end = _start;
      final parentDepth = depth(projected[parent]);
      while (_end < projected.length && depth(projected[_end]) > parentDepth) {
        _end++;
      }
    }

    // Limit the animated branch to a screen of rows. Otherwise, near-zero
    // row heights would let the sliver build an entire large subtree.
    final end = _end;
    final screenRows =
        (MediaQuery.sizeOf(context).height / minRowHeight).ceil() + 2;
    if (end - _start <= screenRows) return projected;
    _end = _start + screenRows;
    return [...projected.take(_end), ...projected.skip(end)];
  }

  Widget wrap(int index, Widget child, {Key? key}) {
    if (_branch == null || index < _start || index >= _end) {
      return key == null ? child : KeyedSubtree(key: key, child: child);
    }
    final collapsing = _outgoing != null;
    return SizeTransition(
      key: key ?? child.key,
      axisAlignment: -1,
      sizeFactor: _factor,
      child: FadeTransition(
        opacity: _factor,
        child: IgnorePointer(
          ignoring: collapsing,
          child: ExcludeSemantics(excluding: collapsing, child: child),
        ),
      ),
    );
  }

  void pause() => _controller.stop();

  void finish({bool complete = true}) {
    _controller.stop();
    _branch = null;
    _outgoing = null;
    final onFinish = _onFinish;
    _onFinish = null;
    if (complete) onFinish?.call();
  }

  void dispose() => _controller.dispose();
}
