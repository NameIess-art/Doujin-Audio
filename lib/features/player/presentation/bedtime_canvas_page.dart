import 'playback_providers.dart';
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/presentation/app_orientation_controller.dart';
import '../../../app/state/app_runtime_providers.dart';
import '../../../core/media/time_text_formatters.dart';
import '../../../core/platform/power_platform_gateway.dart';
import '../../../core/platform/video_display_platform_gateway.dart';
import '../../../core/widgets/app_feedback.dart';
import '../../../core/widgets/app_transitions.dart';
import '../../../core/widgets/target_countdown_builder.dart';
import '../application/playback_session.dart';
import '../domain/playback_mode.dart';

/// Low-blue-light warm amber foreground designed for dark bedroom viewing.
const Color _bedtimeWarmForeground = Color(0xFFFFE6C4);

class BedtimeCanvasPage extends ConsumerStatefulWidget {
  const BedtimeCanvasPage({super.key});

  static bool isCanvasActive = false;
  static Duration idleDimDelay = const Duration(seconds: 15);

  static Route<void> route(BuildContext context) {
    return buildBedtimeCanvasRoute(
      context: context,
      child: const BedtimeCanvasPage(),
    );
  }

  @override
  ConsumerState<BedtimeCanvasPage> createState() => _BedtimeCanvasPageState();
}

class _BedtimeCanvasPageState extends ConsumerState<BedtimeCanvasPage>
    with TickerProviderStateMixin {
  late final PowerPlatformGateway _powerGateway;
  late final VideoDisplayPlatformGateway _displayGateway;
  late final AppOrientationController _orientationController;
  late final AnimationController _breathingController;
  late final Animation<double> _breathingAnimation;
  late final AnimationController _holdExitController;

  static const double _moveCancelThreshold = 24.0;
  static const double _holdVisibleThreshold = 0.12;

  Timer? _clockTimer;
  Timer? _idleDimTimer;
  Timer? _feedbackTimer;
  Timer? _backHintTimer;
  IconData? _feedbackIcon;
  bool _isIdleDimmed = false;
  bool _showBackBlockedHint = false;
  int? _activePointerId;
  Offset? _touchPosition;
  Offset? _touchStartPosition;
  final Set<String> _targetSessionIds = <String>{};
  String? _brightnessToken;
  bool _disposed = false;
  bool? _disableAnimations;

  @override
  void initState() {
    super.initState();
    BedtimeCanvasPage.isCanvasActive = true;
    _powerGateway = ref.read(powerPlatformGatewayProvider);
    _displayGateway = ref.read(videoDisplayPlatformGatewayProvider);
    _orientationController = ref.read(appOrientationControllerProvider);
    unawaited(_powerGateway.setKeepScreenOn(true));
    unawaited(_initBrightness());
    unawaited(_orientationController.setBedtimeCanvasVisible(true));

    final playback = ref.read(playbackFacadeProvider);
    final playing = playback.sessions.values
        .where((s) => s.effectivePlaying)
        .map((s) => s.id)
        .toSet();
    if (playing.isNotEmpty) {
      _targetSessionIds.addAll(playing);
    } else {
      final withLastPlayed =
          playback.sessions.values.where((s) => s.lastPlayedAt != null).toList()
            ..sort((a, b) => b.lastPlayedAt!.compareTo(a.lastPlayedAt!));
      if (withLastPlayed.isNotEmpty) {
        _targetSessionIds.add(withLastPlayed.first.id);
      } else if (playback.aggregateState.focusedSessionId != null &&
          playback.sessions.containsKey(
            playback.aggregateState.focusedSessionId,
          )) {
        _targetSessionIds.add(playback.aggregateState.focusedSessionId!);
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

    _holdExitController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
      // This duration measures a deliberate hold, rather than decorative motion.
      animationBehavior: AnimationBehavior.preserve,
    );

    _holdExitController.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        unawaited(
          AppInteractionFeedback.trigger(
            AppInteractionFeedbackType.confirmation,
          ),
        );
        if (mounted) {
          Navigator.of(context).pop();
        }
      }
    });

    _scheduleNextMinuteClock();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    if (_disableAnimations == disableAnimations) return;
    final firstAppearance = _disableAnimations == null;
    _disableAnimations = disableAnimations;
    if (disableAnimations) {
      _breathingController.value = 0;
    } else if (firstAppearance || _idleDimTimer?.isActive == true) {
      _breathingController.repeat(reverse: true);
    }
    if (firstAppearance) _resetIdleDimTimer();
  }

  @override
  void dispose() {
    _disposed = true;
    BedtimeCanvasPage.isCanvasActive = false;
    _clockTimer?.cancel();
    _idleDimTimer?.cancel();
    _feedbackTimer?.cancel();
    _backHintTimer?.cancel();
    _breathingController.dispose();
    _holdExitController.dispose();
    if (_brightnessToken != null) {
      final token = _brightnessToken!;
      _brightnessToken = null;
      unawaited(_displayGateway.endBrightnessControl(token));
    }
    unawaited(_powerGateway.setKeepScreenOn(false));
    unawaited(_orientationController.setBedtimeCanvasVisible(false));
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

  void _onUserInteraction() {
    if (_isIdleDimmed && mounted) {
      setState(() => _isIdleDimmed = false);
    } else {
      _isIdleDimmed = false;
    }
    if (_disableAnimations == true) {
      _breathingController.value = 0;
    } else if (_idleDimTimer?.isActive != true) {
      _breathingController.repeat(reverse: true);
    }
    _resetIdleDimTimer();
  }

  void _resetIdleDimTimer() {
    _idleDimTimer?.cancel();
    _idleDimTimer = Timer(BedtimeCanvasPage.idleDimDelay, () {
      if (mounted && !_disposed) {
        if (!_isIdleDimmed) {
          setState(() => _isIdleDimmed = true);
        }
        if (_disableAnimations == true) {
          _breathingController.value = 0;
        } else {
          _breathingController.animateTo(
            0.0,
            duration: const Duration(milliseconds: 1200),
            curve: Curves.easeOut,
          );
        }
      }
    });
  }

  void _handleBlockedBack() {
    _onUserInteraction();
    _backHintTimer?.cancel();
    if (mounted) {
      setState(() => _showBackBlockedHint = true);
    }
    _backHintTimer = Timer(const Duration(milliseconds: 2400), () {
      if (mounted && !_disposed) {
        setState(() => _showBackBlockedHint = false);
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

  void _showFeedback({required IconData icon}) {
    if (!mounted) return;
    _feedbackTimer?.cancel();
    setState(() {
      _feedbackIcon = icon;
    });
    _feedbackTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) {
        setState(() {
          _feedbackIcon = null;
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

    final withLastPlayed =
        playback.sessions.values.where((s) => s.lastPlayedAt != null).toList()
          ..sort((a, b) => b.lastPlayedAt!.compareTo(a.lastPlayedAt!));
    if (withLastPlayed.isNotEmpty) {
      final mostRecent = withLastPlayed.first;
      _targetSessionIds.add(mostRecent.id);
      return [mostRecent];
    }

    final focused = playback.aggregateState.focusedSessionId;
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

    if (anyPlaying) {
      unawaited(AppInteractionFeedback.trigger(AppInteractionFeedbackType.tap));
      final playing = sessions.where((s) => s.effectivePlaying).toList();
      _targetSessionIds
        ..clear()
        ..addAll(playing.map((s) => s.id));
      await playback.pauseAllSessions();
      _showFeedback(icon: Icons.pause_rounded);
    } else {
      final targets = _resolveTargetSessions();
      if (targets.isNotEmpty) {
        unawaited(
          AppInteractionFeedback.trigger(AppInteractionFeedbackType.tap),
        );
        for (final session in targets) {
          if (!session.effectivePlaying) {
            await playback.toggleSessionPlayPause(session.id);
          }
        }
        _showFeedback(icon: Icons.play_arrow_rounded);
      }
    }
  }

  void _onPointerDown(PointerDownEvent event) {
    _onUserInteraction();
    if (_activePointerId != null) return;
    _activePointerId = event.pointer;
    _touchStartPosition = event.position;
    _touchPosition = event.position;
    _holdExitController.forward(from: 0.0);
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (_activePointerId != event.pointer || _touchStartPosition == null) {
      return;
    }
    final distance = (event.position - _touchStartPosition!).distance;
    if (distance > _moveCancelThreshold) {
      _holdExitController.reset();
      _touchStartPosition = null;
      _touchPosition = null;
    } else {
      _touchPosition = _touchStartPosition;
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    if (_activePointerId != event.pointer) return;
    _activePointerId = null;
    _holdExitController.reset();
    _touchStartPosition = null;
    _touchPosition = null;
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (_activePointerId != event.pointer) return;
    _activePointerId = null;
    _holdExitController.reset();
    _touchStartPosition = null;
    _touchPosition = null;
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final now = DateTime.now();
    final timeStr =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    return PopScope<void>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBlockedBack();
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: const SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          systemNavigationBarColor: Colors.transparent,
          systemNavigationBarDividerColor: Colors.transparent,
          statusBarIconBrightness: Brightness.light,
          statusBarBrightness: Brightness.dark,
          systemNavigationBarIconBrightness: Brightness.light,
          systemStatusBarContrastEnforced: false,
          systemNavigationBarContrastEnforced: false,
        ),
        child: Scaffold(
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
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // Main content with gentle breathing animation
                  FadeTransition(
                    opacity: _breathingAnimation,
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Clock time display
                          Text(
                            timeStr,
                            style: const TextStyle(
                              color: _bedtimeWarmForeground,
                              fontSize: 68,
                              fontWeight: FontWeight.w200,
                              letterSpacing: 2,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                          const SizedBox(height: 12),
                          // Sleep timer / status subtitle
                          const _BedtimeTimerStatus(),
                        ],
                      ),
                    ),
                  ),

                  // Bottom subtle hint (dims along with idle timer)
                  Positioned(
                    bottom: 32,
                    left: 20,
                    right: 20,
                    child: AnimatedOpacity(
                      key: const ValueKey<String>('bedtime_bottom_hint_fade'),
                      opacity: _showBackBlockedHint
                          ? 1.0
                          : (_isIdleDimmed ? 0.25 : 1.0),
                      duration: _disableAnimations == true
                          ? Duration.zero
                          : const Duration(milliseconds: 900),
                      curve: Curves.easeOut,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_showBackBlockedHint) ...[
                            Text(
                              i18n.tr('bedtime_back_blocked_hint'),
                              key: const ValueKey<String>(
                                'bedtime_back_blocked_hint',
                              ),
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: _bedtimeWarmForeground.withValues(
                                  alpha: 0.36,
                                ),
                                fontSize: 12,
                                letterSpacing: 0.4,
                              ),
                            ),
                            const SizedBox(height: 6),
                          ],
                          Text(
                            i18n.tr('bedtime_controls_hint'),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: _bedtimeWarmForeground.withValues(
                                alpha: 0.18,
                              ),
                              fontSize: 12,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ],
                      ),
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
                        color: _bedtimeWarmForeground.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _feedbackIcon,
                            color: _bedtimeWarmForeground.withValues(
                              alpha: 0.35,
                            ),
                            size: 26,
                          ),
                        ],
                      ),
                    ),
                  ),

                // Long-press hold indicator
                AnimatedBuilder(
                  animation: _holdExitController,
                  builder: (context, _) {
                    final rawProgress = _holdExitController.value;
                    if (rawProgress <= _holdVisibleThreshold) {
                      return const SizedBox.shrink();
                    }
                    final progress =
                        ((rawProgress - _holdVisibleThreshold) /
                                (1.0 - _holdVisibleThreshold))
                            .clamp(0.0, 1.0);
                    final fadeOpacity = (progress / 0.18).clamp(0.0, 1.0);

                    final pos =
                        _touchPosition ??
                        _touchStartPosition ??
                        Offset(
                          MediaQuery.sizeOf(context).width / 2,
                          MediaQuery.sizeOf(context).height / 2,
                        );

                    return Positioned(
                      left: pos.dx - 40,
                      top: pos.dy - 40,
                      child: IgnorePointer(
                        child: Opacity(
                          opacity: fadeOpacity,
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
                                    _bedtimeWarmForeground.withValues(
                                      alpha: 0.4,
                                    ),
                                  ),
                                  backgroundColor: _bedtimeWarmForeground
                                      .withValues(alpha: 0.1),
                                ),
                                Icon(
                                  Icons.lock_open_rounded,
                                  size: 20,
                                  color: _bedtimeWarmForeground.withValues(
                                    alpha: math.min(
                                      0.4,
                                      0.15 + progress * 0.25,
                                    ),
                                  ),
                                ),
                              ],
                            ),
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
      ),
    ),
    );
  }
}

class _BedtimeTimerStatus extends ConsumerWidget {
  const _BedtimeTimerStatus();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final timerState =
        ref.watch(timerStateProvider).value ??
        ref.read(timerFacadeProvider).state;
    final waitingForTrackEnd =
        timerState.stopAfterCurrentTrack &&
        timerState.remaining == Duration.zero;
    final activeCountdown =
        timerState.active &&
        timerState.remaining != null &&
        timerState.remaining! > Duration.zero;
    final waitingForAutoResume =
        !waitingForTrackEnd &&
        !activeCountdown &&
        timerState.autoResumeAt != null;
    final waitingForTrigger =
        !waitingForTrackEnd &&
        !activeCountdown &&
        !waitingForAutoResume &&
        timerState.mode == TimerMode.trigger &&
        timerState.duration != null &&
        timerState.duration! > Duration.zero;

    Widget buildRow(IconData icon, String timerText) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 14,
            color: _bedtimeWarmForeground.withValues(alpha: 0.85),
          ),
          const SizedBox(width: 6),
          Text(
            timerText,
            style: TextStyle(
              color: _bedtimeWarmForeground.withValues(alpha: 0.85),
              fontSize: 13,
              fontWeight: FontWeight.w400,
              letterSpacing: 0.5,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      );
    }

    if (waitingForTrackEnd) {
      return buildRow(
        Icons.music_note_rounded,
        i18n.tr('waiting_for_track_end'),
      );
    }
    if (waitingForAutoResume) {
      return TargetCountdownBuilder(
        target: timerState.autoResumeAt,
        builder: (context, remaining) => buildRow(
          Icons.restore_rounded,
          '${i18n.tr('waiting_for_auto_resume')}  '
          '${formatDurationCompact(remaining)}',
        ),
      );
    }
    if (activeCountdown) {
      return buildRow(
        Icons.timer_outlined,
        '${i18n.tr('sleep_countdown')}  '
        '${formatDurationCompact(timerState.remaining!)}',
      );
    }
    if (waitingForTrigger) {
      return buildRow(
        Icons.schedule_rounded,
        i18n.tr('waiting_to_start_countdown'),
      );
    }
    return buildRow(Icons.nights_stay_outlined, i18n.tr('no_timer_set'));
  }
}
