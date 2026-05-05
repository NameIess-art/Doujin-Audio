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

class _ProgressBarState extends State<_ProgressBar>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _lastReportedPosition = Duration.zero;
  DateTime _lastReportTime = DateTime.now();
  bool _isDragging = false;
  double? _dragValueMs;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _ticker.start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _onTick(Duration elapsed) {
    if (_isDragging) return;
    if (mounted) setState(() {});
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
    return StreamBuilder<Duration?>(
      stream: widget.session.durationStream,
      initialData: widget.session.duration,
      builder: (context, snapshot) {
        final duration = snapshot.data;
        return StreamBuilder<Duration>(
          stream: widget.session.positionStream,
          initialData: widget.session.position,
          builder: (context, snapshot) {
            return StreamBuilder<Duration>(
              stream: widget.session.bufferedPositionStream,
              initialData: widget.session.bufferedPosition,
              builder: (context, bufferedSnapshot) {
                final hasKnownDuration = duration != null;
                final effectiveDuration = duration ?? Duration.zero;
                final buffered = bufferedSnapshot.data ?? Duration.zero;
                final isPlaying = widget.session.state.playing;
                var position = _getSmoothPosition(
                  snapshot.data ?? Duration.zero,
                  isPlaying,
                );
                if (hasKnownDuration && position > effectiveDuration) {
                  position = effectiveDuration;
                }
                final durationMs = hasKnownDuration
                    ? max(1, effectiveDuration.inMilliseconds)
                    : max(
                        1,
                        max(position.inMilliseconds, buffered.inMilliseconds),
                      );
                final maxMillis = durationMs.toDouble();
                final basePositionMs = position.inMilliseconds
                    .clamp(0, durationMs)
                    .toDouble();
                final sliderValue =
                    (_isDragging
                            ? (_dragValueMs ?? basePositionMs)
                            : basePositionMs)
                        .clamp(0.0, maxMillis);
                final bufferedValue =
                    (_isDragging
                            ? max(buffered.inMilliseconds, sliderValue.round())
                            : buffered.inMilliseconds)
                        .clamp(0, durationMs)
                        .toDouble();
                final shownSeconds = hasKnownDuration
                    ? (sliderValue ~/ 1000).clamp(
                        0,
                        effectiveDuration.inSeconds,
                      )
                    : (sliderValue ~/ 1000);
                final remainingSeconds = hasKnownDuration
                    ? (effectiveDuration.inSeconds - shownSeconds).clamp(
                        0,
                        effectiveDuration.inSeconds,
                      )
                    : 0;
                final canSeek =
                    hasKnownDuration && effectiveDuration.inMilliseconds > 0;
                final cs = Theme.of(context).colorScheme;

                return Column(
                  children: [
                    SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 2.2,
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 6,
                        ),
                        overlayShape: const RoundSliderOverlayShape(
                          overlayRadius: 12,
                        ),
                        activeTrackColor: cs.onSurface,
                        inactiveTrackColor: cs.onSurface.withValues(
                          alpha: 0.25,
                        ),
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
              },
            );
          },
        );
      },
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

class _SessionSubtitlePanel extends StatelessWidget {
  const _SessionSubtitlePanel({required this.session, required this.provider});

  final PlaybackSession session;
  final AudioProvider provider;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<SubtitleTrack?>(
      future: provider.subtitleTrackForPath(session.currentTrackPath),
      builder: (context, subtitleSnapshot) {
        final subtitleTrack = subtitleSnapshot.data;
        return StreamBuilder<Duration>(
          stream: session.positionStream,
          initialData: session.position,
          builder: (context, positionSnapshot) {
            final subtitleText = provider.subtitleTextForTrackAt(
              session.currentTrackPath,
              positionSnapshot.data ?? session.position,
              subtitleTrack: subtitleTrack,
            );
            if (subtitleText == null) {
              return const SizedBox.shrink();
            }
            return _SubtitleChip(text: subtitleText);
          },
        );
      },
    );
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
