import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/browse_page_state_store.dart';
import '../state/app_runtime_providers.dart';

/// Restores display position without retaining routes or a second data source.
class BrowsePageScroll extends ConsumerStatefulWidget {
  const BrowsePageScroll({
    super.key,
    required this.pageKey,
    required this.controller,
    required this.child,
    this.displayState = const {},
    this.anchorIds = const [],
  });
  final String pageKey;
  final ScrollController controller;
  final Widget child;
  final Map<String, Object?> displayState;
  final List<String> anchorIds;

  /// A nested tree can supply its current visible order without owning scroll state.
  static void setAnchorIds(BuildContext context, Iterable<String> ids) {
    final owner = context
        .dependOnInheritedWidgetOfExactType<_BrowseAnchors>()
        ?.owner;
    if (owner == null) return;
    owner._anchorIds = ids.toList(growable: false);
    owner._scheduleRestore();
  }

  @override
  ConsumerState<BrowsePageScroll> createState() => _BrowsePageScrollState();
}

class _BrowsePageScrollState extends ConsumerState<BrowsePageScroll>
    with WidgetsBindingObserver {
  late final BrowsePageStateStore _store;
  final Map<String, BuildContext> _anchors = {};
  bool _restored = false;
  bool _changingPage = false;
  bool _restoreScheduled = false;
  bool _anchorRestored = false;
  bool _applyingRestore = false;
  late int _epoch;
  List<String> _anchorIds = const [];
  (double, double)? _lastDimensions;

  @override
  void initState() {
    super.initState();
    _store = ref.read(browsePageStateStoreProvider);
    _epoch = _store.epoch;
    WidgetsBinding.instance.addObserver(this);
    unawaited(
      _store.initialize().then((_) {
        if (!mounted) return;
        _store.update(widget.pageKey, widget.displayState, epoch: _epoch);
        _scheduleRestore();
      }),
    );
  }

  @override
  void didUpdateWidget(covariant BrowsePageScroll oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pageKey != widget.pageKey) {
      _save(key: oldWidget.pageKey, displayState: oldWidget.displayState);
      _epoch = _store.epoch;
      _restored = false;
      _changingPage = true;
      _anchorRestored = false;
      _scheduleRestore();
    }
    _store.update(widget.pageKey, widget.displayState, epoch: _epoch);
  }

  void _scheduleRestore() {
    if (!mounted || _restoreScheduled || (_restored && _anchorRestored)) return;
    _restoreScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _restoreScheduled = false;
      if (!mounted || _epoch != _store.epoch || !widget.controller.hasClients) {
        return;
      }
      final position = widget.controller.position;
      if ((_restored && _anchorRestored) ||
          position.isScrollingNotifier.value) {
        return;
      }
      if (!position.hasContentDimensions) return;
      final saved = _store.stateFor(widget.pageKey);
      final offset =
          (saved['offset'] as num?)?.toDouble() ??
          (_changingPage ? 0.0 : position.pixels);
      if (!_restored) {
        if (offset > 0 && position.maxScrollExtent == 0) return;
        _restored = true;
        _changingPage = false;
        _applyingRestore = true;
        position.jumpTo(
          offset.clamp(position.minScrollExtent, position.maxScrollExtent),
        );
        _applyingRestore = false;
        _scheduleRestore();
        return;
      }
      final anchor = saved['anchor'];
      final anchorOffset = (saved['anchorOffset'] as num?)?.toDouble();
      final target = anchor is String ? _anchors[anchor] : null;
      final box = target?.findRenderObject();
      double? destination;
      if (anchorOffset != null && box is RenderBox && box.attached) {
        destination = RenderAbstractViewport.maybeOf(
          box,
        )?.getOffsetToReveal(box, 0).offset;
        if (destination != null) destination -= anchorOffset;
      } else if (anchor is String && _anchorIds.contains(anchor)) {
        // Lazy lists may put the stable item outside the old pixel window after
        // insertion or a layout change. Estimate from currently mounted rows,
        // then use the item's actual geometry on the next frame.
        final targetIndex = _anchorIds.indexOf(anchor);
        final samples = <(int, double)>[];
        for (final entry in _anchors.entries) {
          final index = _anchorIds.indexOf(entry.key);
          final render = entry.value.findRenderObject();
          if (index < 0 || render is! RenderBox || !render.attached) continue;
          final reveal = RenderAbstractViewport.maybeOf(
            render,
          )?.getOffsetToReveal(render, 0);
          if (reveal != null) samples.add((index, reveal.offset));
        }
        samples.sort((a, b) => a.$1.compareTo(b.$1));
        if (samples.length >= 2 && samples.last.$2 > samples.first.$2) {
          final stride =
              (samples.last.$2 - samples.first.$2) /
              (samples.last.$1 - samples.first.$1);
          destination =
              samples.first.$2 +
              (targetIndex - samples.first.$1) * stride -
              (anchorOffset ?? 0);
        }
      }
      if (destination != null) {
        final clamped = destination.clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        );
        if ((clamped - position.pixels).abs() > 0.5) {
          _applyingRestore = true;
          position.jumpTo(clamped);
          _applyingRestore = false;
          _scheduleRestore();
          return;
        }
      }
      _anchorRestored = true;
    });
  }

  void _save({String? key, Map<String, Object?>? displayState}) {
    if (!_restored ||
        _applyingRestore ||
        _epoch != _store.epoch ||
        !widget.controller.hasClients) {
      return;
    }
    final position = widget.controller.position;
    if (!position.hasContentDimensions) return;
    String? firstId;
    double? firstOffset;
    final viewport = context.findRenderObject();
    if (viewport is RenderBox && viewport.attached && viewport.hasSize) {
      for (final entry in _anchors.entries) {
        final box = entry.value.findRenderObject();
        if (box is! RenderBox || !box.attached || !box.hasSize) continue;
        final reveal = RenderAbstractViewport.maybeOf(
          box,
        )?.getOffsetToReveal(box, 0);
        if (reveal == null) continue;
        final top = reveal.offset - position.pixels;
        if (top + box.size.height <= 0 || top >= viewport.size.height) continue;
        if (firstOffset == null || top < firstOffset) {
          firstId = entry.key;
          firstOffset = top;
        }
      }
    }
    _store.update(key ?? widget.pageKey, {
      'offset': position.pixels,
      'anchor': firstId,
      'anchorOffset': firstOffset,
      ...(displayState ?? widget.displayState),
    }, epoch: _epoch);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _save();
      unawaited(_store.flush());
    }
  }

  @override
  void dispose() {
    _save();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.anchorIds.isNotEmpty) _anchorIds = widget.anchorIds;
    _scheduleRestore();
    return _BrowseAnchors(
      owner: this,
      child: NotificationListener<ScrollMetricsNotification>(
        onNotification: (notification) {
          if (notification.depth == 0) {
            final dimensions = (
              notification.metrics.viewportDimension,
              notification.metrics.maxScrollExtent,
            );
            if (_lastDimensions != null &&
                _lastDimensions != dimensions &&
                _restored &&
                !(widget.controller.hasClients &&
                    widget.controller.position.isScrollingNotifier.value)) {
              _anchorRestored = false;
            }
            _lastDimensions = dimensions;
            _scheduleRestore();
          }
          return false;
        },
        child: NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            if (notification.depth != 0) return false;
            if (notification is ScrollStartNotification && !_applyingRestore) {
              if (widget.controller.position.isScrollingNotifier.value) {
                // A fresh interaction after clearing begins a new snapshot.
                _epoch = _store.epoch;
              }
              _restored = _anchorRestored = true;
            }
            if (notification is ScrollEndNotification) _save();
            return false;
          },
          child: widget.child,
        ),
      ),
    );
  }
}

class _BrowseAnchors extends InheritedWidget {
  const _BrowseAnchors({required this.owner, required super.child});
  final _BrowsePageScrollState owner;
  @override
  bool updateShouldNotify(_BrowseAnchors oldWidget) => owner != oldWidget.owner;
}

class BrowseAnchor extends StatefulWidget {
  const BrowseAnchor({super.key, required this.id, required this.child});
  final String id;
  final Widget child;
  @override
  State<BrowseAnchor> createState() => _BrowseAnchorState();
}

class _BrowseAnchorState extends State<BrowseAnchor> {
  _BrowsePageScrollState? _owner;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _owner?._anchors.remove(widget.id);
    _owner = context
        .dependOnInheritedWidgetOfExactType<_BrowseAnchors>()
        ?.owner;
    _owner?._anchors[widget.id] = context;
    _owner?._scheduleRestore();
  }

  @override
  void didUpdateWidget(covariant BrowseAnchor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.id != widget.id) _owner?._anchors.remove(oldWidget.id);
    _owner?._anchors[widget.id] = context;
    _owner?._scheduleRestore();
  }

  @override
  void dispose() {
    if (identical(_owner?._anchors[widget.id], context)) {
      _owner?._anchors.remove(widget.id);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
