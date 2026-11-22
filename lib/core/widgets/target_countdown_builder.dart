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

class _TargetCountdownBuilderState extends State<TargetCountdownBuilder>
    with WidgetsBindingObserver {
  Timer? _ticker;
  Duration _remaining = Duration.zero;
  bool _tickerModeEnabled = true;
  AppLifecycleState? _lifecycleState;

  @override
  void initState() {
    super.initState();
    final binding = WidgetsBinding.instance;
    _lifecycleState = binding.lifecycleState;
    binding.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickerModeEnabled = TickerMode.valuesOf(context).enabled;
    _syncTicker();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
    _syncTicker(setStateIfChanged: true);
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
    WidgetsBinding.instance.removeObserver(this);
    _stopTicker();
    super.dispose();
  }

  void _syncTicker({bool setStateIfChanged = false}) {
    final visible =
        _lifecycleState == null ||
        _lifecycleState == AppLifecycleState.resumed ||
        _lifecycleState == AppLifecycleState.inactive;
    _updateRemaining(
      setStateIfChanged: setStateIfChanged && _tickerModeEnabled && visible,
    );
    if (!_tickerModeEnabled || !visible || _remaining == Duration.zero) {
      _stopTicker();
      return;
    }
    if (_ticker?.isActive == true) return;
    _ticker = Timer.periodic(widget.tickInterval, (_) {
      _updateRemaining();
      if (_remaining == Duration.zero) _stopTicker();
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
    if (setStateIfChanged) {
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
