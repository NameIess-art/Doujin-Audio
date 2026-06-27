part of 'playlist_tab.dart';

class _ProgressBar extends StatefulWidget {
  const _ProgressBar({
    super.key,
    required this.session,
    required this.provider,
    this.timeSegmentLabels = const <TimeSegmentLabel>[],
    this.selectedSegmentId,
    this.onManualSeek,
  });

  final PlaybackSession session;
  final AudioProvider provider;
  final List<TimeSegmentLabel> timeSegmentLabels;
  final String? selectedSegmentId;
  final ValueChanged<Duration>? onManualSeek;

  @override
  State<_ProgressBar> createState() => _ProgressBarState();
}

class _ProgressBarState extends State<_ProgressBar> {
  static const Duration _smoothTickInterval = Duration(milliseconds: 333);

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
  List<TimeSegmentLabel> _longPressLabels = const <TimeSegmentLabel>[];
  double? _longPressDx;
  double? _longPressTooltipLeft;

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
    if (_tickerModeEnabled) {
      _syncFromSession();
    }
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
      if (!_tickerModeEnabled) {
        _streamPosition = position;
        _lastReportedPosition = position;
        _lastReportTime = DateTime.now();
        return;
      }
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
        _tickerModeEnabled &&
        _playerState.playing &&
        !_isDragging &&
        (_duration?.inMilliseconds ?? 0) > 0;
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
    final overlayLabels = hasKnownDuration
        ? widget.timeSegmentLabels
        : const <TimeSegmentLabel>[];

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Column(
          children: [
            GestureDetector(
              behavior: HitTestBehavior.translucent,
              onLongPressStart: !canSeek
                  ? null
                  : (details) => _showLongPressLabels(
                      details.localPosition,
                      maxMillis,
                      overlayLabels,
                    ),
              onLongPressMoveUpdate: !canSeek
                  ? null
                  : (details) => _showLongPressLabels(
                      details.localPosition,
                      maxMillis,
                      overlayLabels,
                    ),
              onLongPressEnd: (_) => _clearLongPressLabels(),
              onLongPressCancel: _clearLongPressLabels,
              child: SizedBox(
                height: 52,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned.fill(
                      child: CustomPaint(
                        painter: _TimeSegmentProgressPainter(
                          labels: overlayLabels,
                          duration: effectiveDuration,
                          selectedSegmentId: widget.selectedSegmentId,
                          colorScheme: cs,
                        ),
                      ),
                    ),
                    SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 4.0,
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 7,
                          elevation: 4,
                          pressedElevation: 8,
                        ),
                        overlayShape: const RoundSliderOverlayShape(
                          overlayRadius: 16,
                        ),
                        activeTrackColor: cs.onSurface,
                        inactiveTrackColor: cs.onSurface.withValues(alpha: 0.2),
                        thumbColor: cs.onSurface,
                        overlayColor: cs.onSurface.withValues(alpha: 0.15),
                      ),
                      child: Slider(
                        max: maxMillis,
                        value: sliderValue,
                        secondaryTrackValue: bufferedValue,
                        onChangeStart: !canSeek
                            ? null
                            : (value) {
                                AppInteractionFeedback.trigger(
                                  AppInteractionFeedbackType.selection,
                                );
                                setState(() {
                                  _isDragging = true;
                                  _dragValueMs = value;
                                });
                                _showLabelsAtSliderValue(
                                  value,
                                  maxMillis,
                                  overlayLabels,
                                );
                                _syncSmoothTimer();
                              },
                        onChanged: !canSeek
                            ? null
                            : (value) {
                                setState(() {
                                  _dragValueMs = value;
                                });
                                _showLabelsAtSliderValue(
                                  value,
                                  maxMillis,
                                  overlayLabels,
                                );
                              },
                        onChangeEnd: !canSeek
                            ? null
                            : (value) {
                                AppInteractionFeedback.trigger(
                                  AppInteractionFeedbackType.selection,
                                );
                                setState(() {
                                  _isDragging = false;
                                  _dragValueMs = null;
                                });
                                _clearLongPressLabels();
                                _syncSmoothTimer();
                                final position = Duration(
                                  milliseconds: value.round(),
                                );
                                widget.onManualSeek?.call(position);
                                widget.provider.seekSession(
                                  widget.session.id,
                                  position,
                                );
                              },
                      ),
                    ),
                  ],
                ),
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
        ),
        if (_longPressLabels.isNotEmpty && _longPressTooltipLeft != null)
          Positioned(
            left: _longPressTooltipLeft,
            top: 44,
            child: _TimeSegmentDragTooltip(labels: _longPressLabels),
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

  void _showLongPressLabels(
    Offset localPosition,
    double maxMillis,
    List<TimeSegmentLabel> labels,
  ) {
    final box = context.findRenderObject() as RenderBox?;
    final width = box?.size.width ?? 0;
    if (width <= 0) return;
    const horizontalPadding = 24.0;
    final trackWidth = max(1.0, width - horizontalPadding * 2);
    final dx = localPosition.dx.clamp(
      horizontalPadding,
      width - horizontalPadding,
    );
    final ratio = ((dx - horizontalPadding) / trackWidth).clamp(0.0, 1.0);
    final position = Duration(milliseconds: (maxMillis * ratio).round());
    _showLabelsAtPosition(position, dx, width, labels);
  }

  void _showLabelsAtSliderValue(
    double valueMs,
    double maxMillis,
    List<TimeSegmentLabel> labels,
  ) {
    final box = context.findRenderObject() as RenderBox?;
    final width = box?.size.width ?? 0;
    if (width <= 0) return;
    const horizontalPadding = 24.0;
    final trackWidth = max(1.0, width - horizontalPadding * 2);
    final ratio = (valueMs / maxMillis).clamp(0.0, 1.0);
    final dx = horizontalPadding + trackWidth * ratio;
    final position = Duration(milliseconds: valueMs.round());
    _showLabelsAtPosition(position, dx, width, labels);
  }

  void _showLabelsAtPosition(
    Duration position,
    double dx,
    double width,
    List<TimeSegmentLabel> labels,
  ) {
    final hits = labels
        .where((label) => label.contains(position))
        .toList(growable: false);
    if (_longPressDx == dx && listEquals(_longPressLabels, hits)) return;
    setState(() {
      _longPressDx = dx;
      _longPressTooltipLeft = (dx - 96).clamp(0.0, max(0.0, width - 192));
      _longPressLabels = hits;
    });
  }

  void _clearLongPressLabels() {
    if (_longPressLabels.isEmpty && _longPressDx == null) return;
    setState(() {
      _longPressLabels = const <TimeSegmentLabel>[];
      _longPressDx = null;
      _longPressTooltipLeft = null;
    });
  }
}

class _TimeSegmentProgressPainter extends CustomPainter {
  const _TimeSegmentProgressPainter({
    required this.labels,
    required this.duration,
    required this.selectedSegmentId,
    required this.colorScheme,
  });

  final List<TimeSegmentLabel> labels;
  final Duration duration;
  final String? selectedSegmentId;
  final ColorScheme colorScheme;

  @override
  void paint(Canvas canvas, Size size) {
    if (labels.isEmpty || duration.inMilliseconds <= 0) return;
    const horizontalPadding = 24.0;
    const trackStart = horizontalPadding;
    final trackWidth = max(1.0, size.width - horizontalPadding * 2);
    const trackY = 26.0;
    final trackRect = Rect.fromLTWH(trackStart, trackY - 4, trackWidth, 8);

    for (final label in labels) {
      final color = Color(label.colorValue);
      final startRatio = label.start.inMilliseconds / duration.inMilliseconds;
      final endRatio = label.end.inMilliseconds / duration.inMilliseconds;
      final left = trackStart + trackWidth * startRatio.clamp(0.0, 1.0);
      final right = trackStart + trackWidth * endRatio.clamp(0.0, 1.0);
      if (right <= left) continue;
      final selected = label.id == selectedSegmentId;
      final segmentRect = Rect.fromLTRB(left, trackY - 5, right, trackY + 5);
      final rrect = RRect.fromRectAndRadius(
        segmentRect,
        const Radius.circular(6),
      );
      canvas.drawRRect(
        rrect,
        Paint()
          ..color = color.withValues(alpha: selected ? 0.72 : 0.38)
          ..style = PaintingStyle.fill,
      );
      if (selected) {
        canvas.drawRRect(
          rrect,
          Paint()
            ..color = colorScheme.onSurface.withValues(alpha: 0.78)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2,
        );
      }
    }

    final markerXs = <double>[];
    for (final label in labels) {
      _drawMarker(
        canvas,
        trackRect,
        markerXs,
        label.start,
        duration,
        Color(label.colorValue),
      );
      _drawMarker(
        canvas,
        trackRect,
        markerXs,
        label.end,
        duration,
        Color(label.colorValue),
      );
    }
  }

  void _drawMarker(
    Canvas canvas,
    Rect trackRect,
    List<double> markerXs,
    Duration position,
    Duration duration,
    Color color,
  ) {
    final ratio = position.inMilliseconds / duration.inMilliseconds;
    final x = trackRect.left + trackRect.width * ratio.clamp(0.0, 1.0);
    final nearby = markerXs.where((other) => (other - x).abs() < 14).length;
    markerXs.add(x);
    final layer = nearby.isOdd ? 1 : 0;
    final top = layer == 0 ? 4.0 : 14.0;
    final body = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(x, top + 4), width: 12, height: 8),
      const Radius.circular(3),
    );
    canvas.drawRRect(body, Paint()..color = color);
    final pointer = Path()
      ..moveTo(x - 4, top + 8)
      ..lineTo(x + 4, top + 8)
      ..lineTo(x, trackRect.top - 1)
      ..close();
    canvas.drawPath(pointer, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _TimeSegmentProgressPainter oldDelegate) {
    return oldDelegate.labels != labels ||
        oldDelegate.duration != duration ||
        oldDelegate.selectedSegmentId != selectedSegmentId ||
        oldDelegate.colorScheme != colorScheme;
  }
}

class _TimeSegmentDragTooltip extends StatelessWidget {
  const _TimeSegmentDragTooltip({required this.labels});

  final List<TimeSegmentLabel> labels;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 192),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: cs.surfaceContainerHigh.withValues(alpha: 0.96),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.4)),
          boxShadow: [
            BoxShadow(
              color: cs.shadow.withValues(alpha: 0.16),
              blurRadius: 16,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Wrap(
            spacing: 6,
            runSpacing: 4,
            children: labels
                .map(
                  (label) => DecoratedBox(
                    decoration: BoxDecoration(
                      color: Color(label.colorValue).withValues(alpha: 0.22),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      child: Text(
                        label.name,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: cs.onSurface,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                )
                .toList(growable: false),
          ),
        ),
      ),
    );
  }
}

class _SessionSubtitlePanel extends StatefulWidget {
  const _SessionSubtitlePanel({required this.session, required this.provider});

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
  bool _tickerModeEnabled = true;

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
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nextTickerMode = TickerMode.valuesOf(context).enabled;
    if (_tickerModeEnabled == nextTickerMode) return;
    _tickerModeEnabled = nextTickerMode;
    if (_tickerModeEnabled) {
      _updateSubtitleText(widget.session.position);
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
    if (!_tickerModeEnabled) return;
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
