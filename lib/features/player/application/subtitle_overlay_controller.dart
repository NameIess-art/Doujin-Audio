import 'dart:async';

import '../../../core/platform/subtitle_overlay_platform_service.dart';
import '../../../core/logging/app_log_service.dart';
import 'playback_session.dart';
import 'playback_subtitle_service.dart';

typedef SubtitleOverlayStopTimerFactory =
    Timer Function(Duration duration, void Function() callback);

bool shouldRequestSubtitleOverlayPermission({required bool isAndroid}) {
  return isAndroid;
}

typedef SubtitleOverlayRuntimeStyle = ({
  double? fontSize,
  String? backgroundColor,
  String? textColor,
  double? backgroundOpacity,
  String? fontFamily,
  double? borderDepth,
});

final class SubtitleOverlayController {
  SubtitleOverlayController({
    SubtitleOverlayPlatformService? platform,
    SubtitleOverlayStopTimerFactory? stopTimerFactory,
  }) : _platform = platform ?? SubtitleOverlayPlatformService(),
       _stopTimerFactory = stopTimerFactory ?? Timer.new;

  final SubtitleOverlayPlatformService _platform;
  final SubtitleOverlayStopTimerFactory _stopTimerFactory;
  Timer? _stopTimer;
  bool _disposed = false;
  int _commandGeneration = 0;

  bool _runtimeRunning = false;
  bool _runtimeSyncing = false;
  bool _runtimeSyncPending = false;
  int _runtimeGeneration = 0;
  StreamSubscription<Duration>? _runtimePositionSubscription;
  PlaybackSession? _observedRuntimeSession;
  PlaybackSubtitleService? _observedRuntimeSubtitles;
  String? _runtimeSessionId;
  String? _runtimeTrackPath;
  String? _lastRuntimeText;
  bool Function()? _isRuntimeEnabled;
  PlaybackSession? Function()? _runtimeSession;
  PlaybackSubtitleService Function()? _runtimeSubtitles;
  SubtitleOverlayRuntimeStyle Function()? _runtimeStyle;
  bool get _runtimeEnabled => !_disposed && _isRuntimeEnabled?.call() == true;

  void attachRuntime({
    required bool Function() enabled,
    required PlaybackSession? Function() session,
    required PlaybackSubtitleService Function() subtitles,
    required SubtitleOverlayRuntimeStyle Function() style,
  }) {
    _isRuntimeEnabled = enabled;
    _runtimeSession = session;
    _runtimeSubtitles = subtitles;
    _runtimeStyle = style;
  }

  Future<void> detachRuntime() {
    final stopped = stopRuntime(immediate: true);
    _isRuntimeEnabled = null;
    _runtimeSession = null;
    _runtimeSubtitles = null;
    _runtimeStyle = null;
    return stopped;
  }

  void requestRuntimeSync() {
    _runtimeGeneration++;
    unawaited(_syncRuntime());
  }

  bool _isRuntimeRequestCurrent(
    int generation,
    String sessionId,
    String trackPath,
  ) {
    if (!_runtimeEnabled || generation != _runtimeGeneration) {
      return false;
    }
    final session = _runtimeSession?.call();
    return session?.id == sessionId && session?.currentTrackPath == trackPath;
  }

  Future<void> _syncRuntime() async {
    if (_runtimeSyncing) {
      _runtimeSyncPending = true;
      return;
    }
    if (!_runtimeEnabled) {
      return;
    }
    final generation = _runtimeGeneration;
    _runtimeSyncing = true;
    try {
      final session = _runtimeSession?.call();
      if (session == null) {
        await stopRuntime(immediate: true);
        return;
      }
      final sessionId = session.id;
      final trackPath = session.currentTrackPath;
      if (!_runtimeRunning) {
        final canDraw = await canDrawOverlays();
        if (!_isRuntimeRequestCurrent(generation, sessionId, trackPath)) return;
        if (!canDraw) {
          await stopRuntime(immediate: true);
          return;
        }
        final started = await startOverlay();
        if (!started ||
            !_isRuntimeRequestCurrent(generation, sessionId, trackPath)) {
          if (started) await stopOverlay(immediate: true);
          return;
        }
        _runtimeRunning = true;
      }
      await _applyRuntimeStyle();
      if (!_isRuntimeRequestCurrent(generation, sessionId, trackPath)) return;
      _bindRuntimeSession(session);
      _updateRuntimeSession(session);
    } finally {
      _runtimeSyncing = false;
      if (_runtimeSyncPending && _runtimeEnabled) {
        _runtimeSyncPending = false;
        unawaited(_syncRuntime());
      } else {
        _runtimeSyncPending = false;
      }
    }
  }

  Future<void> stopRuntime({bool immediate = false}) async {
    _runtimeGeneration++;
    _runtimeSyncPending = false;
    final subscription = _runtimePositionSubscription;
    _runtimePositionSubscription = null;
    _observedRuntimeSession = null;
    _observedRuntimeSubtitles?.removeListener(_updateRuntime);
    _observedRuntimeSubtitles = null;
    _runtimeSessionId = null;
    _runtimeTrackPath = null;
    _lastRuntimeText = null;
    await subscription?.cancel();
    if (!_runtimeRunning && !immediate) return;
    _runtimeRunning = false;
    await updateSubtitle('');
    await stopOverlay(immediate: immediate);
  }

  Future<void> _applyRuntimeStyle() {
    final style = _runtimeStyle!();
    return updateStyle(
      fontSize: style.fontSize,
      backgroundColor: style.backgroundColor,
      textColor: style.textColor,
      backgroundOpacity: style.backgroundOpacity,
      fontFamily: style.fontFamily,
      borderDepth: style.borderDepth,
    );
  }

  void _bindRuntimeSession(PlaybackSession session) {
    if (!identical(_observedRuntimeSession, session)) {
      unawaited(_runtimePositionSubscription?.cancel());
      _observedRuntimeSession = session;
      _runtimePositionSubscription = session.positionStream.listen((position) {
        if (_runtimeEnabled &&
            _runtimeRunning &&
            identical(_observedRuntimeSession, session) &&
            identical(_runtimeSession?.call(), session)) {
          _updateRuntimeSession(session, position: position);
        }
      });
    }
    final subtitles = _runtimeSubtitles!();
    if (!identical(_observedRuntimeSubtitles, subtitles)) {
      _observedRuntimeSubtitles?.removeListener(_updateRuntime);
      _observedRuntimeSubtitles = subtitles;
      subtitles.addListener(_updateRuntime);
    }
  }

  void _updateRuntime() {
    if (!_runtimeEnabled) {
      unawaited(stopRuntime(immediate: true));
      return;
    }
    final session = _runtimeSession?.call();
    if (session == null) {
      unawaited(stopRuntime(immediate: true));
      return;
    }
    if (!identical(_observedRuntimeSession, session) ||
        _runtimeTrackPath != session.currentTrackPath) {
      requestRuntimeSync();
      return;
    }
    _updateRuntimeSession(session, loadIfMissing: false);
  }

  void _updateRuntimeSession(
    PlaybackSession session, {
    Duration? position,
    bool loadIfMissing = true,
  }) {
    final subtitles = _runtimeSubtitles!();
    if (_runtimeSessionId != session.id) {
      _runtimeSessionId = session.id;
      _lastRuntimeText = null;
    }
    final trackChanged = _runtimeTrackPath != session.currentTrackPath;
    if (trackChanged) {
      final trackPath = session.currentTrackPath;
      _runtimeTrackPath = trackPath;
      _lastRuntimeText = null;
    }
    final trackPath = session.currentTrackPath;
    final subtitleTrack = subtitles.trackSync(trackPath);
    if (loadIfMissing &&
        (trackChanged ||
            subtitleTrack == null &&
                !subtitles.isLoading(trackPath) &&
                !subtitles.hasResult(trackPath))) {
      unawaited(() async {
        try {
          await subtitles.load(trackPath);
          if (_runtimeEnabled &&
              _runtimeRunning &&
              identical(_observedRuntimeSession, session) &&
              identical(_runtimeSession?.call(), session) &&
              _runtimeTrackPath == trackPath) {
            _updateRuntimeSession(session, loadIfMissing: false);
          }
        } catch (error, stackTrace) {
          AppLogService.warning(
            'global_subtitle_load_failed',
            error: error,
            stackTrace: stackTrace,
          );
        }
      }());
    }

    final text =
        subtitles.textAt(
          session.currentTrackPath,
          position ?? session.position,
          subtitleTrack: subtitleTrack,
        ) ??
        '';
    if (_lastRuntimeText != text) {
      _lastRuntimeText = text;
      unawaited(updateSubtitle(text));
    }
  }

  Future<bool> canDrawOverlays() => _platform.canDrawOverlays();

  Future<bool> openOverlaySettings() => _platform.openOverlaySettings();

  Future<bool> startOverlay() async {
    if (_disposed) return false;
    final generation = ++_commandGeneration;
    _stopTimer?.cancel();
    _stopTimer = null;
    await _platform.startOverlay();
    if (_disposed || generation != _commandGeneration) {
      await _platform.stopOverlay();
      return false;
    }
    return true;
  }

  Future<void> stopOverlay({bool immediate = false}) async {
    final generation = ++_commandGeneration;
    _stopTimer?.cancel();
    _stopTimer = null;
    if (immediate) {
      await _doStop();
    } else {
      if (_disposed) return;
      _stopTimer = _stopTimerFactory(const Duration(milliseconds: 300), () {
        if (!_disposed && generation == _commandGeneration) {
          unawaited(_doStop());
        }
      });
    }
  }

  Future<void> _doStop() async {
    _stopTimer?.cancel();
    _stopTimer = null;
    await _platform.stopOverlay();
  }

  Future<void> updateSubtitle(String text) => _platform.updateSubtitle(text);

  Future<void> updateStyle({
    double? fontSize,
    String? backgroundColor,
    String? textColor,
    double? backgroundOpacity,
    String? fontFamily,
    double? borderDepth,
  }) async {
    final args = <String, Object?>{
      'fontSize': fontSize,
      'backgroundColor': backgroundColor,
      'textColor': textColor,
      'backgroundOpacity': backgroundOpacity,
      'fontFamily': fontFamily,
      'borderDepth': borderDepth,
    }..removeWhere((_, value) => value == null);
    await _platform.updateStyle(args);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _runtimeGeneration++;
    final subscription = _runtimePositionSubscription;
    _runtimePositionSubscription = null;
    _observedRuntimeSession = null;
    _observedRuntimeSubtitles?.removeListener(_updateRuntime);
    _observedRuntimeSubtitles = null;
    _isRuntimeEnabled = null;
    _runtimeSession = null;
    _runtimeSubtitles = null;
    _runtimeStyle = null;
    _disposed = true;
    _commandGeneration++;
    _stopTimer?.cancel();
    _stopTimer = null;
    await subscription?.cancel();
    await _platform.stopOverlay();
  }
}
