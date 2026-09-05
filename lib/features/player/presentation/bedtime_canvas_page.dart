import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/state/app_runtime_providers.dart';
import '../../../core/media/time_text_formatters.dart';
import '../../../core/platform/power_platform_gateway.dart';
import '../../../core/platform/video_display_platform_gateway.dart';
import '../application/playback_session.dart';

class BedtimeCanvasPage extends ConsumerStatefulWidget {
  const BedtimeCanvasPage({super.key});

  static bool isCanvasActive = false;
  static Duration idleDimDelay = const Duration(seconds: 15);
  static Duration screenTimeoutDelay = const Duration(minutes: 2);

  static Route<void> route() {
    return PageRouteBuilder<void>(
      pageBuilder: (context, animation, secondaryAnimation) => FadeTransition(
        opacity: animation,
        child: const BedtimeCanvasPage(),
      ),
      transitionDuration: const Duration(milliseconds: 350),
    );
  }

  @override
  ConsumerState<BedtimeCanvasPage> createState() => _BedtimeCanvasPageState();
}

class _BedtimeCanvasPageState extends ConsumerState<BedtimeCanvasPage>
    with TickerProviderStateMixin {
  late final PowerPlatformGateway _powerGateway;
  late final VideoDisplayPlatformGateway _displayGateway;
  late final AnimationController _breathingController;
  late final Animation<double> _breathingAnimation;
  late final AnimationController _holdExitController;

  Timer? _clockTimer;
  Timer? _idleDimTimer;
  Timer? _screenTimeoutTimer;
  Timer? _feedbackTimer;
  IconData? _feedbackIcon;
  String? _feedbackText;
  Offset? _touchPosition;
  Offset? _touchStartPosition;
  final Set<String> _targetSessionIds = <String>{};
  String? _brightnessToken;
  bool _isKeepScreenOn = true;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    BedtimeCanvasPage.isCanvasActive = true;
    _powerGateway = ref.read(powerPlatformGatewayProvider);
    _displayGateway = ref.read(videoDisplayPlatformGatewayProvider);
    _isKeepScreenOn = true;
    unawaited(_powerGateway.setKeepScreenOn(true));
    unawaited(_initBrightness());
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    final playback = ref.read(playbackFacadeProvider);
    final playing = playback.sessions.values
        .where((s) => s.effectivePlaying)
        .map((s) => s.id)
        .toSet();
    if (playing.isNotEmpty) {
      _targetSessionIds.addAll(playing);
    } else {
      final withLastPlayed = playback.sessions.values
          .where((s) => s.lastPlayedAt != null)
          .toList()
        ..sort((a, b) => b.lastPlayedAt!.compareTo(a.lastPlayedAt!));
      if (withLastPlayed.isNotEmpty) {
        _targetSessionIds.add(withLastPlayed.first.id);
      } else if (playback.state.focusedSessionId != null &&
          playback.sessions.containsKey(playback.state.focusedSessionId)) {
        _targetSessionIds.add(playback.state.focusedSessionId!);
      } else if (playback.activeSessions.isNotEmpty) {
        _targetSessionIds.add(playback.activeSessions.first.id);
      }
    }

    _breathingController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 4500),
    );

    _breathingAnimation = Tween<double>(begin: 0.16, end: 0.42).animate(
      CurvedAnimation(
        parent: _breathingController,
        curve: Curves.easeInOutSine,
      ),
    );
    _wakeBreathingAnimation();

    _holdExitController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    );

    _holdExitController.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        HapticFeedback.heavyImpact();
        if (mounted) {
          Navigator.of(context).pop();
        }
      }
    });

    _scheduleNextMinuteClock();

    final timer = ref.read(timerFacadeProvider);
    final isInitialActive = playback.state.playingSessionCount > 0 ||
        timer.state.active ||
        timer.state.stopAfterCurrentTrack;
    _updateKeepScreenOnState(isInitialActive);
  }

  @override
  void dispose() {
    _disposed = true;
    BedtimeCanvasPage.isCanvasActive = false;
    _clockTimer?.cancel();
    _idleDimTimer?.cancel();
    _screenTimeoutTimer?.cancel();
    _feedbackTimer?.cancel();
    _breathingController.dispose();
    _holdExitController.dispose();
    if (_brightnessToken != null) {
      final token = _brightnessToken!;
      _brightnessToken = null;
      unawaited(_displayGateway.endBrightnessControl(token));
    }
    unawaited(_powerGateway.setKeepScreenOn(false));
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  Future<void> _initBrightness() async {
    try {
      final result = await _displayGateway.beginBrightnessControl();
      final lease = result.valueOrNull;
      if (lease != null) {
        if (_disposed) {
          unawaited(_displayGateway.endBrightnessControl(lease.token));
        } else {
          _brightnessToken = lease.token;
          await _displayGateway.setBrightness(lease.token, 0.01);
        }
      }
    } catch (_) {
      // Gracefully handle platform channel errors/unsupported platforms
    }
  }

  void _wakeBreathingAnimation() {
    if (_idleDimTimer?.isActive != true) {
      _breathingController.repeat(reverse: true);
    }
    _resetIdleDimTimer();
  }

  void _resetIdleDimTimer() {
    _idleDimTimer?.cancel();
    _idleDimTimer = Timer(BedtimeCanvasPage.idleDimDelay, () {
      if (mounted && !_disposed) {
        _breathingController.animateTo(
          0.0,
          duration: const Duration(milliseconds: 1200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _scheduleNextMinuteClock() {
    _clockTimer?.cancel();
    if (_disposed) return;
    final now = DateTime.now();
    final msUntilNextMinute = (60 - now.second) * 1000 - now.millisecond + 50;
    _clockTimer = Timer(
      Duration(milliseconds: math.max(100, msUntilNextMinute)),
      () {
        if (mounted && !_disposed) {
          setState(() {});
          _scheduleNextMinuteClock();
        }
      },
    );
  }

  void _updateKeepScreenOnState(bool isAudioOrTimerActive) {
    if (isAudioOrTimerActive) {
      _screenTimeoutTimer?.cancel();
      _screenTimeoutTimer = null;
      if (!_isKeepScreenOn) {
        _isKeepScreenOn = true;
        unawaited(_powerGateway.setKeepScreenOn(true));
      }
    } else {
      if (_isKeepScreenOn && _screenTimeoutTimer == null) {
        _screenTimeoutTimer = Timer(BedtimeCanvasPage.screenTimeoutDelay, () {
          if (mounted && !_disposed) {
            _isKeepScreenOn = false;
            unawaited(_powerGateway.setKeepScreenOn(false));
          }
        });
      }
    }
  }

  void _checkAudioOrTimerState({
    int? playingCount,
    bool? timerActive,
    bool? stopAfterTrack,
  }) {
    final count = playingCount ??
        ref.read(playbackFacadeProvider).state.playingSessionCount;
    final active = timerActive ??
        ref.read(timerFacadeProvider).state.active;
    final stop = stopAfterTrack ??
        ref.read(timerFacadeProvider).state.stopAfterCurrentTrack;
    _updateKeepScreenOnState(count > 0 || active || stop);
  }

  void _onUserInteraction() {
    _wakeBreathingAnimation();
    _screenTimeoutTimer?.cancel();
    _screenTimeoutTimer = null;
    if (!_isKeepScreenOn) {
      _isKeepScreenOn = true;
      unawaited(_powerGateway.setKeepScreenOn(true));
    }
    final playback = ref.read(playbackFacadeProvider);
    final timer = ref.read(timerFacadeProvider);
    final isAudioOrTimerActive = playback.state.playingSessionCount > 0 ||
        timer.state.active ||
        timer.state.stopAfterCurrentTrack;
    if (!isAudioOrTimerActive) {
      _screenTimeoutTimer = Timer(BedtimeCanvasPage.screenTimeoutDelay, () {
        if (mounted && !_disposed) {
          _isKeepScreenOn = false;
          unawaited(_powerGateway.setKeepScreenOn(false));
        }
      });
    }
  }

  void _showFeedback({required IconData icon, String? text}) {
    _feedbackTimer?.cancel();
    setState(() {
      _feedbackIcon = icon;
      _feedbackText = text;
    });
    _feedbackTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) {
        setState(() {
          _feedbackIcon = null;
          _feedbackText = null;
        });
      }
    });
  }

  List<PlaybackSession> _resolveTargetSessions() {
    final playback = ref.read(playbackFacadeProvider);
    final playing = playback.sessions.values
        .where((s) => s.effectivePlaying)
        .toList();
    if (playing.isNotEmpty) {
      _targetSessionIds
        ..clear()
        ..addAll(playing.map((s) => s.id));
      return playing;
    }

    final cached = _targetSessionIds
        .map((id) => playback.sessions[id])
        .whereType<PlaybackSession>()
        .toList();
    if (cached.isNotEmpty) {
      return cached;
    }

    final withLastPlayed = playback.sessions.values
        .where((s) => s.lastPlayedAt != null)
        .toList()
      ..sort((a, b) => b.lastPlayedAt!.compareTo(a.lastPlayedAt!));
    if (withLastPlayed.isNotEmpty) {
      final mostRecent = withLastPlayed.first;
      _targetSessionIds.add(mostRecent.id);
      return [mostRecent];
    }

    final focused = playback.state.focusedSessionId;
    if (focused != null && playback.sessions.containsKey(focused)) {
      final session = playback.sessions[focused]!;
      _targetSessionIds.add(session.id);
      return [session];
    }

    if (playback.activeSessions.isNotEmpty) {
      final first = playback.activeSessions.first;
      _targetSessionIds.add(first.id);
      return [first];
    }

    return const <PlaybackSession>[];
  }

  Future<void> _handleDoubleTap() async {
    _onUserInteraction();
    final playback = ref.read(playbackFacadeProvider);
    final sessions = playback.sessions.values;
    final anyPlaying = sessions.any((s) => s.effectivePlaying);

    unawaited(HapticFeedback.lightImpact());
    if (anyPlaying) {
      final playing = sessions.where((s) => s.effectivePlaying).toList();
      _targetSessionIds
        ..clear()
        ..addAll(playing.map((s) => s.id));
      await playback.pauseAllSessions();
      _showFeedback(icon: Icons.pause_rounded);
    } else {
      final targets = _resolveTargetSessions();
      if (targets.isNotEmpty) {
        for (final session in targets) {
          if (!session.effectivePlaying) {
            await playback.toggleSessionPlayPause(session.id);
          }
        }
        _showFeedback(icon: Icons.play_arrow_rounded);
      }
    }
  }

  void _handleVerticalDrag(DragUpdateDetails details) {
    _onUserInteraction();
    final delta = details.primaryDelta ?? 0.0;
    if (delta.abs() < 0.5) return;

    final targets = _resolveTargetSessions();
    if (targets.isEmpty) return;
    final playback = ref.read(playbackFacadeProvider);

    // Drag up decreases screen Y (negative delta), so delta > 0 is volume down, delta < 0 is volume up
    final volumeChange = -delta / 320.0;
    var anyChanged = false;
    double? feedbackVolume;

    for (final session in targets) {
      final newVolume = (session.volume + volumeChange).clamp(0.0, 1.0);
      feedbackVolume ??= newVolume;
      if ((newVolume - session.volume).abs() >= 0.005) {
        unawaited(playback.setSessionVolume(session.id, newVolume));
        anyChanged = true;
      }
    }

    if (anyChanged && feedbackVolume != null) {
      final percent = (feedbackVolume * 100).round();
      final icon = feedbackVolume == 0
          ? Icons.volume_off_rounded
          : feedbackVolume < 0.5
              ? Icons.volume_down_rounded
              : Icons.volume_up_rounded;
      _showFeedback(icon: icon, text: '$percent%');
    }
  }

  void _onPointerDown(PointerDownEvent event) {
    _onUserInteraction();
    _touchStartPosition = event.position;
    _touchPosition = event.position;
    _holdExitController.forward(from: 0.0);
  }

  void _onPointerMove(PointerMoveEvent event) {
    _touchPosition = event.position;
    if (_touchStartPosition != null) {
      final distance = (event.position - _touchStartPosition!).distance;
      if (distance > 24) {
        _holdExitController.reset();
        _touchStartPosition = null;
      }
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    _holdExitController.reset();
    _touchStartPosition = null;
    _touchPosition = null;
  }

  void _onPointerCancel(PointerCancelEvent event) {
    _holdExitController.reset();
    _touchStartPosition = null;
    _touchPosition = null;
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final timerState = ref.watch(timerStateProvider).value ??
        ref.read(timerFacadeProvider).state;

    ref.listen(playbackStateProvider, (_, next) {
      final slice = next.value;
      if (slice != null) {
        _checkAudioOrTimerState(playingCount: slice.playingSessionCount);
      }
    });
    ref.listen(timerStateProvider, (_, next) {
      final slice = next.value;
      if (slice != null) {
        _checkAudioOrTimerState(
          timerActive: slice.active,
          stopAfterTrack: slice.stopAfterCurrentTrack,
        );
      }
    });

    final now = DateTime.now();
    final timeStr =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    final String timerText;
    if (timerState.stopAfterCurrentTrack) {
      timerText = i18n.tr('stop_after_current_track');
    } else if (timerState.active &&
        timerState.remaining != null &&
        timerState.remaining! > Duration.zero) {
      timerText =
          '${i18n.tr('sleep_countdown')}  ${formatDurationCompact(timerState.remaining!)}';
    } else {
      timerText = i18n.tr('no_timer_set');
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: _onPointerDown,
        onPointerMove: _onPointerMove,
        onPointerUp: _onPointerUp,
        onPointerCancel: _onPointerCancel,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onDoubleTap: _handleDoubleTap,
          onVerticalDragUpdate: _handleVerticalDrag,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Main content with gentle breathing animation
              AnimatedBuilder(
                animation: _breathingAnimation,
                builder: (context, _) {
                  final opacity = _breathingAnimation.value;
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Clock time display
                        Text(
                          timeStr,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: opacity),
                            fontSize: 68,
                            fontWeight: FontWeight.w200,
                            letterSpacing: 2,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                        const SizedBox(height: 12),
                        // Sleep timer / status subtitle
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              timerState.stopAfterCurrentTrack
                                  ? Icons.music_note_rounded
                                  : timerState.active
                                      ? Icons.timer_outlined
                                      : Icons.nights_stay_outlined,
                              size: 14,
                              color: Colors.white
                                  .withValues(alpha: opacity * 0.85),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              timerText,
                              style: TextStyle(
                                color: Colors.white
                                    .withValues(alpha: opacity * 0.85),
                                fontSize: 13,
                                fontWeight: FontWeight.w400,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  );
                },
              ),

              // Bottom subtle hint
              Positioned(
                bottom: 32,
                left: 20,
                right: 20,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      i18n.tr('swipe_to_adjust_track_volume'),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.12),
                        fontSize: 11,
                        letterSpacing: 0.4,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      i18n.tr('hold_to_exit_sleep_mode'),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.16),
                        fontSize: 12,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
              ),

              // Faint gesture feedback badge
              if (_feedbackIcon != null)
                Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 14,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _feedbackIcon,
                          color: Colors.white.withValues(alpha: 0.35),
                          size: 26,
                        ),
                        if (_feedbackText != null) ...[
                          const SizedBox(width: 8),
                          Text(
                            _feedbackText!,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.35),
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),

              // Long-press hold indicator
              AnimatedBuilder(
                animation: _holdExitController,
                builder: (context, _) {
                  final progress = _holdExitController.value;
                  if (progress <= 0.0) return const SizedBox.shrink();

                  final pos = _touchPosition ??
                      Offset(
                        MediaQuery.sizeOf(context).width / 2,
                        MediaQuery.sizeOf(context).height / 2,
                      );

                  return Positioned(
                    left: pos.dx - 40,
                    top: pos.dy - 40,
                    child: IgnorePointer(
                      child: SizedBox(
                        width: 80,
                        height: 80,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            CircularProgressIndicator(
                              value: progress,
                              strokeWidth: 3,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                Colors.white.withValues(alpha: 0.4),
                              ),
                              backgroundColor:
                                  Colors.white.withValues(alpha: 0.1),
                            ),
                            Icon(
                              Icons.lock_open_rounded,
                              size: 20,
                              color: Colors.white.withValues(
                                alpha: math.min(0.4, 0.15 + progress * 0.25),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
