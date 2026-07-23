part of 'playlist_tab.dart';

typedef _ProgressSliderValue = ({
  double maxMillis,
  double sliderValue,
  double bufferedValue,
  Duration duration,
  bool hasKnownDuration,
  bool canSeek,
});

typedef _ProgressTimecodeValue = ({String elapsedText, String remainingText});

class _ProgressBar extends StatelessWidget {
  const _ProgressBar({
    super.key,
    required this.session,
    required this.playback,
    required this.paths,
    this.timeSegmentLabels = const <TimeSegmentLabel>[],
    this.selectedSegmentId,
    this.onManualSeek,
  });

  final PlaybackSession session;
  final PlaybackFacade playback;
  final AudioPathCoordinator paths;
  final List<TimeSegmentLabel> timeSegmentLabels;
  final String? selectedSegmentId;
  final ValueChanged<Duration>? onManualSeek;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final track = paths.trackByPath(session.currentTrackPath);
    final isAsmr = track?.remoteMetadataKind == 'asmr.one';
    final primaryColor = isAsmr
        ? AppDesignTokens.of(context).asmrAccent
        : cs.primary;
    final staticLayer = _ProgressBarStaticLayer(
      session: session,
      labels: timeSegmentLabels,
      selectedSegmentId: selectedSegmentId,
      colorScheme: cs,
    );
    return _ProgressSliderAndTimecodes(
      session: session,
      playback: playback,
      primaryColor: primaryColor,
      staticLayer: staticLayer,
      timeSegmentLabels: timeSegmentLabels,
      selectedSegmentId: selectedSegmentId,
      onManualSeek: onManualSeek,
    );
  }
}

class _ProgressSliderAndTimecodes extends StatefulWidget {
  const _ProgressSliderAndTimecodes({
    required this.session,
    required this.playback,
    required this.primaryColor,
    required this.staticLayer,
    required this.timeSegmentLabels,
    required this.selectedSegmentId,
    required this.onManualSeek,
  });

  final PlaybackSession session;
  final PlaybackFacade playback;
  final Color primaryColor;
  final Widget staticLayer;
  final List<TimeSegmentLabel> timeSegmentLabels;
  final String? selectedSegmentId;
  final ValueChanged<Duration>? onManualSeek;

  @override
  State<_ProgressSliderAndTimecodes> createState() =>
      _ProgressSliderAndTimecodesState();
}

class _ProgressSliderAndTimecodesState
    extends State<_ProgressSliderAndTimecodes> {
  static const Duration _bufferedUpdateInterval = Duration(milliseconds: 120);

  late final PlaybackPositionUiGate _positionGate;
  late final ValueNotifier<_ProgressSliderValue> _sliderValue;
  late final ValueNotifier<_ProgressTimecodeValue> _timecodeValue;
  late final ValueNotifier<_ProgressTooltipState?> _tooltipValue;
  StreamSubscription<Duration>? _bufferedSub;
  Timer? _bufferedUpdateTimer;
  bool _isDragging = false;
  double? _dragValueMs;
  bool _tickerModeEnabled = true;
  bool _bufferedUpdateQueued = false;
  Duration _bufferedPosition = Duration.zero;

  @override
  void initState() {
    super.initState();
    _bufferedPosition = widget.session.bufferedPosition;
    _positionGate = PlaybackPositionUiGate(
      session: widget.session,
      includeBufferedPosition: false,
    )..addListener(_handlePositionTick);
    _sliderValue = ValueNotifier<_ProgressSliderValue>(
      _buildSliderValue(_positionGate.value),
    );
    _timecodeValue = ValueNotifier<_ProgressTimecodeValue>(
      _buildTimecodeValue(_sliderValue.value),
    );
    _tooltipValue = ValueNotifier<_ProgressTooltipState?>(null);
    _bindBufferedPosition();
  }

  @override
  void didUpdateWidget(covariant _ProgressSliderAndTimecodes oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) {
      _bufferedPosition = widget.session.bufferedPosition;
      _positionGate.updateSession(widget.session);
      _bindBufferedPosition();
      _publishProgressValue(force: true);
    } else if (oldWidget.timeSegmentLabels != widget.timeSegmentLabels ||
        oldWidget.selectedSegmentId != widget.selectedSegmentId) {
      _clearTooltip();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nextTickerMode = TickerMode.valuesOf(context).enabled;
    if (_tickerModeEnabled == nextTickerMode) return;
    _tickerModeEnabled = nextTickerMode;
    if (!_isDragging) {
      _positionGate.tickerModeEnabled = nextTickerMode;
    }
  }

  @override
  void dispose() {
    _bufferedUpdateTimer?.cancel();
    unawaited(_bufferedSub?.cancel());
    _positionGate
      ..removeListener(_handlePositionTick)
      ..dispose();
    _sliderValue.dispose();
    _timecodeValue.dispose();
    _tooltipValue.dispose();
    super.dispose();
  }

  void _handlePositionTick() {
    _publishProgressValue();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: _ProgressSliderFrame(
        sliderValue: _sliderValue,
        timecodeValue: _timecodeValue,
        tooltipValue: _tooltipValue,
        staticLayer: widget.staticLayer,
        primaryColor: widget.primaryColor,
        onLongPressMove: _handleLongPressPosition,
        onLongPressEnd: _clearTooltip,
        onChangeStart: _handleSliderChangeStart,
        onChanged: _handleSliderChanged,
        onChangeEnd: _handleSliderChangeEnd,
      ),
    );
  }

  void _bindBufferedPosition() {
    unawaited(_bufferedSub?.cancel());
    _bufferedSub = widget.session.bufferedPositionStream.listen(
      _handleBufferedPosition,
    );
  }

  void _handleBufferedPosition(Duration buffered) {
    if (_bufferedPosition == buffered) return;
    _bufferedPosition = buffered;
    if (_isDragging) return;
    if (_bufferedUpdateTimer?.isActive ?? false) {
      _bufferedUpdateQueued = true;
      return;
    }
    _publishProgressValue();
    _bufferedUpdateQueued = false;
    _bufferedUpdateTimer = Timer(_bufferedUpdateInterval, () {
      if (!_bufferedUpdateQueued || !mounted || _isDragging) return;
      _bufferedUpdateQueued = false;
      _publishProgressValue();
    });
  }

  void _publishProgressValue({bool force = false}) {
    final nextSlider = _buildSliderValue(_positionGate.value);
    if (force || _sliderValue.value != nextSlider) {
      _sliderValue.value = nextSlider;
    }
    final nextTimecode = _buildTimecodeValue(nextSlider);
    if (force || _timecodeValue.value != nextTimecode) {
      _timecodeValue.value = nextTimecode;
    }
  }

  _ProgressSliderValue _buildSliderValue(PlaybackPositionUiSnapshot snapshot) {
    final duration = snapshot.duration;
    final hasKnownDuration = duration != null;
    final effectiveDuration = duration ?? Duration.zero;
    var position = snapshot.position;
    if (hasKnownDuration && position > effectiveDuration) {
      position = effectiveDuration;
    }
    final durationMs = hasKnownDuration
        ? max(1, effectiveDuration.inMilliseconds)
        : max(
            1,
            max(position.inMilliseconds, _bufferedPosition.inMilliseconds),
          );
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
                ? max(_bufferedPosition.inMilliseconds, sliderValue.round())
                : _bufferedPosition.inMilliseconds)
            .clamp(0, durationMs)
            .toDouble();
    return (
      maxMillis: maxMillis,
      sliderValue: sliderValue,
      bufferedValue: bufferedValue,
      duration: effectiveDuration,
      hasKnownDuration: hasKnownDuration,
      canSeek: hasKnownDuration && effectiveDuration.inMilliseconds > 0,
    );
  }

  _ProgressTimecodeValue _buildTimecodeValue(_ProgressSliderValue value) {
    final shownSeconds = value.hasKnownDuration
        ? (value.sliderValue ~/ 1000).clamp(0, value.duration.inSeconds)
        : (value.sliderValue ~/ 1000);
    final remainingSeconds = value.hasKnownDuration
        ? (value.duration.inSeconds - shownSeconds).clamp(
            0,
            value.duration.inSeconds,
          )
        : 0;
    return (
      elapsedText: formatDurationCompact(Duration(seconds: shownSeconds)),
      remainingText: value.hasKnownDuration
          ? '-${formatDurationCompact(Duration(seconds: remainingSeconds))}'
          : '--:--',
    );
  }

  void _handleLongPressPosition(Offset localPosition) {
    final value = _sliderValue.value;
    if (!value.canSeek) return;
    _showLongPressLabels(localPosition, value.maxMillis, _overlayLabels);
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
    _showLabelsAtPosition(
      _tooltipStateForPosition(position, dx, width, labels),
    );
  }

  void _handleSliderChangeStart(double value) {
    AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection);
    _positionGate.tickerModeEnabled = false;
    _isDragging = true;
    _dragValueMs = value;
    _publishProgressValue(force: true);
    _showLabelsAtSliderValue(value);
  }

  void _handleSliderChanged(double value) {
    _isDragging = true;
    _dragValueMs = value;
    _publishProgressValue(force: true);
    _showLabelsAtSliderValue(value);
  }

  void _handleSliderChangeEnd(double value) {
    AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection);
    final position = Duration(milliseconds: value.round());
    _isDragging = false;
    _dragValueMs = null;
    _clearTooltip();
    _publishProgressValue(force: true);
    widget.onManualSeek?.call(position);
    widget.playback.seekSession(widget.session.id, position);
    _positionGate.tickerModeEnabled = _tickerModeEnabled;
  }

  void _showLabelsAtSliderValue(double valueMs) {
    final slider = _sliderValue.value;
    final state = _tooltipStateForSliderValue(
      valueMs,
      slider.maxMillis,
      _overlayLabels,
    );
    if (state == null) return;
    _showLabelsAtPosition(state);
  }

  List<TimeSegmentLabel> get _overlayLabels =>
      _sliderValue.value.hasKnownDuration
      ? widget.timeSegmentLabels
      : const <TimeSegmentLabel>[];

  _ProgressTooltipState? _tooltipStateForSliderValue(
    double valueMs,
    double maxMillis,
    List<TimeSegmentLabel> labels,
  ) {
    final box = context.findRenderObject() as RenderBox?;
    final width = box?.size.width ?? 0;
    if (width <= 0) return null;
    const horizontalPadding = 24.0;
    final trackWidth = max(1.0, width - horizontalPadding * 2);
    final ratio = (valueMs / maxMillis).clamp(0.0, 1.0);
    final dx = horizontalPadding + trackWidth * ratio;
    final position = Duration(milliseconds: valueMs.round());
    return _tooltipStateForPosition(position, dx, width, labels);
  }

  void _showLabelsAtPosition(_ProgressTooltipState state) {
    if (_tooltipValue.value == state) return;
    _tooltipValue.value = state;
  }

  _ProgressTooltipState _tooltipStateForPosition(
    Duration position,
    double dx,
    double width,
    List<TimeSegmentLabel> labels,
  ) {
    final hits = labels
        .where((label) => label.contains(position))
        .toList(growable: false);
    return _ProgressTooltipState(
      labels: hits,
      dx: dx,
      left: (dx - 96).clamp(0.0, max(0.0, width - 192)),
    );
  }

  void _clearTooltip() {
    if (_tooltipValue.value == null) return;
    _tooltipValue.value = null;
  }
}

class _ProgressSliderFrame extends StatelessWidget {
  const _ProgressSliderFrame({
    required this.sliderValue,
    required this.timecodeValue,
    required this.tooltipValue,
    required this.staticLayer,
    required this.primaryColor,
    required this.onLongPressMove,
    required this.onLongPressEnd,
    required this.onChangeStart,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final ValueListenable<_ProgressSliderValue> sliderValue;
  final ValueListenable<_ProgressTimecodeValue> timecodeValue;
  final ValueListenable<_ProgressTooltipState?> tooltipValue;
  final Widget staticLayer;
  final Color primaryColor;
  final ValueChanged<Offset> onLongPressMove;
  final VoidCallback onLongPressEnd;
  final ValueChanged<double> onChangeStart;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Column(
          children: [
            GestureDetector(
              behavior: HitTestBehavior.translucent,
              onLongPressStart: (details) =>
                  onLongPressMove(details.localPosition),
              onLongPressMoveUpdate: (details) =>
                  onLongPressMove(details.localPosition),
              onLongPressEnd: (_) => onLongPressEnd(),
              onLongPressCancel: onLongPressEnd,
              child: SizedBox(
                height: 52,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned.fill(child: staticLayer),
                    _ProgressSliderTheme(
                      primaryColor: primaryColor,
                      child: ValueListenableBuilder<_ProgressSliderValue>(
                        valueListenable: sliderValue,
                        builder: (context, value, child) {
                          return Slider(
                            max: value.maxMillis,
                            value: value.sliderValue,
                            secondaryTrackValue: value.bufferedValue,
                            onChangeStart: value.canSeek ? onChangeStart : null,
                            onChanged: value.canSeek ? onChanged : null,
                            onChangeEnd: value.canSeek ? onChangeEnd : null,
                            semanticFormatterCallback: (rawValue) {
                              final position = Duration(
                                milliseconds: rawValue.round(),
                              );
                              return '${formatDurationCompact(position)} / '
                                  '${formatDurationCompact(value.duration)}';
                            },
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
            ValueListenableBuilder<_ProgressTimecodeValue>(
              valueListenable: timecodeValue,
              builder: (context, value, child) {
                return _ProgressTimecodeRow(value: value);
              },
            ),
          ],
        ),
        ValueListenableBuilder<_ProgressTooltipState?>(
          valueListenable: tooltipValue,
          builder: (context, value, child) {
            if (value == null || value.labels.isEmpty) {
              return const SizedBox.shrink();
            }
            return Positioned(
              left: value.left,
              top: 44,
              child: _TimeSegmentDragTooltip(labels: value.labels),
            );
          },
        ),
      ],
    );
  }
}

class _ProgressSliderTheme extends StatelessWidget {
  const _ProgressSliderTheme({required this.primaryColor, required this.child});

  final Color primaryColor;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: 4.0,
        thumbShape: const RoundSliderThumbShape(
          enabledThumbRadius: 7,
          elevation: 4,
          pressedElevation: 8,
        ),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
        activeTrackColor: primaryColor,
        inactiveTrackColor: primaryColor.withValues(alpha: 0.22),
        thumbColor: primaryColor,
        overlayColor: primaryColor.withValues(alpha: 0.15),
      ),
      child: child,
    );
  }
}

class _ProgressTimecodeRow extends StatelessWidget {
  const _ProgressTimecodeRow({required this.value});

  final _ProgressTimecodeValue value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _TimecodeLabel(text: value.elapsedText),
          _TimecodeLabel(text: value.remainingText, alignEnd: true),
        ],
      ),
    );
  }
}

class _ProgressBarStaticLayer extends StatelessWidget {
  const _ProgressBarStaticLayer({
    required this.session,
    required this.labels,
    required this.selectedSegmentId,
    required this.colorScheme,
  });

  final PlaybackSession session;
  final List<TimeSegmentLabel> labels;
  final String? selectedSegmentId;
  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration?>(
      stream: session.durationStream,
      initialData: session.duration,
      builder: (context, snapshot) {
        final duration = snapshot.data ?? Duration.zero;
        final paintLabels = duration.inMilliseconds > 0
            ? labels
            : const <TimeSegmentLabel>[];
        return CustomPaint(
          painter: _TimeSegmentProgressPainter(
            labels: paintLabels,
            duration: duration,
            selectedSegmentId: selectedSegmentId,
            colorScheme: colorScheme,
          ),
        );
      },
    );
  }
}

class _ProgressTooltipState {
  const _ProgressTooltipState({
    required this.labels,
    required this.dx,
    required this.left,
  });

  final List<TimeSegmentLabel> labels;
  final double dx;
  final double left;

  @override
  bool operator ==(Object other) {
    return other is _ProgressTooltipState &&
        listEquals(other.labels, labels) &&
        other.dx == dx &&
        other.left == left;
  }

  @override
  int get hashCode => Object.hash(Object.hashAll(labels), dx, left);
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
          borderRadius: BorderRadius.circular(16),
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

class _SessionSubtitlePanel extends ConsumerStatefulWidget {
  const _SessionSubtitlePanel({required this.session});

  final PlaybackSession session;

  @override
  ConsumerState<_SessionSubtitlePanel> createState() =>
      _SessionSubtitlePanelState();
}

class _SessionSubtitlePanelState extends ConsumerState<_SessionSubtitlePanel> {
  late final PlaybackPositionUiGate _positionGate;
  final SubtitleTextCache _subtitleTextCache = SubtitleTextCache();
  SubtitleTrack? _subtitleTrack;
  String? _subtitleText;
  int? _playbackSubtitleIndex;
  String? _loadedPath;
  bool _tickerModeEnabled = true;

  @override
  void initState() {
    super.initState();
    _positionGate = PlaybackPositionUiGate(
      session: widget.session,
      includeBufferedPosition: false,
    )..addListener(_handlePositionTick);
    _loadSubtitleTrack();
  }

  @override
  void didUpdateWidget(covariant _SessionSubtitlePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) {
      _positionGate.updateSession(widget.session);
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
    _positionGate.tickerModeEnabled = nextTickerMode;
  }

  @override
  void dispose() {
    _positionGate
      ..removeListener(_handlePositionTick)
      ..dispose();
    super.dispose();
  }

  void _handlePositionTick() {
    _updateSubtitleText(_positionGate.value.position);
  }

  void _loadSubtitleTrack() {
    final trackPath = widget.session.currentTrackPath;
    _loadedPath = trackPath;
    _subtitleTextCache.clear();
    setState(() {
      _subtitleTrack = null;
      _subtitleText = null;
      _playbackSubtitleIndex = null;
    });
    ref.read(playbackSubtitleServiceProvider).load(trackPath).then((track) {
      if (!mounted || _loadedPath != trackPath) return;
      _subtitleTrack = track;
      _subtitleTextCache.clear();
      _updateSubtitleText(_positionGate.value.position);
    });
  }

  void _updateSubtitleText(Duration position) {
    if (!_tickerModeEnabled) return;
    final track = _subtitleTrack;
    final nextText = _subtitleTextCache.resolve(
      trackPath: widget.session.currentTrackPath,
      position: position,
      track: track,
    );
    final nextIndex = _timelineSubtitleIndexAt(track, position);
    if (_subtitleText == nextText && _playbackSubtitleIndex == nextIndex) {
      return;
    }
    setState(() {
      _subtitleText = nextText;
      _playbackSubtitleIndex = nextIndex;
    });
  }

  int? _timelineSubtitleIndexAt(SubtitleTrack? track, Duration position) {
    final cues = track?.cues;
    if (cues == null || cues.isEmpty) return null;
    if (position < cues.first.start) return 0;

    var low = 0;
    var high = cues.length - 1;
    var result = 0;
    while (low <= high) {
      final mid = low + ((high - low) >> 1);
      if (cues[mid].start <= position) {
        result = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final detail = ref.watch(sessionDetailTransportProvider(widget.session.id));
    final playbackError = detail?.playbackError ?? widget.session.playbackError;
    final isLoading = detail?.isLoading ?? widget.session.isPlaybackLoading;
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final transitionDuration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : AppDesignTokens.of(context).motionStandard;

    late final Widget content;
    if (isLoading) {
      content = Container(
        key: const ValueKey('subtitle_loading'),
        width: double.infinity,
        height: 44,
        padding: EdgeInsets.zero,
        alignment: Alignment.topLeft,
        child: ClipRect(
          child: Text(
            i18n.tr('playback_loading'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
              fontSize: 16,
              height: 1.3,
            ),
          ),
        ),
      );
    } else if (playbackError != null) {
      content = Container(
        key: const ValueKey('subtitle_error'),
        width: double.infinity,
        height: 44,
        padding: EdgeInsets.zero,
        alignment: Alignment.topLeft,
        child: ClipRect(
          child: Text(
            localizedPlaybackErrorText(i18n, playbackError),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Colors.redAccent,
              fontWeight: FontWeight.w600,
              fontSize: 16,
              height: 1.3,
            ),
          ),
        ),
      );
    } else {
      final subtitleStyle = ref.watch(
        settingsStateProvider.select(
          (state) =>
              state.value?.playbackDetailSubtitleStyle ??
              PlaybackDetailSubtitleStyle.compact,
        ),
      );
      final subtitleTrack = _subtitleTrack;
      final playbackSubtitleIndex = _playbackSubtitleIndex;
      if (subtitleStyle == PlaybackDetailSubtitleStyle.timeline &&
          subtitleTrack != null &&
          subtitleTrack.cues.isNotEmpty &&
          playbackSubtitleIndex != null) {
        content = _TimelineSubtitleView(
          key: ValueKey<Object>((widget.session.id, subtitleTrack)),
          cues: subtitleTrack.cues,
          playbackSubtitleIndex: playbackSubtitleIndex,
          onSeek: (position) => ref
              .read(playbackFacadeProvider)
              .seekSession(widget.session.id, position),
        );
      } else {
        final subtitleText = _subtitleText;
        content = subtitleText == null
            ? const SizedBox.shrink(key: ValueKey('subtitle_empty'))
            : _SubtitleChip(key: ValueKey(subtitleText), text: subtitleText);
      }
    }

    return AnimatedSize(
      duration: transitionDuration,
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: AnimatedSwitcher(
        duration: transitionDuration,
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, animation) => FadeTransition(
          key: ValueKey<Object>(('subtitle_fade', child.key)),
          opacity: animation,
          child: child,
        ),
        layoutBuilder: (currentChild, previousChildren) {
          return Stack(
            alignment: Alignment.topCenter,
            children: [...previousChildren, ?currentChild],
          );
        },
        child: content,
      ),
    );
  }
}

class _SubtitleChip extends StatelessWidget {
  const _SubtitleChip({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      height: 44,
      padding: EdgeInsets.zero,
      alignment: Alignment.topCenter,
      child: ClipRect(
        child: SizedBox(
          width: double.infinity,
          child: Text(
            text,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: _sessionDetailForeground(
                cs,
                _SessionDetailForegroundLevel.medium,
                darkFallback: cs.onSurface.withValues(alpha: 0.85),
              ),
              fontWeight: FontWeight.w600,
              fontSize: 16,
              height: 1.3,
            ),
          ),
        ),
      ),
    );
  }
}

class _TimelineSubtitleView extends StatefulWidget {
  const _TimelineSubtitleView({
    super.key,
    required this.cues,
    required this.playbackSubtitleIndex,
    required this.onSeek,
  });

  final List<SubtitleCue> cues;
  final int playbackSubtitleIndex;
  final Future<void> Function(Duration position) onSeek;

  @override
  State<_TimelineSubtitleView> createState() => _TimelineSubtitleViewState();
}

class _TimelineSubtitleViewState extends State<_TimelineSubtitleView> {
  static const int _initialWindowRadius = 30;
  static const int _windowExpansionSize = 30;
  static const int _windowExpansionThreshold = 4;
  static const double _minimumItemExtent = 48;
  static const double _minimumViewportHeight = _minimumItemExtent * 2;
  static const double _textHorizontalPadding = 20;
  static const double _textVerticalPadding = 6;
  static const Duration _returnDelay = Duration(seconds: 3);
  static const Duration _scrollDuration = Duration(milliseconds: 180);
  static const Duration _focusHapticInterval = Duration(milliseconds: 110);

  late final ScrollController _scrollController;
  late int _focusedIndex;
  int _windowStart = 0;
  int _windowEnd = 0;
  List<double> _itemExtents = const <double>[];
  List<double> _itemCenters = const <double>[];
  double _viewportHeight = _minimumViewportHeight;
  double _leadingPadding = _minimumItemExtent / 2;
  double _trailingPadding = _minimumItemExtent / 2;
  (Object, int, int, double, TextScaler, TextDirection, TextStyle)?
  _layoutSignature;
  Timer? _returnTimer;
  bool _isBrowsing = false;
  bool _isSnapping = false;
  bool _isProgrammaticScroll = false;
  bool _layoutAlignmentScheduled = false;

  int get _lastIndex => widget.cues.length - 1;
  int get _windowLength => _windowEnd - _windowStart;

  @override
  void initState() {
    super.initState();
    _focusedIndex = widget.playbackSubtitleIndex.clamp(0, _lastIndex);
    _resetWindowAround(_focusedIndex);
    _scrollController = ScrollController()
      ..addListener(_handleScrollOffsetChanged);
  }

  @override
  void didUpdateWidget(covariant _TimelineSubtitleView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final playbackIndex = widget.playbackSubtitleIndex.clamp(0, _lastIndex);
    if (!identical(oldWidget.cues, widget.cues)) {
      _focusedIndex = playbackIndex;
      _resetWindowAround(playbackIndex);
      return;
    }
    if (_isBrowsing) {
      if (_focusedIndex == playbackIndex) {
        _returnTimer?.cancel();
        _isBrowsing = false;
      }
      return;
    }
    if (oldWidget.playbackSubtitleIndex != widget.playbackSubtitleIndex) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_isBrowsing) {
          unawaited(_scrollToIndex(playbackIndex));
        }
      });
    }
  }

  @override
  void dispose() {
    _returnTimer?.cancel();
    _scrollController
      ..removeListener(_handleScrollOffsetChanged)
      ..dispose();
    super.dispose();
  }

  void _handleScrollOffsetChanged() {
    if (!_scrollController.hasClients || _itemCenters.isEmpty) return;
    final viewportCenter = _scrollController.offset + (_viewportHeight / 2);
    final nextIndex = _windowStart + _nearestWindowItemIndex(viewportCenter);
    if (nextIndex == _focusedIndex || !mounted) return;
    setState(() => _focusedIndex = nextIndex);
    // Give each subtitle paragraph a light, rate-limited detent while the
    // user browses.  The shared feedback service respects the user's haptic
    // setting and suppresses rapid duplicate pulses.
    if (_isBrowsing) {
      unawaited(
        AppInteractionFeedback.continuous(
          '${widget.key}:$nextIndex',
          interval: _focusHapticInterval,
        ),
      );
    }
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    if (_isProgrammaticScroll) return false;
    if (notification is ScrollStartNotification ||
        (notification is ScrollUpdateNotification &&
            notification.scrollDelta != null &&
            notification.scrollDelta!.abs() > 0)) {
      _returnTimer?.cancel();
      if (!_isBrowsing) {
        AppInteractionFeedback.resetContinuous();
        setState(() => _isBrowsing = true);
      }
    } else if (notification is ScrollEndNotification &&
        _isBrowsing &&
        !_isSnapping) {
      unawaited(_finishManualScroll());
    }
    return false;
  }

  Future<void> _finishManualScroll() async {
    if (_isSnapping || !mounted) return;
    _isSnapping = true;
    try {
      _extendWindowNearFocusedIndex();
      await _scrollToIndex(_focusedIndex);
    } finally {
      _isSnapping = false;
    }
    if (!mounted || !_isBrowsing) return;
    final playbackIndex = widget.playbackSubtitleIndex.clamp(0, _lastIndex);
    if (_focusedIndex == playbackIndex) {
      setState(() => _isBrowsing = false);
      return;
    }
    _returnTimer?.cancel();
    _returnTimer = Timer(_returnDelay, _returnToPlaybackSubtitle);
  }

  void _returnToPlaybackSubtitle() {
    _returnTimer = null;
    if (!mounted) return;
    final playbackIndex = widget.playbackSubtitleIndex.clamp(0, _lastIndex);
    setState(() => _isBrowsing = false);
    unawaited(_scrollToIndex(playbackIndex));
  }

  Future<void> _scrollToIndex(int index) async {
    final targetIndex = index.clamp(0, _lastIndex);
    if (!_windowContains(targetIndex)) {
      setState(() => _resetWindowAround(targetIndex));
    }
    if (!_scrollController.hasClients || _itemCenters.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_scrollToIndex(targetIndex));
      });
      return;
    }
    final position = _scrollController.position;
    final localIndex = targetIndex - _windowStart;
    final targetOffset = (_itemCenters[localIndex] - (_viewportHeight / 2))
        .clamp(position.minScrollExtent, position.maxScrollExtent)
        .toDouble();
    if ((_scrollController.offset - targetOffset).abs() < 0.5) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      _isProgrammaticScroll = true;
      try {
        _scrollController.jumpTo(targetOffset);
      } finally {
        _isProgrammaticScroll = false;
      }
      return;
    }
    _isProgrammaticScroll = true;
    try {
      await _scrollController.animateTo(
        targetOffset,
        duration: _scrollDuration,
        curve: Curves.easeOutCubic,
      );
    } finally {
      _isProgrammaticScroll = false;
    }
  }

  void _seekToFocusedSubtitle() {
    _returnTimer?.cancel();
    if (_isBrowsing) {
      setState(() => _isBrowsing = false);
    }
    unawaited(widget.onSeek(widget.cues[_focusedIndex].start));
  }

  int _nearestWindowItemIndex(double viewportCenter) {
    var low = 0;
    var high = _itemCenters.length;
    while (low < high) {
      final mid = low + ((high - low) >> 1);
      if (_itemCenters[mid] < viewportCenter) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    if (low == 0) return 0;
    if (low == _itemCenters.length) return _itemCenters.length - 1;
    final previous = low - 1;
    return viewportCenter - _itemCenters[previous] <=
            _itemCenters[low] - viewportCenter
        ? previous
        : low;
  }

  bool _windowContains(int index) =>
      index >= _windowStart && index < _windowEnd;

  void _resetWindowAround(int index) {
    final targetIndex = index.clamp(0, _lastIndex);
    _windowStart = max(0, targetIndex - _initialWindowRadius);
    _windowEnd = min(
      widget.cues.length,
      targetIndex + _initialWindowRadius + 1,
    );
    _invalidateLayoutMetrics();
  }

  void _extendWindowNearFocusedIndex() {
    var nextStart = _windowStart;
    var nextEnd = _windowEnd;
    if (_focusedIndex - _windowStart <= _windowExpansionThreshold) {
      nextStart = max(0, _windowStart - _windowExpansionSize);
    }
    if ((_windowEnd - 1) - _focusedIndex <= _windowExpansionThreshold) {
      nextEnd = min(widget.cues.length, _windowEnd + _windowExpansionSize);
    }
    if (nextStart == _windowStart && nextEnd == _windowEnd) return;
    setState(() {
      _windowStart = nextStart;
      _windowEnd = nextEnd;
      _invalidateLayoutMetrics();
    });
  }

  void _invalidateLayoutMetrics() {
    _layoutSignature = null;
    _itemExtents = const <double>[];
    _itemCenters = const <double>[];
  }

  double _measureCueExtent(
    SubtitleCue cue, {
    required double textWidth,
    required TextStyle textStyle,
    required TextDirection textDirection,
    required TextScaler textScaler,
  }) {
    final painter = TextPainter(
      text: TextSpan(text: cue.text, style: textStyle),
      textAlign: TextAlign.center,
      textDirection: textDirection,
      textScaler: textScaler,
    )..layout(maxWidth: textWidth);
    return max(
      _minimumItemExtent,
      (painter.height * 1.03) + (_textVerticalPadding * 2),
    );
  }

  void _updateLayoutMetrics(List<double> itemExtents) {
    final viewportHeight = max(_minimumViewportHeight, itemExtents.reduce(max));
    final leadingPadding = max(0.0, (viewportHeight - itemExtents.first) / 2);
    final trailingPadding = max(0.0, (viewportHeight - itemExtents.last) / 2);
    var offset = leadingPadding;
    final itemCenters = <double>[];
    for (final extent in itemExtents) {
      itemCenters.add(offset + (extent / 2));
      offset += extent;
    }
    _itemExtents = itemExtents;
    _itemCenters = itemCenters;
    _viewportHeight = viewportHeight;
    _leadingPadding = leadingPadding;
    _trailingPadding = trailingPadding;
    _scheduleLayoutAlignment();
  }

  void _scheduleLayoutAlignment() {
    if (_layoutAlignmentScheduled) return;
    _layoutAlignmentScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _layoutAlignmentScheduled = false;
      if (!mounted || _isBrowsing || !_scrollController.hasClients) return;
      if (!_windowContains(_focusedIndex) ||
          _itemCenters.length != _windowLength) {
        return;
      }
      final position = _scrollController.position;
      final localIndex = _focusedIndex - _windowStart;
      final targetOffset = (_itemCenters[localIndex] - (_viewportHeight / 2))
          .clamp(position.minScrollExtent, position.maxScrollExtent)
          .toDouble();
      if ((_scrollController.offset - targetOffset).abs() < 0.5) return;
      _isProgrammaticScroll = true;
      try {
        _scrollController.jumpTo(targetOffset);
      } finally {
        _isProgrammaticScroll = false;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final baseTextStyle =
        Theme.of(context).textTheme.bodyMedium ?? const TextStyle();
    final focusedTextStyle = baseTextStyle.copyWith(
      color: _sessionDetailForeground(
        cs,
        _SessionDetailForegroundLevel.medium,
        darkFallback: cs.onSurface.withValues(alpha: 0.85),
      ),
      fontWeight: FontWeight.w600,
      fontSize: 16,
      height: 1.3,
    );
    final unfocusedTextStyle = focusedTextStyle.copyWith(
      color: _sessionDetailForeground(
        cs,
        _SessionDetailForegroundLevel.muted,
        darkFallback: cs.onSurface.withValues(alpha: 0.72),
      ),
      fontWeight: FontWeight.w500,
      fontSize: 14,
    );
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    return LayoutBuilder(
      builder: (context, constraints) {
        final textWidth = max(
          0.0,
          constraints.maxWidth - (_textHorizontalPadding * 2),
        );
        final textScaler = MediaQuery.textScalerOf(context);
        final textDirection = Directionality.of(context);
        final layoutSignature = (
          widget.cues,
          _windowStart,
          _windowEnd,
          textWidth,
          textScaler,
          textDirection,
          focusedTextStyle,
        );
        if (_layoutSignature != layoutSignature) {
          _layoutSignature = layoutSignature;
          final itemExtents = <double>[
            for (var index = _windowStart; index < _windowEnd; index++)
              _measureCueExtent(
                widget.cues[index],
                textWidth: textWidth,
                textStyle: focusedTextStyle,
                textDirection: textDirection,
                textScaler: textScaler,
              ),
          ];
          _updateLayoutMetrics(itemExtents);
        }
        return SizedBox(
          key: const ValueKey('subtitle_timeline_viewport'),
          width: double.infinity,
          height: _viewportHeight,
          child: ClipRect(
            child: NotificationListener<ScrollNotification>(
              onNotification: _handleScrollNotification,
              child: ListView.builder(
                key: const ValueKey('subtitle_timeline_list'),
                controller: _scrollController,
                padding: EdgeInsets.only(
                  top: _leadingPadding,
                  bottom: _trailingPadding,
                ),
                itemExtentBuilder: (index, _) => _itemExtents[index],
                itemCount: _windowLength,
                itemBuilder: (context, localIndex) {
                  final index = _windowStart + localIndex;
                  final cue = widget.cues[index];
                  final isFocused = index == _focusedIndex;
                  final isPlaybackSubtitle =
                      index == widget.playbackSubtitleIndex;
                  return Semantics(
                    selected: isFocused,
                    child: Opacity(
                      opacity: isFocused ? 1 : 0.45,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 120),
                        curve: Curves.easeOutCubic,
                        decoration: BoxDecoration(
                          color: isFocused
                              ? cs.primary.withValues(alpha: 0.08)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Stack(
                          key: ValueKey('subtitle_timeline_cue_$index'),
                          fit: StackFit.expand,
                          children: [
                            Padding(
                              key: ValueKey(
                                'subtitle_timeline_text_padding_$index',
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: _textHorizontalPadding,
                                vertical: _textVerticalPadding,
                              ),
                              child: Center(
                                child: AnimatedScale(
                                  scale: isFocused ? 1.03 : 1,
                                  duration: const Duration(milliseconds: 120),
                                  curve: Curves.easeOutCubic,
                                  child: SizedBox(
                                    width: double.infinity,
                                    child: Text(
                                      cue.text,
                                      key: ValueKey(
                                        'subtitle_timeline_text_$index',
                                      ),
                                      textAlign: TextAlign.center,
                                      style: isFocused
                                          ? focusedTextStyle
                                          : unfocusedTextStyle,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            if (isFocused && !isPlaybackSubtitle)
                              Align(
                                alignment: Alignment.centerRight,
                                child: SizedBox(
                                  width: 48,
                                  height: 48,
                                  child: IconButton(
                                    key: const ValueKey(
                                      'subtitle_timeline_seek_button',
                                    ),
                                    tooltip: i18n.tr('seek_to_subtitle'),
                                    onPressed: _seekToFocusedSubtitle,
                                    icon: Icon(
                                      Icons.play_arrow_rounded,
                                      color: _sessionDetailForeground(
                                        cs,
                                        _SessionDetailForegroundLevel.medium,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}
