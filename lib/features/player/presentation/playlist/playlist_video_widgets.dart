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
import '../../../../app/state/subtitle_settings_provider.dart';
import '../../../../app/theme/app_styles.dart';
import '../../../../core/media/music_track.dart';
import '../../../../core/media/path_matcher.dart';
import '../../../../core/media/subtitle_parser.dart';
import '../../../../core/media/time_text_formatters.dart';
import '../../../../core/ui/ui_interaction_coordinator.dart';
import '../../../../core/widgets/app_feedback.dart';
import '../../../../core/widgets/app_buttons.dart';
import '../../../../core/widgets/async_cover_image.dart';
import '../../application/playback_facade.dart';
import '../../application/playback_session_snapshot.dart';
import '../../application/playback_subtitle_service.dart';
import '../playback_error_text.dart';
import '../playback_position_ui_gate.dart';
import '../session_video_surface.dart';
import '../session_video_viewport.dart';
import 'playlist_shared_helpers.dart';
import 'playlist_progress_widgets.dart';
import 'playlist_transport_controls.dart';
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
      slide: false,
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
  static const _controlRowHeight = 48.0;
  static const _controlRowSpacing = 8.0;

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
  bool _tickerModeEnabled = true;
  bool _subtitleEnabled = false;
  bool _exitScheduled = false;
  bool _exitRunning = false;
  bool _allowPop = false;
  bool _sliderInteracting = false;
  bool _controlsHovered = false;
  final _pageFocus = FocusNode();
  final _pastRestartThreshold = ValueNotifier<bool>(false);
  double _brightness = 0.5;
  final _volumePreview = ValueNotifier<double?>(null);
  final _feedback = ValueNotifier<({IconData icon, String text})?>(null);

  Offset _panDelta = Offset.zero;
  _FullscreenVideoPanMode? _panMode;
  SessionVideoVerticalGestureSide? _panVerticalSide;
  Duration _panStartPosition = Duration.zero;
  Duration? _panSeekTarget;
  double _panStartVolumeDisplayValue = 1;
  double _panStartBrightness = 0.5;
  Size _panViewportSize = Size.zero;
  Offset? _doubleTapPosition;
  Offset? _lastPointerPosition;
  Offset? _hiddenAtPointerPosition;

  String get _volumeCommitKey =>
      SessionVolumeControls.commitKey(widget.sessionId);

  bool get _controlsInteracting =>
      _sliderInteracting ||
      _controlsHovered ||
      (_pageFocus.hasFocus && !_pageFocus.hasPrimaryFocus);

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
      )..addListener(_handlePositionGateChanged);
      _pastRestartThreshold.value =
          _positionGate!.value.position.inSeconds > 3;
    }
    _brightness = widget.fullscreenLease.initialBrightness ?? 0.5;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scheduleControlsHide();
    });
  }

  void _handlePositionGateChanged() {
    final past = (_positionGate?.value.position.inSeconds ?? 0) > 3;
    if (_pastRestartThreshold.value != past) {
      _pastRestartThreshold.value = past;
    }
  }

  void _syncPositionGateTickerMode() {
    _positionGate?.tickerModeEnabled =
        _tickerModeEnabled && (_controlsVisible || _subtitleEnabled);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nextTickerMode = TickerMode.valuesOf(context).enabled;
    if (_tickerModeEnabled == nextTickerMode) return;
    _tickerModeEnabled = nextTickerMode;
    _syncPositionGateTickerMode();
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
    _pageFocus.dispose();
    UiInteractionCoordinator.instance
      ..cancelThrottledCommit('video_brightness:${widget.sessionId}')
      ..cancelThrottledCommit(_volumeCommitKey);
    AppInteractionFeedback.resetContinuous();
    final pendingVolume = _volumePreview.value;
    if (pendingVolume != null) {
      unawaited(_playback.setSessionVolume(widget.sessionId, pendingVolume));
    }
    unawaited(_restoreTemporarySpeed(showFailure: false));
    _positionGate?.removeListener(_handlePositionGateChanged);
    _positionGate?.dispose();
    _pastRestartThreshold.dispose();
    _volumePreview.dispose();
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
      ..cancelThrottledCommit(_volumeCommitKey);
    final pendingVolume = _volumePreview.value;
    if (pendingVolume != null) {
      final ok = await _playback.setSessionVolume(
        widget.sessionId,
        pendingVolume,
      );
      if (!ok && _playback.hasSession(widget.sessionId)) {
        _showOperationFailure();
      }
      if (!mounted) return;
      _volumePreview.value = null;
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
      controlsInteracting: _controlsInteracting,
    )) {
      return;
    }
    _controlsTimer = Timer(_controlsTimeout, () {
      if (!mounted ||
          !sessionVideoShouldAutoHideControls(
            controlsVisible: _controlsVisible,
            controlsInteracting: _controlsInteracting,
          )) {
        return;
      }
      _setControlsVisible(false);
    });
  }

  void _setControlsVisible(bool visible) {
    if (_controlsVisible == visible) return;
    if (!visible) {
      _hiddenAtPointerPosition = _lastPointerPosition;
    } else {
      _hiddenAtPointerPosition = null;
    }
    setState(() => _controlsVisible = visible);
    // Keep the shared gate active while subtitles are enabled, and pause
    // notifications whenever both controls and subtitles are inactive.
    _syncPositionGateTickerMode();
  }

  void _showControls() {
    _setControlsVisible(true);
    _scheduleControlsHide();
  }

  void _setControlsHovered(bool hovered) {
    if (_controlsHovered == hovered) return;
    _controlsHovered = hovered;
    if (hovered) {
      _controlsTimer?.cancel();
    } else {
      _scheduleControlsHide();
    }
  }

  void _handleMouseHover(PointerHoverEvent event) {
    _lastPointerPosition = event.localPosition;
    if (!_controlsVisible) {
      final hiddenAt = _hiddenAtPointerPosition;
      if (hiddenAt != null &&
          (event.localPosition - hiddenAt).distance <= 4.0) {
        return;
      }
    }
    _showControls();
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      if (event is KeyDownEvent) {
        unawaited(_requestExit());
      }
      return KeyEventResult.handled;
    }
    final focusContext = FocusManager.instance.primaryFocus?.context;
    if (focusContext?.findAncestorStateOfType<EditableTextState>() != null) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.keyF) {
      if (event is KeyDownEvent) {
        unawaited(_requestExit());
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.space) {
      if (event is! KeyDownEvent) return KeyEventResult.handled;
      final playing =
          _playback.sessionSnapshotById(widget.sessionId)?.playbackRequested ==
          true;
      _setFeedback(
        playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
        ref
            .read(appLanguageProviderInstanceProvider)
            .tr(playing ? 'pause' : 'play'),
      );
      unawaited(_playback.toggleSessionPlayPause(widget.sessionId));
      _scheduleControlsHide();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight) {
      final forward = key == LogicalKeyboardKey.arrowRight;
      final gate = _positionGate;
      if (gate != null &&
          (gate.value.duration ?? Duration.zero) > Duration.zero) {
        final target = sessionVideoSkipTarget(
          position: gate.value.position,
          duration: gate.value.duration ?? Duration.zero,
          delta: Duration(seconds: forward ? 5 : -5),
        );
        unawaited(_playback.seekSession(widget.sessionId, target));
      } else {
        unawaited(
          _playback.seekSessionByOffset(
            widget.sessionId,
            Duration(seconds: forward ? 5 : -5),
          ),
        );
      }
      _setFeedback(
        forward ? Icons.forward_5_rounded : Icons.replay_5_rounded,
        ref
            .read(appLanguageProviderInstanceProvider)
            .tr(
              forward
                  ? 'seek_forward_five_seconds'
                  : 'seek_backward_five_seconds',
            ),
      );
      _scheduleControlsHide();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown) {
      final currentGain =
          _playback.sessionById(widget.sessionId)?.volume ??
          _initialSession?.volume ??
          1.0;
      final currentDisplay = sessionVolumeDisplayValueFromGain(currentGain);
      final delta = key == LogicalKeyboardKey.arrowUp ? 0.05 : -0.05;
      final nextDisplay = (currentDisplay + delta).clamp(
        0.0,
        sessionVolumeDisplayMaximum,
      );
      final nextGain = sessionVolumeGainFromDisplayValue(nextDisplay);
      _setFeedback(
        sessionVolumeIcon(nextGain),
        '${ref.read(appLanguageProviderInstanceProvider).tr('volume')} '
        '${(nextDisplay * 100).round()}%',
      );
      unawaited(_playback.setSessionVolume(widget.sessionId, nextGain));
      _scheduleControlsHide();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyM) {
      if (event is! KeyDownEvent) return KeyEventResult.handled;
      final wasMuted =
          (_playback.sessionById(widget.sessionId)?.volume ?? 1.0) <= 0;
      unawaited(
        _playback.toggleSessionMute(widget.sessionId).then((_) {
          if (!mounted) return;
          final nextGain =
              _playback.sessionById(widget.sessionId)?.volume ??
              (wasMuted ? 1.0 : 0.0);
          final displayPct =
              (sessionVolumeDisplayValueFromGain(nextGain) * 100).round();
          _setFeedback(
            sessionVolumeIcon(nextGain),
            '${ref.read(appLanguageProviderInstanceProvider).tr('volume')} '
            '$displayPct%',
          );
        }),
      );
      _scheduleControlsHide();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
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
      _playback.sessionById(widget.sessionId)?.volume ??
          _initialSession?.volume ??
          1,
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
        _panMode = _FullscreenVideoPanMode.horizontalSeek;
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
        _volumePreview.value = volumeGain;
        AppInteractionFeedback.continuous((displayValue * 100).round());
        _setFeedback(
          sessionVolumeIcon(volumeGain),
          '${ref.read(appLanguageProviderInstanceProvider).tr('volume')} '
          '${(displayValue * 100).round()}%',
          persistent: true,
        );
        UiInteractionCoordinator.instance.scheduleThrottledCommit(
          key: _volumeCommitKey,
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
          _volumeCommitKey,
        );
        final volume = _volumePreview.value;
        _volumePreview.value = null;
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

  void _endControlInteraction() {
    _sliderInteracting = false;
    if (mounted) {
      _scheduleControlsHide();
    }
  }

  EdgeInsets _controlBarPadding(BuildContext context) {
    final safeInsets = MediaQuery.viewPaddingOf(context);
    return EdgeInsets.fromLTRB(
      max(16, safeInsets.left + 8),
      8,
      max(16, safeInsets.right + 8),
      8 + safeInsets.bottom,
    );
  }

  double _bottomControlsHeight(bool stackVolumeControls) => stackVolumeControls
      ? 2 * _controlRowHeight + _controlRowSpacing
      : _controlRowHeight;

  double _controlBarHeight(
    BuildContext context,
    EdgeInsets padding,
    bool stackVolumeControls,
  ) {
    final inlineTimecodes =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final textHeight = MediaQuery.textScalerOf(context).scale(13) * 1.1;
    final timelineHeight = inlineTimecodes
        ? max(20.0, textHeight)
        : 20.0 + max(20.0, textHeight);
    return timelineHeight +
        _controlRowSpacing +
        _bottomControlsHeight(stackVolumeControls) +
        padding.vertical;
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(appLanguageStateProvider);
    final transport = ref.watch(
      sessionDetailTransportProvider(widget.sessionId).select(
        (state) => (
          playing: state?.isPlaying == true,
          loading: state?.isPlaybackLoading == true,
          playbackError: state?.playbackError,
        ),
      ),
    );
    final subtitleEnabled = ref.watch(
      subtitleSettingsProvider.select(
        (state) => state.isShowEnabled(widget.sessionId),
      ),
    );
    ref.watch(
      playbackSessionProvider(widget.sessionId).select(
        (session) => (
          session?.queueVersion,
          session?.currentQueueIndex,
          session?.currentTrackPath,
          session?.loadedPath,
          session?.loopMode,
        ),
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
    _subtitleEnabled = subtitleEnabled;
    if (_positionGate == null) {
      _positionGate = PlaybackPositionUiGate(
        session: activeSession,
        deferDuringInteraction: false,
      )..addListener(_handlePositionGateChanged);
    } else {
      _positionGate!.updateSession(activeSession);
    }
    _syncPositionGateTickerMode();
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
    final baseControlTheme = ref.read(themeProviderInstanceProvider).darkTheme;
    final controlsLabel = ref
        .read(appLanguageProviderInstanceProvider)
        .tr('video_controls');

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
        queueColorValue: activeSession.playbackQueue?.colorValue,
        child: PopScope<void>(
          canPop: _allowPop,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) unawaited(_requestExit());
          },
          child: Focus(
            focusNode: _pageFocus,
            autofocus: true,
            onKeyEvent: _handleKeyEvent,
            onFocusChange: (_) => _scheduleControlsHide(),
            child: Scaffold(
                backgroundColor: Colors.black,
                body: AppPageContentTransition(
                  child: MouseRegion(
                    cursor: _controlsVisible
                        ? MouseCursor.defer
                        : SystemMouseCursors.none,
                    onEnter: (event) =>
                        _lastPointerPosition = event.localPosition,
                    onHover: _handleMouseHover,
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final viewportSize = constraints.biggest;
                        final controlBarPadding = _controlBarPadding(context);
                        // A separate row keeps the track usable beside the mute button.
                        final stackVolumeControls =
                            viewportSize.width - controlBarPadding.horizontal <
                            320;
                        final controlBarHeight = _controlBarHeight(
                          context,
                          controlBarPadding,
                          stackVolumeControls,
                        );
                        final gestureRect = sessionVideoFullscreenGestureRect(
                          viewportSize: viewportSize,
                          controlsVisible: _controlsVisible,
                          controlBarHeight: controlBarHeight,
                        );
                        return Stack(
                          fit: StackFit.expand,
                          children: [
                            SessionVideoBlurredBackdrop(
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
                                cacheWidth: 200,
                                useDefaultCacheWidth: false,
                                fit: BoxFit.cover,
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
                              child: MouseRegion(
                                cursor: _controlsVisible
                                    ? SystemMouseCursors.click
                                    : SystemMouseCursors.none,
                                child: GestureDetector(
                                  key: const ValueKey<String>(
                                    'fullscreen_video_gesture_surface',
                                  ),
                                  excludeFromSemantics: true,
                                  behavior: HitTestBehavior.opaque,
                                  onTapDown: (details) =>
                                      _lastPointerPosition =
                                          gestureRect.topLeft +
                                          details.localPosition,
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
                                  child: SessionVideoControlsTarget(
                                    label: controlsLabel,
                                    controlsVisible: _controlsVisible,
                                    onToggle: _toggleControls,
                                  ),
                                ),
                              ),
                            ),
                            if (subtitleEnabled)
                              AnimatedPositioned(
                                left: 24,
                                right: 24,
                                bottom: _controlsVisible
                                    ? controlBarHeight + 12
                                    : 24 +
                                          MediaQuery.viewPaddingOf(
                                            context,
                                          ).bottom,
                                duration: MediaQuery.disableAnimationsOf(
                                  context,
                                )
                                    ? Duration.zero
                                    : kAppFadeDuration,
                                curve: kAppFadeCurve,
                                child: IgnorePointer(
                                  child: _FullscreenVideoSubtitleOverlay(
                                    session: activeSession,
                                    positionGate: _positionGate!,
                                  ),
                                ),
                              ),
                            _buildFeedback(),
                            if (transport.playbackError != null)
                              _buildErrorBanner(
                                context,
                                playbackError: transport.playbackError!,
                                useAsmrOneText: track?.isRemoteAsmr ?? false,
                              ),
                            Builder(
                              builder: (context) => _buildControls(
                                context,
                                activeSession,
                                playing: transport.playing,
                                loading: transport.loading,
                                padding: controlBarPadding,
                                height: controlBarHeight,
                                stackVolumeControls: stackVolumeControls,
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
      );
  }

  Widget _buildErrorBanner(
    BuildContext context, {
    required String playbackError,
    required bool useAsmrOneText,
  }) {
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Material(
            key: const ValueKey<String>('fullscreen_video_error_banner'),
            color: Colors.black.withValues(alpha: 0.82),
            borderRadius: BorderRadius.circular(18),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: cs.error.withValues(alpha: 0.45)),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.error_outline_rounded, color: cs.error, size: 28),
                  const SizedBox(height: 8),
                  Text(
                    localizedPlaybackErrorText(
                      i18n,
                      playbackError,
                      useAsmrOneText: useAsmrOneText,
                    ),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    key: const ValueKey<String>('fullscreen_video_retry_button'),
                    onPressed: () {
                      _showControls();
                      unawaited(
                        _playback.toggleSessionPlayPause(widget.sessionId),
                      );
                    },
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: Text(i18n.tr('retry')),
                  ),
                ],
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
                  ? const SizedBox.shrink(
                      key: ValueKey<String>('fullscreen_video_feedback_empty'),
                    )
                  : Material(
                      key: const ValueKey<String>(
                        'fullscreen_video_feedback_card',
                      ),
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
    PlaybackSessionSnapshot session, {
    required bool playing,
    required bool loading,
    required EdgeInsets padding,
    required double height,
    required bool stackVolumeControls,
  }) {
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final cs = Theme.of(context).colorScheme;
    final primaryColor = cs.primary;
    final onPrimaryColor = cs.onPrimary;
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
    final exitTooltip = i18n.tr('exit_fullscreen');
    final controls = AnimatedOpacity(
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
              child: MouseRegion(
                onEnter: (_) => _setControlsHovered(true),
                onExit: (_) => _setControlsHovered(false),
                child: AppPageHeaderTransition(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.black.withValues(alpha: 0.6 * 0.9),
                          Colors.transparent,
                        ],
                      ),
                    ),
                    // The app retains system-bar insets while immersive mode is
                    // active, so use the same top origin as other page headers.
                    child: Padding(
                      padding: EdgeInsets.only(
                        right:
                            MediaQuery.paddingOf(context).right +
                            AppPageHeaderMetrics.padding.right +
                            exitButtonOffset,
                        top:
                            MediaQuery.paddingOf(context).top +
                            AppPageHeaderMetrics.padding.top +
                            exitButtonOffset,
                        bottom: 8,
                      ),
                      child: Align(
                        alignment: Alignment.topRight,
                        child: Semantics(
                          container: true,
                          label: TooltipVisibility.of(context)
                              ? null
                              : exitTooltip,
                          child: AppOverlayIconButton(
                            key: const ValueKey<String>(
                              'fullscreen_video_exit',
                            ),
                            tooltip: exitTooltip,
                            onPressed: _requestExit,
                            buttonSize: exitButtonSize,
                            icon: const Icon(Icons.fullscreen_exit_rounded),
                          ),
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
              height: height,
              child: MouseRegion(
                onEnter: (_) => _setControlsHovered(true),
                onExit: (_) => _setControlsHovered(false),
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
                    padding: padding,
                    child: Column(
                      children: [
                        SliderTheme(
                          data: sessionDetailProgressSliderTheme(
                            context,
                            primaryColor,
                          ),
                          child: TickerMode(
                            enabled: _controlsVisible,
                            child: SessionProgressBar(
                              key: const ValueKey('fullscreen_video_progress'),
                              session: session,
                              playback: _playback,
                              inlineTimecodes:
                                  MediaQuery.orientationOf(context) ==
                                  Orientation.landscape,
                              onSeekStart: _beginControlInteraction,
                              onSeekCancel: _endControlInteraction,
                              onManualSeek: (_) => _endControlInteraction(),
                            ),
                          ),
                        ),
                        const SizedBox(height: _controlRowSpacing),
                      SizedBox(
                        height: _bottomControlsHeight(stackVolumeControls),
                        child: Flex(
                          direction: stackVolumeControls
                              ? Axis.vertical
                              : Axis.horizontal,
                          children: [
                            SizedBox(
                              height: _controlRowHeight,
                              child: IconButtonTheme(
                                data: IconButtonThemeData(
                                  style: appIconButtonStyle(
                                    IconButton.styleFrom(
                                      fixedSize: const Size(44, 44),
                                      minimumSize: const Size(44, 44),
                                      padding: EdgeInsets.zero,
                                      tapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap,
                                    ),
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    ValueListenableBuilder<bool>(
                                      valueListenable: _pastRestartThreshold,
                                      builder:
                                          (context, pastRestartThreshold, _) =>
                                              PrimaryTransportButton(
                                                key: const ValueKey<String>(
                                                  'fullscreen_video_previous',
                                                ),
                                                tooltip: i18n.tr(
                                                  'previous_track',
                                                ),
                                                enabled:
                                                    hasPrevious ||
                                                    pastRestartThreshold,
                                                onPressed: () {
                                                  _showControls();
                                                  unawaited(
                                                    AppInteractionFeedback.trigger(
                                                      AppInteractionFeedbackType
                                                          .selection,
                                                    ),
                                                  );
                                                  unawaited(
                                                    _playback.seekSessionToPrev(
                                                      widget.sessionId,
                                                    ),
                                                  );
                                                },
                                                iconSize: 26,
                                                constraints:
                                                    const BoxConstraints.tightFor(
                                                      width: 44,
                                                      height: 44,
                                                    ),
                                                icon:
                                                    Icons.skip_previous_rounded,
                                              ),
                                    ),
                                    const SizedBox(width: 4),
                                    Container(
                                      decoration:
                                          sessionDetailPlayButtonDecoration(
                                            context,
                                            primaryColor,
                                            enabled: true,
                                          ),
                                      child: IconButton(
                                        key: const ValueKey<String>(
                                          'fullscreen_video_play_pause',
                                        ),
                                        tooltip: playing
                                            ? i18n.tr('pause')
                                            : i18n.tr('play'),
                                        onPressed: () {
                                          _showControls();
                                          unawaited(
                                            AppInteractionFeedback.trigger(
                                              AppInteractionFeedbackType
                                                  .confirmation,
                                            ),
                                          );
                                          unawaited(
                                            _playback.toggleSessionPlayPause(
                                              widget.sessionId,
                                            ),
                                          );
                                        },
                                        style: appTransportIconButtonStyle(
                                          IconButton.styleFrom(
                                            fixedSize: const Size(48, 48),
                                            minimumSize: const Size(48, 48),
                                            foregroundColor: onPrimaryColor,
                                            shape: const CircleBorder(),
                                            padding: EdgeInsets.zero,
                                          ),
                                        ),
                                        iconSize: 30,
                                        constraints:
                                            const BoxConstraints.tightFor(
                                              width: 48,
                                              height: 48,
                                            ),
                                        icon: loading && playing
                                            ? SizedBox(
                                                width: 20,
                                                height: 20,
                                                child:
                                                    CircularProgressIndicator(
                                                      strokeWidth: 3,
                                                      color: onPrimaryColor,
                                                    ),
                                              )
                                            : Icon(
                                                playing
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
                                      enabled: hasNext,
                                      onPressed: () {
                                        _showControls();
                                        unawaited(
                                          AppInteractionFeedback.trigger(
                                            AppInteractionFeedbackType
                                                .selection,
                                          ),
                                        );
                                        unawaited(
                                          _playback.seekSessionToNext(
                                            widget.sessionId,
                                          ),
                                        );
                                      },
                                      iconSize: 26,
                                      constraints:
                                          const BoxConstraints.tightFor(
                                            width: 44,
                                            height: 44,
                                          ),
                                      icon: Icons.skip_next_rounded,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(
                              width: 12,
                              height: _controlRowSpacing,
                            ),
                            Expanded(
                              child: Align(
                                alignment: stackVolumeControls
                                    ? Alignment.center
                                    : Alignment.centerRight,
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    maxWidth:
                                        playbackSecondaryControlsWidth -
                                        playbackSecondaryControlButtonWidth,
                                  ),
                                  child: SessionVolumeControls(
                                    session: session,
                                    playback: _playback,
                                    volumePreview: _volumePreview,
                                    onInteractionStart: _beginControlInteraction,
                                    onInteractionEnd: _endControlInteraction,
                                    onOperationFailure: _showOperationFailure,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              ),
            ),
          ],
        ),
      ),
    );
    return ExcludeFocus(
      excluding: !_controlsVisible,
      child: ExcludeSemantics(excluding: !_controlsVisible, child: controls),
    );
  }
}

class _FullscreenVideoSubtitleOverlay extends ConsumerStatefulWidget {
  const _FullscreenVideoSubtitleOverlay({
    required this.session,
    required this.positionGate,
  });

  final PlaybackSessionSnapshot session;
  final PlaybackPositionUiGate positionGate;

  @override
  ConsumerState<_FullscreenVideoSubtitleOverlay> createState() =>
      _FullscreenVideoSubtitleOverlayState();
}

class _FullscreenVideoSubtitleOverlayState
    extends ConsumerState<_FullscreenVideoSubtitleOverlay> {
  late final PlaybackSubtitleService _subtitleService;
  SubtitleTrack? _subtitleTrack;
  String? _loadedPath;
  SubtitleCue? _lastCue;
  String? _lastCueText;
  String? _activeText;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    widget.positionGate.addListener(_handlePositionTick);
    _subtitleService = ref.read(playbackSubtitleServiceProvider)
      ..addListener(_handleSubtitleServiceChanged);
    _loadSubtitles();
  }

  @override
  void didUpdateWidget(covariant _FullscreenVideoSubtitleOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.positionGate != widget.positionGate) {
      oldWidget.positionGate.removeListener(_handlePositionTick);
      widget.positionGate.addListener(_handlePositionTick);
    }
    if (oldWidget.session.id != widget.session.id ||
        _loadedPath != widget.session.currentTrackPath) {
      _loadSubtitles();
    }
  }

  @override
  void dispose() {
    _loadGeneration++;
    _subtitleService.removeListener(_handleSubtitleServiceChanged);
    widget.positionGate.removeListener(_handlePositionTick);
    super.dispose();
  }

  void _loadSubtitles() {
    final generation = ++_loadGeneration;
    final trackPath = widget.session.currentTrackPath;
    _loadedPath = trackPath;
    if (trackPath.isEmpty) {
      _lastCue = null;
      _lastCueText = null;
      if (_subtitleTrack != null || _activeText != null) {
        setState(() {
          _subtitleTrack = null;
          _activeText = null;
        });
      }
      return;
    }
    if (_subtitleService.hasResult(trackPath)) {
      _applyTrack(trackPath, _subtitleService.trackSync(trackPath));
      return;
    }
    unawaited(
      _subtitleService.load(trackPath).then((track) {
        if (!mounted || generation != _loadGeneration) return;
        _applyTrack(trackPath, track);
      }),
    );
  }

  void _handleSubtitleServiceChanged() {
    if (!mounted) return;
    final trackPath = widget.session.currentTrackPath;
    if (trackPath.isEmpty) return;
    if (_subtitleService.hasResult(trackPath)) {
      final updated = _subtitleService.trackSync(trackPath);
      if (!identical(_subtitleTrack, updated) ||
          _subtitleTrack?.offset != updated?.offset) {
        _applyTrack(trackPath, updated);
      }
    } else if (!_subtitleService.isLoading(trackPath)) {
      _loadSubtitles();
    }
  }

  void _applyTrack(String trackPath, SubtitleTrack? track) {
    if (!mounted || _loadedPath != trackPath) return;
    final nextText = _cueTextAt(track, widget.positionGate.value.position);
    if (identical(_subtitleTrack, track) && _activeText == nextText) return;
    setState(() {
      _subtitleTrack = track;
      _activeText = nextText;
    });
  }

  void _handlePositionTick() {
    final nextText = _cueTextAt(
      _subtitleTrack,
      widget.positionGate.value.position,
    );
    if (_activeText == nextText) return;
    setState(() => _activeText = nextText);
  }

  String? _cueTextAt(SubtitleTrack? track, Duration position) {
    final cue = track?.cueAt(position);
    if (identical(cue, _lastCue)) return _lastCueText;
    _lastCue = cue;
    final raw = cue?.text.trim();
    _lastCueText = (raw == null || raw.isEmpty) ? null : raw;
    return _lastCueText;
  }

  @override
  Widget build(BuildContext context) {
    final text = _activeText;
    if (text == null) return const SizedBox.shrink();
    final fontSize = ref.watch(
      subtitleSettingsProvider.select((state) => state.fontSize),
    );
    final fontFamily = ref.watch(
      subtitleSettingsProvider.select((state) => state.fontFamily),
    );
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: DecoratedBox(
          key: const ValueKey<String>('fullscreen_video_subtitle_overlay'),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.68),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            child: Text(
              text,
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white,
                fontSize: fontSize.clamp(13.0, 28.0),
                fontFamily: fontFamily.isEmpty ? null : fontFamily,
                fontWeight: FontWeight.w600,
                height: 1.35,
                shadows: const [
                  Shadow(
                    blurRadius: 4,
                    offset: Offset(0, 1),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
