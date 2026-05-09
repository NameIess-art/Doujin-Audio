part of 'playlist_tab.dart';

class _ProgressBar extends StatefulWidget {
  const _ProgressBar({
    super.key,
    required this.session,
    required this.provider,
  });

  final PlaybackSession session;
  final AudioProvider provider;

  @override
  State<_ProgressBar> createState() => _ProgressBarState();
}

class _ProgressBarState extends State<_ProgressBar> {
  static const Duration _smoothTickInterval = Duration(milliseconds: 250);

  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration?>? _durationSub;
  StreamSubscription<Duration>? _bufferedSub;
  Timer? _smoothTimer;
  PlayerState _playerState = PlayerState(false, ProcessingState.idle);
  Duration _streamPosition = Duration.zero;
  Duration? _duration;
  Duration _buffered = Duration.zero;
  Duration _lastReportedPosition = Duration.zero;
  DateTime _lastReportTime = DateTime.now();
  bool _isDragging = false;
  double? _dragValueMs;
  bool _tickerModeEnabled = true;

  @override
  void initState() {
    super.initState();
    _syncFromSession();
    _bindSession();
  }

  @override
  void didUpdateWidget(covariant _ProgressBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session == widget.session) return;
    _unbindSession();
    _syncFromSession();
    _bindSession();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nextTickerMode = TickerMode.valuesOf(context).enabled;
    if (_tickerModeEnabled == nextTickerMode) return;
    _tickerModeEnabled = nextTickerMode;
    _syncSmoothTimer();
  }

  @override
  void dispose() {
    _smoothTimer?.cancel();
    _unbindSession();
    super.dispose();
  }

  void _syncFromSession() {
    _playerState = widget.session.state;
    _streamPosition = widget.session.position;
    _duration = widget.session.duration;
    _buffered = widget.session.bufferedPosition;
    _lastReportedPosition = _streamPosition;
    _lastReportTime = DateTime.now();
    _syncSmoothTimer();
  }

  void _bindSession() {
    _stateSub = widget.session.stateStream.listen((state) {
      if (_playerState == state) return;
      setState(() {
        _playerState = state;
      });
      _syncSmoothTimer();
    });
    _positionSub = widget.session.positionStream.listen((position) {
      if (_streamPosition == position) return;
      setState(() {
        _streamPosition = position;
        _lastReportedPosition = position;
        _lastReportTime = DateTime.now();
      });
    });
    _durationSub = widget.session.durationStream.listen((duration) {
      if (duration == null && _duration != null) return;
      if (_duration == duration) return;
      setState(() {
        _duration = duration;
      });
    });
    _bufferedSub = widget.session.bufferedPositionStream.listen((buffered) {
      if (_buffered == buffered) return;
      setState(() {
        _buffered = buffered;
      });
    });
    _syncSmoothTimer();
  }

  void _unbindSession() {
    unawaited(_stateSub?.cancel());
    unawaited(_positionSub?.cancel());
    unawaited(_durationSub?.cancel());
    unawaited(_bufferedSub?.cancel());
    _stateSub = null;
    _positionSub = null;
    _durationSub = null;
    _bufferedSub = null;
    _smoothTimer?.cancel();
    _smoothTimer = null;
  }

  void _syncSmoothTimer() {
    final shouldTick =
        _tickerModeEnabled && _playerState.playing && !_isDragging;
    if (!shouldTick) {
      _smoothTimer?.cancel();
      _smoothTimer = null;
      return;
    }
    if (_smoothTimer != null) return;
    _smoothTimer = Timer.periodic(_smoothTickInterval, (_) {
      if (!mounted || _isDragging || !_playerState.playing) return;
      setState(() {});
    });
  }

  Duration _getSmoothPosition(Duration streamPosition, bool isPlaying) {
    if (!isPlaying) {
      _lastReportedPosition = streamPosition;
      _lastReportTime = DateTime.now();
      return streamPosition;
    }

    final now = DateTime.now();
    if (streamPosition != _lastReportedPosition) {
      _lastReportedPosition = streamPosition;
      _lastReportTime = now;
      return streamPosition;
    }

    final diff = now.difference(_lastReportTime);
    return streamPosition + diff;
  }

  @override
  Widget build(BuildContext context) {
    final duration = _duration;
    final hasKnownDuration = duration != null;
    final effectiveDuration = duration ?? Duration.zero;
    var position = _getSmoothPosition(_streamPosition, _playerState.playing);
    if (hasKnownDuration && position > effectiveDuration) {
      position = effectiveDuration;
    }
    final durationMs = hasKnownDuration
        ? max(1, effectiveDuration.inMilliseconds)
        : max(1, max(position.inMilliseconds, _buffered.inMilliseconds));
    final maxMillis = durationMs.toDouble();
    final basePositionMs = position.inMilliseconds
        .clamp(0, durationMs)
        .toDouble();
    final sliderValue =
        (_isDragging ? (_dragValueMs ?? basePositionMs) : basePositionMs).clamp(
          0.0,
          maxMillis,
        );
    final bufferedValue =
        (_isDragging
                ? max(_buffered.inMilliseconds, sliderValue.round())
                : _buffered.inMilliseconds)
            .clamp(0, durationMs)
            .toDouble();
    final shownSeconds = hasKnownDuration
        ? (sliderValue ~/ 1000).clamp(0, effectiveDuration.inSeconds)
        : (sliderValue ~/ 1000);
    final remainingSeconds = hasKnownDuration
        ? (effectiveDuration.inSeconds - shownSeconds).clamp(
            0,
            effectiveDuration.inSeconds,
          )
        : 0;
    final canSeek = hasKnownDuration && effectiveDuration.inMilliseconds > 0;
    final cs = Theme.of(context).colorScheme;

    return Column(
      children: [
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 2.2,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
            activeTrackColor: cs.onSurface,
            inactiveTrackColor: cs.onSurface.withValues(alpha: 0.25),
            thumbColor: cs.onSurface,
            overlayColor: cs.onSurface.withValues(alpha: 0.12),
          ),
          child: Slider(
            max: maxMillis,
            value: sliderValue,
            secondaryTrackValue: bufferedValue,
            onChangeStart: !canSeek
                ? null
                : (value) {
                    HapticFeedback.selectionClick();
                    setState(() {
                      _isDragging = true;
                      _dragValueMs = value;
                    });
                    _syncSmoothTimer();
                  },
            onChanged: !canSeek
                ? null
                : (value) {
                    setState(() {
                      _dragValueMs = value;
                    });
                  },
            onChangeEnd: !canSeek
                ? null
                : (value) {
                    HapticFeedback.selectionClick();
                    setState(() {
                      _isDragging = false;
                      _dragValueMs = null;
                    });
                    _syncSmoothTimer();
                    widget.provider.seekSession(
                      widget.session.id,
                      Duration(milliseconds: value.round()),
                    );
                  },
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _TimecodeLabel(text: _fmtSeconds(shownSeconds)),
              _TimecodeLabel(
                text: hasKnownDuration
                    ? '-${_fmtSeconds(remainingSeconds)}'
                    : '--:--',
                alignEnd: true,
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _fmtSeconds(int totalSeconds) {
    final clamped = totalSeconds < 0 ? 0 : totalSeconds;
    final h = clamped ~/ 3600;
    final m = (clamped ~/ 60).remainder(60).toString().padLeft(2, '0');
    final s = clamped.remainder(60).toString().padLeft(2, '0');
    if (h > 0) return '${h.toString().padLeft(2, '0')}:$m:$s';
    return '$m:$s';
  }
}

class _SessionSubtitlePanel extends StatefulWidget {
  const _SessionSubtitlePanel({
    super.key,
    required this.session,
    required this.provider,
  });

  final PlaybackSession session;
  final AudioProvider provider;

  @override
  State<_SessionSubtitlePanel> createState() => _SessionSubtitlePanelState();
}

class _SessionSubtitlePanelState extends State<_SessionSubtitlePanel> {
  StreamSubscription<Duration>? _positionSub;
  SubtitleTrack? _subtitleTrack;
  String? _subtitleText;
  String? _loadedPath;

  @override
  void initState() {
    super.initState();
    _loadSubtitleTrack();
    _bindPosition();
  }

  @override
  void didUpdateWidget(covariant _SessionSubtitlePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) {
      unawaited(_positionSub?.cancel());
      _bindPosition();
    }
    if (_loadedPath != widget.session.currentTrackPath) {
      _loadSubtitleTrack();
    }
  }

  @override
  void dispose() {
    unawaited(_positionSub?.cancel());
    super.dispose();
  }

  void _bindPosition() {
    _positionSub = widget.session.positionStream.listen(_updateSubtitleText);
  }

  void _loadSubtitleTrack() {
    final trackPath = widget.session.currentTrackPath;
    _loadedPath = trackPath;
    setState(() {
      _subtitleTrack = null;
      _subtitleText = null;
    });
    widget.provider.subtitleTrackForPath(trackPath).then((track) {
      if (!mounted || _loadedPath != trackPath) return;
      _subtitleTrack = track;
      _updateSubtitleText(widget.session.position);
    });
  }

  void _updateSubtitleText(Duration position) {
    final nextText = widget.provider.subtitleTextForTrackAt(
      widget.session.currentTrackPath,
      position,
      subtitleTrack: _subtitleTrack,
    );
    if (_subtitleText == nextText) return;
    setState(() {
      _subtitleText = nextText;
    });
  }

  @override
  Widget build(BuildContext context) {
    final subtitleText = _subtitleText;
    if (subtitleText == null) {
      return const SizedBox.shrink();
    }
    return _SubtitleChip(text: subtitleText);
  }
}

class _SubtitleChip extends StatelessWidget {
  const _SubtitleChip({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Text(
        text,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: cs.onSurface.withValues(alpha: 0.85),
          fontWeight: FontWeight.w600,
          fontSize: 16,
          height: 1.3,
        ),
      ),
    );
  }
}
