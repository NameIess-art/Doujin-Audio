import 'dart:async';

import 'package:flutter/widgets.dart';

class TargetCountdownBuilder extends StatefulWidget {
  const TargetCountdownBuilder({
    super.key,
    required this.target,
    required this.builder,
    this.tickInterval = const Duration(seconds: 1),
  });

  final DateTime? target;
  final Duration tickInterval;
  final Widget Function(BuildContext context, Duration remaining) builder;

  @override
  State<TargetCountdownBuilder> createState() => _TargetCountdownBuilderState();
}

class _TargetCountdownBuilderState extends State<TargetCountdownBuilder> {
  Timer? _ticker;
  Duration _remaining = Duration.zero;

  @override
  void initState() {
    super.initState();
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant TargetCountdownBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.target != oldWidget.target ||
        widget.tickInterval != oldWidget.tickInterval) {
      if (widget.tickInterval != oldWidget.tickInterval) {
        _stopTicker();
      }
      _syncTicker();
    }
  }

  @override
  void dispose() {
    _stopTicker();
    super.dispose();
  }

  void _syncTicker() {
    _updateRemaining(setStateIfChanged: false);
    if (widget.target == null) {
      _stopTicker();
      return;
    }
    if (_ticker?.isActive == true) return;
    _ticker = Timer.periodic(widget.tickInterval, (_) {
      if (!mounted) return;
      _updateRemaining();
    });
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  void _updateRemaining({bool setStateIfChanged = true}) {
    final target = widget.target;
    final next = target == null
        ? Duration.zero
        : _remainingUntil(target, DateTime.now());
    if (next == _remaining) return;
    if (setStateIfChanged && mounted) {
      setState(() => _remaining = next);
    } else {
      _remaining = next;
    }
  }

  Duration _remainingUntil(DateTime target, DateTime now) {
    final diff = target.difference(now);
    return diff > Duration.zero ? diff : Duration.zero;
  }

  @override
  Widget build(BuildContext context) {
    return widget.builder(context, _remaining);
  }
}
