import '../../../../core/widgets/app_transitions.dart';
import '../../../library/presentation/library_providers.dart';
import '../playback_providers.dart';
import '../../../settings/presentation/settings_providers.dart';
import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/presentation/app_orientation_controller.dart';
import '../../../../app/presentation/app_presentation_providers.dart';
import '../../../../app/state/app_runtime_providers.dart';
import '../../../../app/theme/app_styles.dart';
import '../../../../core/media/music_track.dart';
import '../../../../core/media/path_matcher.dart';
import '../../../../core/media/time_text_formatters.dart';
import '../../../../core/ui/ui_interaction_coordinator.dart';
import '../../../../core/widgets/app_feedback.dart';
import '../../../../core/widgets/app_glass_surface.dart';
import '../../../../core/widgets/async_cover_image.dart';
import '../../../settings/application/settings_state.dart';
import '../../application/playback_facade.dart';
import '../../application/playback_session_snapshot.dart';
import '../playback_position_ui_gate.dart';
import '../playlist_view_models.dart';
import '../session_video_surface.dart';
import '../session_video_viewport.dart';
import 'playlist_shared_helpers.dart';
import 'playlist_transport_controls.dart';
import 'playlist_volume_timer_widgets.dart';
import 'session_detail_theme.dart';

bool isSessionVideoReady(PlaybackSessionSnapshot session, MusicTrack? track) {
  final loadedPath = session.loadedPath;
  return (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.windows) &&
      track?.isVideo == true &&
      loadedPath != null &&
      PathMatcher.equalsNormalized(loadedPath, track!.path);
}

bool shouldKeepSessionVideoFullscreen({
  required bool sessionExists,
  required bool currentTrackIsVideo,
}) => sessionExists && currentTrackIsVideo;

Future<void> showSessionVideoFullscreen(
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
    final route = buildAppPageRoute<void>(
      context: context,
      fullscreenDialog: true,
      child: SessionVideoFullscreenPage(
        sessionId: sessionId,
        trackPath: trackPath,
        fullscreenLease: lease,
      ),
    );
    await Navigator.of(context).push<void>(route);
    // Keep the inline surface detached until the fullscreen surface is removed.
    await route.completed;
  } finally {
    await playback.setSessionTemporarySpeed(sessionId, null);
    await lease.release();
  }
}

enum _FullscreenVideoPanMode { horizontalSeek, brightness, volume, ignored }

class SessionVideoFullscreenPage extends ConsumerStatefulWidget {
  const SessionVideoFullscreenPage({
    super.key,
    required this.sessionId,
    required this.trackPath,
    required this.fullscreenLease,
  });

  final String sessionId;
  final String trackPath;
  final AppVideoFullscreenLease fullscreenLease;

  @override
  ConsumerState<SessionVideoFullscreenPage> createState() =>
      _SessionVideoFullscreenPageState();
}

class _SessionVideoFullscreenPageState
    extends ConsumerState<SessionVideoFullscreenPage>
    with WidgetsBindingObserver {
  static const _controlsTimeout = Duration(seconds: 3);
  static const _feedbackTimeout = Duration(milliseconds: 800);
  static const _gestureThreshold = 8.0;

  late final PlaybackFacade _playback;
  PlaybackSessionSnapshot? _initialSession;
  PlaybackPositionUiGate? _positionGate;
  late Future<String?> _coverFuture;
  String? _activeTrackPath;
  String? _activeCoverScope;
  ({int epoch, int revision})? _activeCoverRevision;
  Timer? _controlsTimer;
  Timer? _feedbackTimer;
  bool _controlsVisible = true;
  bool _exitScheduled = false;
  bool _exitRunning = false;
  bool _allowPop = false;
  bool _sliderInteracting = false;
  final _sliderPositionMs = ValueNotifier<double?>(null);
  double _brightness = 0.5;
  final _dragVolume = ValueNotifier<double?>(null);
  final _feedback = ValueNotifier<({IconData icon, String text})?>(null);
  late final Listenable _controlValues;

  Offset _panDelta = Offset.zero;
  _FullscreenVideoPanMode? _panMode;
  SessionVideoGestureZone? _panZone;
  SessionVideoVerticalGestureSide? _panVerticalSide;
  Duration _panStartPosition = Duration.zero;
  Duration? _panSeekTarget;
  double _panStartVolumeDisplayValue = 1;
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
    _initialSession = _playback.sessionSnapshotById(widget.sessionId);
    final session = _initialSession;
    if (session != null) {
      _positionGate = PlaybackPositionUiGate(
        session: session,
        deferDuringInteraction: false,
      );
    }
    _controlValues = Listenable.merge([
      ?_positionGate,
      _sliderPositionMs,
      _dragVolume,
    ]);
    _brightness = widget.fullscreenLease.initialBrightness ?? 0.5;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scheduleControlsHide();
    });
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
    _sliderPositionMs.dispose();
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
      if (!ok && _playback.hasSession(widget.sessionId)) {
        _showOperationFailure();
      }
      _dragVolume.value = null;
    }
    await _restoreTemporarySpeed(showFailure: false);
    if (!mounted) return;
    setState(() => _allowPop = true);
    Navigator.of(context).pop();
  }

  void _scheduleControlsHide() {
    _controlsTimer?.cancel();
    if (!sessionVideoShouldAutoHideControls(
      controlsVisible: _controlsVisible,
      controlsInteracting: _sliderInteracting,
    )) {
      return;
    }
    _controlsTimer = Timer(_controlsTimeout, () {
      if (!mounted ||
          !sessionVideoShouldAutoHideControls(
            controlsVisible: _controlsVisible,
            controlsInteracting: _sliderInteracting,
          )) {
        return;
      }
      _setControlsVisible(false);
    });
  }

  void _setControlsVisible(bool visible) {
    if (_controlsVisible == visible) return;
    setState(() => _controlsVisible = visible);
    // The gate retains the latest position for gestures without rebuilding
    // hidden controls, then publishes it immediately when controls return.
    _positionGate?.tickerModeEnabled = visible;
  }

  void _showControls() {
    _controlsTimer?.cancel();
    _setControlsVisible(true);
    _scheduleControlsHide();
  }

  void _toggleControls() {
    _controlsTimer?.cancel();
    _setControlsVisible(
      sessionVideoControlsVisibleAfterBlankTap(_controlsVisible),
    );
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
    _panZone = sessionVideoGestureZone(
      details.localPosition.dx,
      viewportSize.width,
    );
    _panVerticalSide = sessionVideoVerticalGestureSide(
      details.localPosition.dx,
      viewportSize.width,
    );
    _panStartPosition =
        _positionGate?.value.position ??
        _initialSession?.position ??
        Duration.zero;
    _panSeekTarget = null;
    _panStartVolumeDisplayValue = sessionVolumeDisplayValueFromGain(
      _initialSession?.volume ?? 1,
    );
    _panStartBrightness = _brightness;
    _panViewportSize = viewportSize;
  }

  void _handlePanUpdate(DragUpdateDetails details) {
    if (_sliderInteracting) return;
    _panDelta += details.delta;
    if (_panMode == null) {
      if (_panDelta.distance < _gestureThreshold) return;
      if (_panDelta.dx.abs() >= _panDelta.dy.abs()) {
        _panMode = _panZone == SessionVideoGestureZone.center
            ? _FullscreenVideoPanMode.ignored
            : _FullscreenVideoPanMode.horizontalSeek;
      } else {
        _panMode = _panVerticalSide == SessionVideoVerticalGestureSide.left
            ? widget.fullscreenLease.initialBrightness == null
                  ? _FullscreenVideoPanMode.ignored
                  : _FullscreenVideoPanMode.brightness
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
        final displayValue = sessionVideoVerticalGestureValue(
          startValue: _panStartVolumeDisplayValue,
          dragDy: _panDelta.dy,
          viewportHeight: _panViewportSize.height,
          minimum: 0,
          maximum: sessionVolumeDisplayMaximum,
        );
        final volumeGain = sessionVolumeGainFromDisplayValue(displayValue);
        _dragVolume.value = volumeGain;
        AppInteractionFeedback.continuous((displayValue * 100).round());
        _setFeedback(
          _volumeIcon(volumeGain),
          '${ref.read(appLanguageProviderInstanceProvider).tr('volume')} '
          '${(displayValue * 100).round()}%',
          persistent: true,
        );
        UiInteractionCoordinator.instance.scheduleThrottledCommit(
          key: 'video_volume:${widget.sessionId}',
          commit: () => _playback.setSessionVolume(
            widget.sessionId,
            volumeGain,
            persist: false,
          ),
        );
        break;
      case _FullscreenVideoPanMode.ignored:
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
      case _FullscreenVideoPanMode.ignored:
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
    if (position == null) return;
    final zone = sessionVideoGestureZone(
      position.dx,
      max(1, MediaQuery.sizeOf(context).width - 48),
    );
    if (zone == SessionVideoGestureZone.center) {
      final playing =
          _playback.sessionSnapshotById(widget.sessionId)?.playbackRequested ==
          true;
      unawaited(
        AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection),
      );
      _setFeedback(
        playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
        ref
            .read(appLanguageProviderInstanceProvider)
            .tr(playing ? 'pause' : 'play'),
      );
      unawaited(_playback.toggleSessionPlayPause(widget.sessionId));
      _scheduleControlsHide();
      return;
    }
    final gate = _positionGate;
    if (gate == null ||
        (gate.value.duration ?? Duration.zero) <= Duration.zero) {
      return;
    }
    final delta = zone == SessionVideoGestureZone.left
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
      zone == SessionVideoGestureZone.left
          ? Icons.replay_5_rounded
          : Icons.forward_5_rounded,
      ref
          .read(appLanguageProviderInstanceProvider)
          .tr(
            zone == SessionVideoGestureZone.left
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
    _setControlsVisible(true);
  }

  void _endProgressInteraction(double value) {
    final target = Duration(milliseconds: value.round());
    _sliderInteracting = false;
    _sliderPositionMs.value = null;
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

  double _controlBarHeight(BuildContext context) {
    final timeHeight = max(
      24.0,
      MediaQuery.textScalerOf(context).scale(13) * 1.1,
    );
    return sessionVideoFullscreenControlBarHeight +
        timeHeight -
        24 +
        MediaQuery.viewPaddingOf(context).bottom;
  }

  @override
  Widget build(BuildContext context) {
    final detail = ref.watch(sessionDetailTransportProvider(widget.sessionId));
    ref.watch(
      playbackSessionProvider(widget.sessionId).select(
        (session) => (session?.queueVersion, session?.currentQueueIndex),
      ),
    );
    ref.watch(
      libraryStateProvider.select((state) => state.value?.contentRevision),
    );
    final paths = ref.read(audioPathCoordinatorProvider);
    final allowVideoPlayback = ref.watch(
      settingsStateProvider.select(
        (state) => state.value?.allowVideoPlayback ?? true,
      ),
    );
    final session = _playback.sessionSnapshotById(widget.sessionId);
    final activeSession = session;
    final track = activeSession == null
        ? null
        : paths.trackByPath(activeSession.currentTrackPath);
    if (!allowVideoPlayback ||
        activeSession == null ||
        !shouldKeepSessionVideoFullscreen(
          sessionExists: true,
          currentTrackIsVideo: track?.isVideo == true,
        )) {
      _exitAfterBuild();
      return const ColoredBox(color: Colors.black);
    }
    final library = ref.read(libraryFacadeProvider);
    final coverCache = library.coverArtworkCacheService;
    final coverScope =
        coverCache.coverSearchKeyForTrack(
          track,
          trackPath: activeSession.currentTrackPath,
        ) ??
        activeSession.currentTrackPath;
    final coverRevision = ref.watch(
      coverGenerationProvider.select(
        (_) => coverCache.revisionForScope(coverScope),
      ),
    );
    if (coverRevision != _activeCoverRevision ||
        coverScope != _activeCoverScope ||
        _activeTrackPath == null ||
        !PathMatcher.equalsNormalized(
          activeSession.currentTrackPath,
          _activeTrackPath!,
        )) {
      _activeTrackPath = activeSession.currentTrackPath;
      _activeCoverScope = coverScope;
      _activeCoverRevision = coverRevision;
      _coverFuture = library.playbackCoverPathFutureForTrack(track);
    }
    final playing = detail?.isPlaying == true;
    final coverCacheWidth = coverCacheWidthForResolution(
      ref.watch(
        settingsStateProvider.select(
          (state) =>
              state.value?.coverImageResolution ??
              CoverImageResolution.balanced,
        ),
      ),
    );
    final baseControlTheme = ref.read(themeProviderInstanceProvider).darkTheme;

    return Theme(
      data: baseControlTheme,
      child: SessionDetailTheme(
        coverPathFuture: _coverFuture,
        initialCoverPath: library.resolvedPlaybackCoverPathForTrack(track),
        requestKey: activeSession.currentTrackPath,
        coverRevision: (
          scope: coverScope,
          epoch: coverRevision.epoch,
          revision: coverRevision.revision,
        ),
        isAsmr: track?.usesAsmrVisualTheme == true,
        queueColorValue: activeSession.playbackQueue?.colorValue,
        child: PopScope<void>(
          canPop: _allowPop,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) unawaited(_requestExit());
          },
          child: CallbackShortcuts(
            bindings: <ShortcutActivator, VoidCallback>{
              const SingleActivator(LogicalKeyboardKey.escape): () {
                unawaited(_requestExit());
              },
            },
            child: Focus(
              autofocus: true,
              child: Scaffold(
                backgroundColor: Colors.black,
                body: AppPageContentTransition(
                  child: MouseRegion(
                    onHover: (_) => _showControls(),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final viewportSize = constraints.biggest;
                        final gestureRect = sessionVideoFullscreenGestureRect(
                          viewportSize: viewportSize,
                          controlsVisible: _controlsVisible,
                          controlBarHeight: _controlBarHeight(context),
                        );
                        return Stack(
                          fit: StackFit.expand,
                          children: [
                            RepaintBoundary(
                              child: SessionVideoBlurredBackdrop(
                                child: AsyncLocalCoverImage(
                                  onImageError: library
                                      .coverArtworkCacheService
                                      .reportArtworkReadFailure,
                                  future: _coverFuture,
                                  requestKey: (
                                    activeSession.currentTrackPath,
                                    coverRevision,
                                  ),
                                  initialPath: library
                                      .resolvedPlaybackCoverPathForTrack(track),
                                  retryFutureBuilder: () => library
                                      .playbackCoverPathFutureForTrack(track),
                                  cacheWidth: coverCacheWidth,
                                  useDefaultCacheWidth: coverCacheWidth != null,
                                  fit: BoxFit.cover,
                                ),
                              ),
                            ),
                            if (isSessionVideoReady(activeSession, track))
                              NativeSessionVideoSurface(
                                sessionId: widget.sessionId,
                                nativeRepository: ref
                                    .read(playbackFacadeProvider)
                                    .nativeRepository,
                              ),
                            Positioned.fromRect(
                              rect: gestureRect,
                              child: GestureDetector(
                                key: const ValueKey<String>(
                                  'fullscreen_video_gesture_surface',
                                ),
                                behavior: HitTestBehavior.opaque,
                                onTap: _toggleControls,
                                onDoubleTapDown: (details) =>
                                    _doubleTapPosition = details.localPosition,
                                onDoubleTap: _handleDoubleTap,
                                onLongPressStart: (_) =>
                                    unawaited(_startTemporarySpeed()),
                                onLongPressEnd: (_) =>
                                    unawaited(_restoreTemporarySpeed()),
                                onLongPressCancel: () =>
                                    unawaited(_restoreTemporarySpeed()),
                                onPanStart: (details) => _handlePanStart(
                                  details,
                                  Size(
                                    max(1, gestureRect.width),
                                    max(1, gestureRect.height),
                                  ),
                                ),
                                onPanUpdate: _handlePanUpdate,
                                onPanEnd: (_) =>
                                    _handlePanEnd(cancelled: false),
                                onPanCancel: () =>
                                    _handlePanEnd(cancelled: true),
                              ),
                            ),
                            _buildFeedback(),
                            Builder(
                              builder: (context) => _buildControls(
                                context,
                                activeSession,
                                detail,
                                playing,
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
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
            return AnimatedSwitcher(
              switchOutCurve: kAppFadeCurve,
              switchInCurve: kAppFadeCurve,
              key: const ValueKey<String>('fullscreen_video_gesture_feedback'),
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : kAppFadeDuration,
              child: feedback == null
                  ? const SizedBox.shrink()
                  : Material(
                      key: ValueKey<(IconData, String)>((
                        feedback.icon,
                        feedback.text,
                      )),
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
                            Icon(feedback.icon, color: Colors.white, size: 28),
                            const SizedBox(width: 10),
                            Text(
                              feedback.text,
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
    PlaybackSessionSnapshot session,
    SessionDetailViewState? detail,
    bool playing,
  ) {
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final cs = Theme.of(context).colorScheme;
    final primaryColor = cs.primary;
    final onPrimaryColor = cs.onPrimary;
    final showPauseIcon = detail?.showPauseIcon ?? playing;
    final hasPrevious = _playback.hasSessionAdjacentTrack(
      widget.sessionId,
      forward: false,
    );
    final hasNext = _playback.hasSessionAdjacentTrack(
      widget.sessionId,
      forward: true,
    );
    const exitButtonSize = 48.0;
    const exitButtonOffset =
        (AppPageHeaderMetrics.buttonSize - exitButtonSize) / 2;
    return AnimatedOpacity(
      curve: kAppFadeCurve,
      key: const ValueKey<String>('fullscreen_video_controls'),
      opacity: _controlsVisible ? 1 : 0,
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : kAppFadeDuration,
      child: IgnorePointer(
        ignoring: !_controlsVisible,
        child: Stack(
          children: [
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: AppPageHeaderTransition(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.6 * 0.6),
                        Colors.transparent,
                      ],
                    ),
                  ),
                  // The app retains system-bar insets while immersive mode is
                  // active, so use the same top origin as other page headers.
                  child: Padding(
                    padding: EdgeInsets.only(
                      left:
                          AppPageHeaderMetrics.padding.left + exitButtonOffset,
                      top:
                          MediaQuery.paddingOf(context).top +
                          AppPageHeaderMetrics.padding.top +
                          exitButtonOffset,
                      bottom: 8,
                    ),
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: AppGlassSurface(
                        backgroundColor: Colors.black,
                        borderRadius: BorderRadius.circular(exitButtonSize / 2),
                        child: IconButton(
                          key: const ValueKey<String>('fullscreen_video_exit'),
                          tooltip: i18n.tr('exit_fullscreen'),
                          onPressed: _requestExit,
                          color: Colors.white,
                          constraints: const BoxConstraints.tightFor(
                            width: exitButtonSize,
                            height: exitButtonSize,
                          ),
                          icon: const Icon(Icons.arrow_back_rounded),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: _controlBarHeight(context),
              child: DecoratedBox(
                key: const ValueKey<String>('fullscreen_video_control_bar'),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.92),
                    ],
                  ),
                ),
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    max(16, MediaQuery.viewPaddingOf(context).left + 8),
                    8,
                    max(16, MediaQuery.viewPaddingOf(context).right + 8),
                    8 + MediaQuery.viewPaddingOf(context).bottom,
                  ),
                  child: AnimatedBuilder(
                    animation: _controlValues,
                    builder: (context, _) {
                      final snapshot = _positionGate?.value;
                      final duration = snapshot?.duration ?? Duration.zero;
                      final maxMs = max(1, duration.inMilliseconds).toDouble();
                      final positionMs =
                          (_sliderPositionMs.value ??
                                  snapshot?.position.inMilliseconds
                                      .toDouble() ??
                                  0)
                              .clamp(0, maxMs)
                              .toDouble();
                      final volumeGain =
                          (_dragVolume.value ??
                                  detail?.volume ??
                                  session.volume)
                              .clamp(0.0, PlaybackFacade.maxSessionVolume)
                              .toDouble();
                      final displayVolume = sessionVolumeDisplayValueFromGain(
                        volumeGain,
                      );
                      final canPrevious =
                          (snapshot != null &&
                              snapshot.position.inSeconds > 3) ||
                          hasPrevious;
                      final canNext = hasNext;

                      final timeline = SliderTheme(
                        data:
                            sessionDetailProgressSliderTheme(
                              context,
                              primaryColor,
                            ).copyWith(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                            ),
                        child: Column(
                          children: [
                            SizedBox(
                              height: 32,
                              child: Slider(
                                key: const ValueKey<String>(
                                  'fullscreen_video_progress',
                                ),
                                semanticFormatterCallback: (value) =>
                                    formatDurationCompact(
                                      Duration(milliseconds: value.round()),
                                    ),
                                max: maxMs,
                                value: positionMs,
                                onChangeStart: duration > Duration.zero
                                    ? (_) => _beginControlInteraction()
                                    : null,
                                onChanged: duration > Duration.zero
                                    ? (value) => _sliderPositionMs.value = value
                                    : null,
                                onChangeEnd: duration > Duration.zero
                                    ? _endProgressInteraction
                                    : null,
                              ),
                            ),
                            SizedBox(
                              height: max(
                                24.0,
                                MediaQuery.textScalerOf(context).scale(13) *
                                    1.1,
                              ),
                              child: Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Flexible(
                                    child: FittedBox(
                                      fit: BoxFit.scaleDown,
                                      alignment: Alignment.centerLeft,
                                      child: TimecodeLabel(
                                        key: const ValueKey<String>(
                                          'fullscreen_video_current_time',
                                        ),
                                        text: formatDurationCompact(
                                          Duration(
                                            milliseconds: positionMs.round(),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Flexible(
                                    child: FittedBox(
                                      fit: BoxFit.scaleDown,
                                      alignment: Alignment.centerRight,
                                      child: TimecodeLabel(
                                        key: const ValueKey<String>(
                                          'fullscreen_video_duration',
                                        ),
                                        text: formatDurationCompact(duration),
                                        alignEnd: true,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                      final transport = IconButtonTheme(
                        data: IconButtonThemeData(
                          style: IconButton.styleFrom(
                            fixedSize: const Size(44, 44),
                            minimumSize: const Size(44, 44),
                            padding: EdgeInsets.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            PrimaryTransportButton(
                              key: const ValueKey<String>(
                                'fullscreen_video_previous',
                              ),
                              tooltip: i18n.tr('previous_track'),
                              enabled: canPrevious,
                              onPressed: () {
                                _showControls();
                                unawaited(
                                  AppInteractionFeedback.trigger(
                                    AppInteractionFeedbackType.selection,
                                  ),
                                );
                                unawaited(
                                  _playback.seekSessionToPrev(widget.sessionId),
                                );
                              },
                              iconSize: 26,
                              constraints: const BoxConstraints.tightFor(
                                width: 44,
                                height: 44,
                              ),
                              icon: Icons.skip_previous_rounded,
                            ),
                            const SizedBox(width: 4),
                            Container(
                              decoration: sessionDetailPlayButtonDecoration(
                                context,
                                primaryColor,
                                enabled: true,
                              ),
                              child: IconButton(
                                key: const ValueKey<String>(
                                  'fullscreen_video_play_pause',
                                ),
                                tooltip: showPauseIcon
                                    ? i18n.tr('pause')
                                    : i18n.tr('play'),
                                onPressed: () {
                                  _showControls();
                                  unawaited(
                                    _playback.toggleSessionPlayPause(
                                      widget.sessionId,
                                    ),
                                  );
                                },
                                style: IconButton.styleFrom(
                                  fixedSize: const Size(48, 48),
                                  minimumSize: const Size(48, 48),
                                  foregroundColor: onPrimaryColor,
                                  shape: const CircleBorder(),
                                  padding: EdgeInsets.zero,
                                ),
                                iconSize: 30,
                                constraints: const BoxConstraints.tightFor(
                                  width: 48,
                                  height: 48,
                                ),
                                icon:
                                    detail?.isPlaybackLoading == true &&
                                        showPauseIcon
                                    ? SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 3,
                                          color: onPrimaryColor,
                                        ),
                                      )
                                    : Icon(
                                        showPauseIcon
                                            ? Icons.pause_rounded
                                            : Icons.play_arrow_rounded,
                                      ),
                              ),
                            ),
                            const SizedBox(width: 4),
                            PrimaryTransportButton(
                              key: const ValueKey<String>(
                                'fullscreen_video_next',
                              ),
                              tooltip: i18n.tr('next_track'),
                              enabled: canNext,
                              onPressed: () {
                                _showControls();
                                unawaited(
                                  AppInteractionFeedback.trigger(
                                    AppInteractionFeedbackType.selection,
                                  ),
                                );
                                unawaited(
                                  _playback.seekSessionToNext(widget.sessionId),
                                );
                              },
                              iconSize: 26,
                              constraints: const BoxConstraints.tightFor(
                                width: 44,
                                height: 44,
                              ),
                              icon: Icons.skip_next_rounded,
                            ),
                          ],
                        ),
                      );
                      final volumeSlider = Slider(
                        key: const ValueKey<String>('fullscreen_video_volume'),
                        semanticFormatterCallback: (value) =>
                            '${(value * 100).round()}%',
                        max: sessionVolumeDisplayMaximum,
                        value: displayVolume,
                        onChangeStart: (_) => _beginControlInteraction(),
                        onChanged: (displayValue) {
                          final volumeGain = sessionVolumeGainFromDisplayValue(
                            displayValue,
                          );
                          _dragVolume.value = volumeGain;
                          AppInteractionFeedback.continuous(
                            (displayValue * 100).round(),
                          );
                          UiInteractionCoordinator.instance
                              .scheduleThrottledCommit(
                                key: 'video_volume:${widget.sessionId}',
                                commit: () => _playback.setSessionVolume(
                                  widget.sessionId,
                                  volumeGain,
                                  persist: false,
                                ),
                              );
                        },
                        onChangeEnd: (value) => _endVolumeInteraction(
                          sessionVolumeGainFromDisplayValue(value),
                        ),
                      );
                      return SliderTheme(
                        data:
                            sessionDetailVolumeSliderTheme(
                              context,
                              isBoosted: volumeGain > 1,
                            ).copyWith(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                            ),
                        child: Column(
                          children: [
                            timeline,
                            const SizedBox(height: 8),
                            SizedBox(
                              height: 48,
                              child: LayoutBuilder(
                                builder: (context, constraints) => Row(
                                  children: [
                                    transport,
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Align(
                                        alignment: Alignment.centerRight,
                                        child: ConstrainedBox(
                                          constraints: const BoxConstraints(
                                            maxWidth: 240,
                                          ),
                                          child: Row(
                                            children: [
                                              Icon(
                                                _volumeIcon(volumeGain),
                                                size: 18,
                                                color: volumeGain > 1
                                                    ? cs.primary
                                                    : sessionDetailForeground(
                                                        cs,
                                                        SessionDetailForegroundLevel
                                                            .muted,
                                                      ),
                                                semanticLabel: i18n.tr(
                                                  'volume',
                                                ),
                                              ),
                                              Expanded(child: volumeSlider),
                                              if (constraints.maxWidth >= 480)
                                                SizedBox(
                                                  width: 56,
                                                  child: Text(
                                                    '${(displayVolume * 100).round()}%',
                                                    key: const ValueKey<String>(
                                                      'fullscreen_video_volume_value',
                                                    ),
                                                    textAlign: TextAlign.right,
                                                    style: Theme.of(context)
                                                        .textTheme
                                                        .labelSmall
                                                        ?.copyWith(
                                                          fontWeight:
                                                              FontWeight.w900,
                                                          fontSize: 11,
                                                          color: volumeGain > 1
                                                              ? cs.primary
                                                              : null,
                                                        ),
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
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
