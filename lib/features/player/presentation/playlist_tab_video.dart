part of 'playlist_tab.dart';

bool _isSessionVideoReady(PlaybackSession session, MusicTrack? track) {
  final loadedPath = session.loadedPath;
  return Platform.isAndroid &&
      track?.isVideo == true &&
      loadedPath != null &&
      PathMatcher.equalsNormalized(loadedPath, track!.path);
}

Future<void> _showSessionVideoFullscreen(
  BuildContext context,
  WidgetRef ref, {
  required String sessionId,
  required String trackPath,
}) async {
  final orientationController = ref.read(appOrientationControllerProvider);
  final playback = ref.read(playbackFacadeProvider);
  final lease = await orientationController.enterVideoFullscreen();
  if (!context.mounted) {
    await lease.release();
    return;
  }
  try {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => _SessionVideoFullscreenPage(
          sessionId: sessionId,
          trackPath: trackPath,
          fullscreenLease: lease,
        ),
      ),
    );
  } finally {
    await playback.setSessionTemporarySpeed(sessionId, null);
    await lease.release();
  }
}

enum _FullscreenVideoPanMode { horizontalSeek, brightness, volume }

class _SessionVideoFullscreenPage extends ConsumerStatefulWidget {
  const _SessionVideoFullscreenPage({
    required this.sessionId,
    required this.trackPath,
    required this.fullscreenLease,
  });

  final String sessionId;
  final String trackPath;
  final AppVideoFullscreenLease fullscreenLease;

  @override
  ConsumerState<_SessionVideoFullscreenPage> createState() =>
      _SessionVideoFullscreenPageState();
}

class _SessionVideoFullscreenPageState
    extends ConsumerState<_SessionVideoFullscreenPage>
    with WidgetsBindingObserver {
  static const _controlsTimeout = Duration(seconds: 3);
  static const _feedbackTimeout = Duration(milliseconds: 800);
  static const _gestureThreshold = 8.0;

  late final PlaybackFacade _playback;
  PlaybackSession? _initialSession;
  PlaybackPositionUiGate? _positionGate;
  Future<String?>? _coverFuture;
  Timer? _controlsTimer;
  Timer? _feedbackTimer;
  bool _controlsVisible = true;
  bool _exitScheduled = false;
  bool _exitRunning = false;
  bool _allowPop = false;
  bool? _lastPlaying;
  bool _sliderInteracting = false;
  double? _sliderPositionMs;
  double _brightness = 0.5;
  final _dragVolume = ValueNotifier<double?>(null);
  final _feedback = ValueNotifier<({IconData icon, String text})?>(null);
  late final Listenable _controlValues;

  Offset _panDelta = Offset.zero;
  _FullscreenVideoPanMode? _panMode;
  SessionVideoGestureSide? _panSide;
  Duration _panStartPosition = Duration.zero;
  Duration? _panSeekTarget;
  double _panStartVolume = 1;
  double _panStartBrightness = 0.5;
  Size _panViewportSize = Size.zero;
  Offset? _doubleTapPosition;

  bool _temporarySpeedRequested = false;
  int _temporarySpeedGeneration = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _playback = ref.read(playbackFacadeProvider);
    _initialSession = _playback.sessionById(widget.sessionId);
    final session = _initialSession;
    if (session != null) {
      _positionGate = PlaybackPositionUiGate(
        session: session,
        deferDuringInteraction: false,
      );
    }
    _controlValues = Listenable.merge([
      ?_positionGate,
      _dragVolume,
    ]);
    final paths = ref.read(audioPathCoordinatorProvider);
    final track = paths.trackByPath(widget.trackPath);
    _coverFuture = ref
        .read(libraryFacadeProvider)
        .playbackCoverPathFutureForTrack(track);
    _brightness = widget.fullscreenLease.initialBrightness ?? 0.5;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      unawaited(_restoreTemporarySpeed(showFailure: false));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controlsTimer?.cancel();
    _feedbackTimer?.cancel();
    UiInteractionCoordinator.instance
      ..cancelThrottledCommit('video_brightness:${widget.sessionId}')
      ..cancelThrottledCommit('video_volume:${widget.sessionId}');
    AppInteractionFeedback.resetContinuous();
    final pendingVolume = _dragVolume.value;
    if (pendingVolume != null) {
      unawaited(_playback.setSessionVolume(widget.sessionId, pendingVolume));
    }
    unawaited(_restoreTemporarySpeed(showFailure: false));
    _positionGate?.dispose();
    _dragVolume.dispose();
    _feedback.dispose();
    super.dispose();
  }

  void _exitAfterBuild() {
    if (_exitScheduled) return;
    _exitScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_requestExit());
    });
  }

  Future<void> _requestExit() async {
    if (_exitRunning) return;
    _exitRunning = true;
    _controlsTimer?.cancel();
    UiInteractionCoordinator.instance
      ..cancelThrottledCommit('video_brightness:${widget.sessionId}')
      ..cancelThrottledCommit('video_volume:${widget.sessionId}');
    final pendingVolume = _dragVolume.value;
    if (pendingVolume != null) {
      final ok = await _playback.setSessionVolume(
        widget.sessionId,
        pendingVolume,
      );
      if (!ok && _playback.sessionById(widget.sessionId) != null) {
        _showOperationFailure();
      }
      _dragVolume.value = null;
    }
    await _restoreTemporarySpeed(showFailure: false);
    if (!mounted) return;
    setState(() => _allowPop = true);
    Navigator.of(context).pop();
  }

  void _syncPlaying(bool playing) {
    if (_lastPlaying == playing) return;
    _lastPlaying = playing;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!playing) {
        _controlsTimer?.cancel();
        if (!_controlsVisible) setState(() => _controlsVisible = true);
      } else if (_controlsVisible && !_sliderInteracting) {
        _scheduleControlsHide();
      }
    });
  }

  void _scheduleControlsHide() {
    _controlsTimer?.cancel();
    if (_lastPlaying != true || _sliderInteracting) return;
    _controlsTimer = Timer(_controlsTimeout, () {
      if (!mounted || _sliderInteracting || _lastPlaying != true) return;
      setState(() => _controlsVisible = false);
    });
  }

  void _showControls() {
    _controlsTimer?.cancel();
    if (!_controlsVisible) setState(() => _controlsVisible = true);
    _scheduleControlsHide();
  }

  void _toggleControls() {
    if (_lastPlaying != true) {
      _showControls();
      return;
    }
    _controlsTimer?.cancel();
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _scheduleControlsHide();
  }

  void _setFeedback(IconData icon, String text, {bool persistent = false}) {
    _feedbackTimer?.cancel();
    if (mounted) _feedback.value = (icon: icon, text: text);
    if (!persistent) {
      _feedbackTimer = Timer(_feedbackTimeout, () {
        if (mounted) _feedback.value = null;
      });
    }
  }

  void _showOperationFailure() {
    if (!mounted) return;
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    showAppSnackBar(
      context,
      i18n.tr('operation_failed_retry'),
      tone: AppFeedbackTone.destructive,
    );
  }

  void _handlePanStart(DragStartDetails details, Size viewportSize) {
    if (_sliderInteracting) return;
    _controlsTimer?.cancel();
    _panDelta = Offset.zero;
    _panMode = null;
    _panSide = sessionVideoGestureSide(
      details.localPosition.dx,
      viewportSize.width,
    );
    _panStartPosition =
        _positionGate?.value.position ??
        _initialSession?.position ??
        Duration.zero;
    _panSeekTarget = null;
    _panStartVolume = _initialSession?.volume ?? 1;
    _panStartBrightness = _brightness;
    _panViewportSize = viewportSize;
  }

  void _handlePanUpdate(DragUpdateDetails details) {
    if (_sliderInteracting) return;
    _panDelta += details.delta;
    if (_panMode == null) {
      if (_panDelta.distance < _gestureThreshold) return;
      if (_panDelta.dx.abs() >= _panDelta.dy.abs()) {
        _panMode = _FullscreenVideoPanMode.horizontalSeek;
      } else {
        _panMode = _panSide == SessionVideoGestureSide.left
            ? _FullscreenVideoPanMode.brightness
            : _FullscreenVideoPanMode.volume;
      }
    }

    switch (_panMode!) {
      case _FullscreenVideoPanMode.horizontalSeek:
        final duration = _positionGate?.value.duration ?? Duration.zero;
        if (duration <= Duration.zero) return;
        final target = sessionVideoHorizontalSeekTarget(
          startPosition: _panStartPosition,
          duration: duration,
          dragDx: _panDelta.dx,
          viewportWidth: _panViewportSize.width,
        );
        _panSeekTarget = target;
        final delta = target - _panStartPosition;
        final sign = delta.isNegative ? '-' : '+';
        _setFeedback(
          delta.isNegative
              ? Icons.fast_rewind_rounded
              : Icons.fast_forward_rounded,
          '${formatDurationCompact(target)}  '
          '$sign${formatDurationCompact(delta.abs())}',
          persistent: true,
        );
        break;
      case _FullscreenVideoPanMode.brightness:
        final next = sessionVideoVerticalGestureValue(
          startValue: _panStartBrightness,
          dragDy: _panDelta.dy,
          viewportHeight: _panViewportSize.height,
          minimum: 0.05,
          maximum: 1,
        );
        _brightness = next;
        AppInteractionFeedback.continuous((next * 100).round());
        _setFeedback(
          Icons.brightness_6_rounded,
          '${ref.read(appLanguageProviderInstanceProvider).tr('brightness')} '
          '${(next * 100).round()}%',
          persistent: true,
        );
        UiInteractionCoordinator.instance.scheduleThrottledCommit(
          key: 'video_brightness:${widget.sessionId}',
          commit: () async {
            await widget.fullscreenLease.setBrightness(next);
          },
        );
        break;
      case _FullscreenVideoPanMode.volume:
        final next = sessionVideoVerticalGestureValue(
          startValue: _panStartVolume,
          dragDy: _panDelta.dy,
          viewportHeight: _panViewportSize.height,
          minimum: 0,
          maximum: PlaybackFacade.maxSessionVolume,
        );
        _dragVolume.value = next;
        AppInteractionFeedback.continuous((next * 100).round());
        _setFeedback(
          _volumeIcon(next),
          '${ref.read(appLanguageProviderInstanceProvider).tr('volume')} '
          '${(next * 100).round()}%',
          persistent: true,
        );
        UiInteractionCoordinator.instance.scheduleThrottledCommit(
          key: 'video_volume:${widget.sessionId}',
          commit: () => _playback.setSessionVolume(
            widget.sessionId,
            next,
            persist: false,
          ),
        );
        break;
    }
  }

  void _handlePanEnd({required bool cancelled}) {
    final mode = _panMode;
    final target = _panSeekTarget;
    _panMode = null;
    _panSeekTarget = null;
    AppInteractionFeedback.resetContinuous();
    switch (mode) {
      case _FullscreenVideoPanMode.horizontalSeek:
        if (!cancelled && target != null) {
          unawaited(_playback.seekSession(widget.sessionId, target));
        }
        break;
      case _FullscreenVideoPanMode.brightness:
        UiInteractionCoordinator.instance.cancelThrottledCommit(
          'video_brightness:${widget.sessionId}',
        );
        unawaited(_commitBrightness());
        break;
      case _FullscreenVideoPanMode.volume:
        UiInteractionCoordinator.instance.cancelThrottledCommit(
          'video_volume:${widget.sessionId}',
        );
        final volume = _dragVolume.value;
        _dragVolume.value = null;
        if (volume != null) {
          unawaited(_commitVolume(volume));
        }
        break;
      case null:
        break;
    }
    final feedback = _feedback.value;
    if (feedback != null) {
      _setFeedback(feedback.icon, feedback.text);
    }
    _scheduleControlsHide();
  }

  Future<void> _commitBrightness() async {
    final ok = await widget.fullscreenLease.setBrightness(_brightness);
    if (!ok) _showOperationFailure();
  }

  Future<void> _commitVolume(double volume) async {
    final ok = await _playback.setSessionVolume(widget.sessionId, volume);
    if (!ok) _showOperationFailure();
  }

  void _handleDoubleTap() {
    final position = _doubleTapPosition;
    final gate = _positionGate;
    if (position == null ||
        gate == null ||
        (gate.value.duration ?? Duration.zero) <= Duration.zero) {
      return;
    }
    final side = sessionVideoGestureSide(
      position.dx,
      max(1, MediaQuery.sizeOf(context).width - 48),
    );
    final delta = side == SessionVideoGestureSide.left
        ? const Duration(seconds: -5)
        : const Duration(seconds: 5);
    final target = sessionVideoSkipTarget(
      position: gate.value.position,
      duration: gate.value.duration ?? Duration.zero,
      delta: delta,
    );
    unawaited(
      AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection),
    );
    _setFeedback(
      side == SessionVideoGestureSide.left
          ? Icons.replay_5_rounded
          : Icons.forward_5_rounded,
      ref.read(appLanguageProviderInstanceProvider).tr(
        side == SessionVideoGestureSide.left
            ? 'seek_backward_five_seconds'
            : 'seek_forward_five_seconds',
      ),
    );
    unawaited(_playback.seekSession(widget.sessionId, target));
    _scheduleControlsHide();
  }

  Future<void> _startTemporarySpeed() async {
    if (_sliderInteracting || _temporarySpeedRequested) return;
    _temporarySpeedRequested = true;
    final generation = ++_temporarySpeedGeneration;
    _controlsTimer?.cancel();
    unawaited(
      AppInteractionFeedback.trigger(AppInteractionFeedbackType.confirmation),
    );
    final speedText = ref
        .read(appLanguageProviderInstanceProvider)
        .tr('temporary_double_speed');
    _setFeedback(Icons.speed_rounded, speedText, persistent: true);
    final ok = await _playback.setSessionTemporarySpeed(widget.sessionId, 2.0);
    if (generation != _temporarySpeedGeneration || !_temporarySpeedRequested) {
      await _playback.setSessionTemporarySpeed(widget.sessionId, null);
      return;
    }
    if (!ok) {
      _temporarySpeedRequested = false;
      _setFeedback(Icons.error_outline_rounded, speedText);
      _showOperationFailure();
    }
  }

  Future<void> _restoreTemporarySpeed({bool showFailure = true}) async {
    final shouldClear = _temporarySpeedRequested;
    _temporarySpeedRequested = false;
    _temporarySpeedGeneration++;
    if (!shouldClear) return;
    final ok = await _playback.setSessionTemporarySpeed(widget.sessionId, null);
    if (!ok && showFailure) _showOperationFailure();
    final feedback = _feedback.value;
    if (feedback != null && mounted) {
      _setFeedback(feedback.icon, feedback.text);
      _scheduleControlsHide();
    }
  }

  void _beginControlInteraction() {
    _sliderInteracting = true;
    _controlsTimer?.cancel();
    if (!_controlsVisible) setState(() => _controlsVisible = true);
  }

  void _endProgressInteraction(double value) {
    final target = Duration(milliseconds: value.round());
    setState(() {
      _sliderInteracting = false;
      _sliderPositionMs = null;
    });
    unawaited(_playback.seekSession(widget.sessionId, target));
    _scheduleControlsHide();
  }

  void _endVolumeInteraction(double value) {
    _sliderInteracting = false;
    _dragVolume.value = null;
    UiInteractionCoordinator.instance.cancelThrottledCommit(
      'video_volume:${widget.sessionId}',
    );
    AppInteractionFeedback.resetContinuous();
    unawaited(_commitVolume(value));
    _scheduleControlsHide();
  }

  @override
  Widget build(BuildContext context) {
    final detail = ref.watch(sessionDetailTransportProvider(widget.sessionId));
    final paths = ref.read(audioPathCoordinatorProvider);
    final session = _playback.sessionById(widget.sessionId);
    final track = session == null
        ? null
        : paths.trackByPath(session.currentTrackPath);
    final stillCurrentVideo =
        session != null &&
        track?.isVideo == true &&
        PathMatcher.equalsNormalized(
          session.currentTrackPath,
          widget.trackPath,
        );
    if (!stillCurrentVideo) {
      _exitAfterBuild();
      return const ColoredBox(color: Colors.black);
    }
    final playing = detail?.isPlaying == true;
    _syncPlaying(playing);
    final library = ref.read(libraryFacadeProvider);
    final coverCacheWidth = coverCacheWidthForResolution(
      ref.watch(
        settingsStateProvider.select(
          (state) =>
              state.value?.coverImageResolution ??
              CoverImageResolution.balanced,
        ),
      ),
    );

    return PopScope<void>(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_requestExit());
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: LayoutBuilder(
          builder: (context, constraints) {
            final viewportSize = constraints.biggest;
            return Stack(
              fit: StackFit.expand,
              children: [
                RepaintBoundary(
                  child: SessionVideoBlurredBackdrop(
                    child: AsyncLocalCoverImage(
                      future: _coverFuture ?? Future<String?>.value(),
                      requestKey: 'fullscreen:${widget.sessionId}',
                      initialPath: library.resolvedPlaybackCoverPathForTrack(
                        track,
                      ),
                      retryFutureBuilder: () =>
                          library.playbackCoverPathFutureForTrack(track),
                      seed: track!.displayName,
                      cacheWidth: coverCacheWidth,
                      useDefaultCacheWidth: coverCacheWidth != null,
                      fit: BoxFit.cover,
                      iconSize: 72,
                    ),
                  ),
                ),
                if (_isSessionVideoReady(session, track))
                  NativeSessionVideoSurface(sessionId: widget.sessionId),
                Positioned.fill(
                  left: 24,
                  right: 24,
                  child: GestureDetector(
                    key: const ValueKey<String>(
                      'fullscreen_video_gesture_surface',
                    ),
                    behavior: HitTestBehavior.opaque,
                    onTap: _toggleControls,
                    onDoubleTapDown: (details) =>
                        _doubleTapPosition = details.localPosition,
                    onDoubleTap: _handleDoubleTap,
                    onLongPressStart: (_) => unawaited(_startTemporarySpeed()),
                    onLongPressEnd: (_) => unawaited(_restoreTemporarySpeed()),
                    onLongPressCancel: () =>
                        unawaited(_restoreTemporarySpeed()),
                    onPanStart: (details) => _handlePanStart(
                      details,
                      Size(
                        max(1, viewportSize.width - 48),
                        viewportSize.height,
                      ),
                    ),
                    onPanUpdate: _handlePanUpdate,
                    onPanEnd: (_) => _handlePanEnd(cancelled: false),
                    onPanCancel: () => _handlePanEnd(cancelled: true),
                  ),
                ),
                _buildFeedback(),
                _buildControls(context, session, detail, playing),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildFeedback() {
    return IgnorePointer(
      child: Center(
        child: ValueListenableBuilder<({IconData icon, String text})?>(
          valueListenable: _feedback,
          builder: (context, feedback, _) {
            return AnimatedOpacity(
              key: const ValueKey<String>('fullscreen_video_gesture_feedback'),
              opacity: feedback == null ? 0 : 1,
              duration: const Duration(milliseconds: 120),
              child: Material(
                color: Colors.black.withValues(alpha: 0.68),
                borderRadius: BorderRadius.circular(18),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 22,
                    vertical: 14,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        feedback?.icon ?? Icons.play_arrow_rounded,
                        color: Colors.white,
                        size: 28,
                      ),
                      const SizedBox(width: 10),
                      Text(
                        feedback?.text ?? '',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
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
    );
  }

  Widget _buildControls(
    BuildContext context,
    PlaybackSession session,
    SessionDetailViewState? detail,
    bool playing,
  ) {
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    return AnimatedOpacity(
      key: const ValueKey<String>('fullscreen_video_controls'),
      opacity: _controlsVisible ? 1 : 0,
      duration: const Duration(milliseconds: 160),
      child: IgnorePointer(
        ignoring: !_controlsVisible,
        child: Stack(
          children: [
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.6),
                      Colors.transparent,
                    ],
                  ),
                ),
                child: SafeArea(
                  minimum: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  bottom: false,
                  child: Align(
                    alignment: Alignment.topRight,
                    child: IconButton(
                      key: const ValueKey<String>('fullscreen_video_exit'),
                      tooltip: i18n.tr('exit_fullscreen'),
                      onPressed: _requestExit,
                      color: Colors.white,
                      constraints: const BoxConstraints.tightFor(
                        width: 48,
                        height: 48,
                      ),
                      icon: const Icon(Icons.fullscreen_exit_rounded),
                    ),
                  ),
                ),
              ),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.82),
                    ],
                  ),
                ),
                child: SafeArea(
                  minimum: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  top: false,
                  bottom: false,
                  child: AnimatedBuilder(
                    animation: _controlValues,
                    builder: (context, _) {
                      final snapshot = _positionGate?.value;
                      final duration = snapshot?.duration ?? Duration.zero;
                      final maxMs = max(1, duration.inMilliseconds).toDouble();
                      final positionMs =
                          (_sliderPositionMs ??
                                  snapshot?.position.inMilliseconds.toDouble() ??
                                  0)
                              .clamp(0, maxMs)
                              .toDouble();
                      final volume =
                          (_dragVolume.value ?? detail?.volume ?? session.volume)
                              .clamp(0.0, PlaybackFacade.maxSessionVolume)
                              .toDouble();
                      return Row(
                        children: [
                          IconButton(
                            key: const ValueKey<String>(
                              'fullscreen_video_play_pause',
                            ),
                            tooltip: playing ? i18n.tr('pause') : i18n.tr('play'),
                            onPressed: () {
                              _showControls();
                              unawaited(
                                _playback.toggleSessionPlayPause(widget.sessionId),
                              );
                            },
                            color: Colors.white,
                            iconSize: 30,
                            constraints: const BoxConstraints.tightFor(
                              width: 48,
                              height: 48,
                            ),
                            icon: Icon(
                              playing
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            formatDurationCompact(
                              Duration(milliseconds: positionMs.round()),
                            ),
                            style: const TextStyle(color: Colors.white),
                          ),
                          Expanded(
                            child: Slider(
                              key: const ValueKey<String>(
                                'fullscreen_video_progress',
                              ),
                              max: maxMs,
                              value: positionMs,
                              onChangeStart: duration > Duration.zero
                                  ? (_) => _beginControlInteraction()
                                  : null,
                              onChanged: duration > Duration.zero
                                  ? (value) =>
                                        setState(() => _sliderPositionMs = value)
                                  : null,
                              onChangeEnd: duration > Duration.zero
                                  ? _endProgressInteraction
                                  : null,
                            ),
                          ),
                          Text(
                            formatDurationCompact(duration),
                            style: const TextStyle(color: Colors.white),
                          ),
                          const SizedBox(width: 10),
                          Icon(
                            _volumeIcon(volume),
                            color: Colors.white,
                            semanticLabel: i18n.tr('volume'),
                          ),
                          SizedBox(
                            width: 116,
                            child: Slider(
                              key: const ValueKey<String>(
                                'fullscreen_video_volume',
                              ),
                              max: PlaybackFacade.maxSessionVolume,
                              value: volume,
                              onChangeStart: (_) => _beginControlInteraction(),
                              onChanged: (value) {
                                _dragVolume.value = value;
                                AppInteractionFeedback.continuous(
                                  (value * 100).round(),
                                );
                                UiInteractionCoordinator.instance
                                    .scheduleThrottledCommit(
                                      key: 'video_volume:${widget.sessionId}',
                                      commit: () => _playback.setSessionVolume(
                                        widget.sessionId,
                                        value,
                                        persist: false,
                                      ),
                                    );
                              },
                              onChangeEnd: _endVolumeInteraction,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

IconData _volumeIcon(double volume) {
  if (volume <= 0.001) return Icons.volume_off_rounded;
  if (volume < 0.5) return Icons.volume_down_rounded;
  return Icons.volume_up_rounded;
}
