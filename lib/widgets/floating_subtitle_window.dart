import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/audio_provider.dart';
import '../providers/audio_provider_riverpod.dart';
import '../providers/subtitle_settings_provider.dart';
import '../services/audio_state_services.dart';
import '../services/subtitle_parser.dart';
import '../services/subtitle_overlay_controller.dart';
import 'subtitle_window_visual.dart';

class FloatingSubtitleWindow extends ConsumerStatefulWidget {
  final bool isCrossPage;
  final String? sessionId;
  final double? defaultTop;
  final double? overrideTop;

  const FloatingSubtitleWindow({
    super.key,
    this.isCrossPage = false,
    this.sessionId,
    this.defaultTop,
    this.overrideTop,
  });

  @override
  ConsumerState<FloatingSubtitleWindow> createState() =>
      _FloatingSubtitleWindowState();
}

class _FloatingSubtitleWindowState extends ConsumerState<FloatingSubtitleWindow>
    with WidgetsBindingObserver {
  ProviderSubscription<AsyncValue<PlaybackStateSliceData>>? _playbackStateSub;
  StreamSubscription<Duration>? _positionSub;
  SubtitleTrack? _subtitleTrack;
  String? _subtitleText;
  String? _loadedPath;
  PlaybackSession? _currentSession;
  double? _dragY;
  bool _snapHapticFired = false;
  bool _isAppInBackground = false;
  bool _isOverlayActive = false;
  bool _isSyncing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _isAppInBackground =
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed &&
        WidgetsBinding.instance.lifecycleState != null;

    _playbackStateSub = ref.listenManual<AsyncValue<PlaybackStateSliceData>>(
      playbackStateProvider,
      (previous, next) {
        _syncSession(next.valueOrNull);
      },
      fireImmediately: true,
    );

    // Also listen to settings changes to sync overlay state if toggled in background
    ref.listenManual(subtitleSettingsProvider, (prev, next) {
      if (_isAppInBackground) {
        _syncOverlayState();
      }
    });

    if (_isAppInBackground) {
      _syncOverlayState();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (widget.isCrossPage && _isOverlayActive) {
      _stopOverlay();
    }
    _playbackStateSub?.close();
    _positionSub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // On Android, inactive can be triggered by notifications or dialogs.
    // We only want the system overlay when the app is actually in background (paused).
    final isBg =
        (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached);

    if (isBg != _isAppInBackground) {
      _isAppInBackground = isBg;
      _syncOverlayState();
    }
  }

  Future<void> _syncOverlayState() async {
    if (_isSyncing) return;
    _isSyncing = true;
    try {
      if (_isAppInBackground) {
        await _tryStartOverlay();
      } else {
        await _stopOverlay(immediate: true);
      }
    } finally {
      _isSyncing = false;
    }
  }

  Future<void> _tryStartOverlay() async {
    if (!widget.isCrossPage) return;
    if (_currentSession == null) return;
    final settings = ref.read(subtitleSettingsProvider);
    if (!settings.isGlobalEnabled(_currentSession!.id)) return;

    if (await SubtitleOverlayController.canDrawOverlays()) {
      await SubtitleOverlayController.startOverlay();

      final bg = settings.backgroundColor ?? const Color(0xFF000000);
      final bgColor = bg.withValues(alpha: settings.backgroundOpacity);
      final txtColor = settings.fontColor ?? const Color(0xFFFFFFFF);

      await SubtitleOverlayController.updateStyle(
        fontSize: settings.fontSize,
        backgroundColor: _toHex(bgColor),
        textColor: _toHex(txtColor),
      );
      if (_subtitleText != null) {
        await SubtitleOverlayController.updateSubtitle(_subtitleText!);
      }
      _isOverlayActive = true;
    }
  }

  String _toHex(Color color) {
    return '#${color.toARGB32().toRadixString(16).padLeft(8, '0')}';
  }

  Future<void> _stopOverlay({bool immediate = false}) async {
    if (!widget.isCrossPage) return;
    if (_isOverlayActive) {
      await SubtitleOverlayController.stopOverlay(immediate: immediate);
      _isOverlayActive = false;
    }
  }

  void _syncSession(PlaybackStateSliceData? playbackState) {
    if (playbackState == null) return;

    final sessions = playbackState.activeSessions;
    final focusedId = playbackState.focusedSessionId;
    PlaybackSession? activeSession;

    if (widget.sessionId != null) {
      activeSession = sessions
          .where((s) => s.id == widget.sessionId)
          .firstOrNull;
    } else {
      if (focusedId != null) {
        activeSession = sessions.where((s) => s.id == focusedId).firstOrNull;
      }
      activeSession ??= sessions.where((s) => s.state.playing).firstOrNull;
      activeSession ??= sessions.firstOrNull;
    }

    if (_currentSession?.id == activeSession?.id &&
        _loadedPath == activeSession?.currentTrackPath) {
      return;
    }

    _currentSession = activeSession;
    unawaited(_positionSub?.cancel());
    _positionSub = null;

    if (_currentSession != null) {
      _positionSub = _currentSession!.positionStream.listen(
        _updateSubtitleText,
      );
      _loadSubtitleTrack();
      if (_isAppInBackground) {
        _syncOverlayState();
      }
    } else if (mounted) {
      setState(() {
        _subtitleTrack = null;
        _subtitleText = null;
        _loadedPath = null;
      });
    }
  }

  void _loadSubtitleTrack() {
    if (_currentSession == null) return;
    final trackPath = _currentSession!.currentTrackPath;
    _loadedPath = trackPath;
    setState(() {
      _subtitleTrack = null;
      _subtitleText = null;
    });

    final provider = ref.read(audioProviderFacadeProvider);
    provider.subtitleTrackForPath(trackPath).then((track) {
      if (!mounted || _loadedPath != trackPath) return;
      _subtitleTrack = track;
      if (_currentSession != null) {
        _updateSubtitleText(_currentSession!.position);
      }
      if (_isOverlayActive) {
        SubtitleOverlayController.updateSubtitle(_subtitleText ?? '');
      }
    });
  }

  void _updateSubtitleText(Duration position) {
    if (_currentSession == null) return;
    final provider = ref.read(audioProviderFacadeProvider);
    final nextText = provider.subtitleTextForTrackAt(
      _currentSession!.currentTrackPath,
      position,
      subtitleTrack: _subtitleTrack,
    );

    if (nextText != _subtitleText) {
      setState(() {
        _subtitleText = nextText;
      });
      if (_isOverlayActive) {
        SubtitleOverlayController.updateSubtitle(nextText ?? '');
      }
    }
  }

  @override
  void didUpdateWidget(covariant FloatingSubtitleWindow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionId != widget.sessionId) {
      _syncSession(ref.read(playbackStateProvider).valueOrNull);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(playbackStateProvider);
    final settings = ref.watch(subtitleSettingsProvider);

    final sessionId = _currentSession?.id ?? '';
    final trackPath = _currentSession?.currentTrackPath ?? '';
    if (!settings.isShowEnabled(sessionId)) return const SizedBox.shrink();
    if (widget.isCrossPage && !settings.isGlobalEnabled(sessionId)) {
      return const SizedBox.shrink();
    }

    // Try sync load if not loaded yet
    if (_subtitleTrack == null && trackPath.isNotEmpty) {
      final provider = ref.read(audioProviderFacadeProvider);
      final cached = provider.getSubtitleTrackSync(trackPath);
      if (cached != null) {
        _subtitleTrack = cached;
        if (_currentSession != null) {
          _subtitleText = provider.subtitleTextForTrackAt(
            trackPath,
            _currentSession!.position,
            subtitleTrack: cached,
          );
        }
      }
    }

    if (_subtitleTrack == null || _subtitleTrack!.cues.isEmpty) {
      return const SizedBox.shrink();
    }

    final screenHeight = MediaQuery.sizeOf(context).height;
    final screenWidth = MediaQuery.sizeOf(context).width;

    double top;
    if (widget.overrideTop != null) {
      top = widget.overrideTop!;
    } else {
      top = _dragY ?? settings.positions[_currentSession?.id] ?? -1.0;
      if (top < 0) {
        if (widget.isCrossPage) {
          top = screenHeight - 151;
        } else {
          top = widget.defaultTop ?? screenHeight * 0.60;
        }
      }
    }

    top = top.clamp(40.0, screenHeight - 60.0);
    final isTinyWindow = screenWidth < 300 || screenHeight < 300;

    return Positioned(
      top: top,
      left: 0,
      right: 0,
      child: FractionalTranslation(
        translation: const Offset(0, -0.5),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.translucent,
              onVerticalDragStart: (_) {
                _dragY = top;
                _snapHapticFired = false;
              },
              onVerticalDragUpdate: (details) {
                setState(() {
                  var newY = (_dragY ?? top) + (details.primaryDelta ?? 0);
                  final defaultTop = widget.isCrossPage
                      ? null
                      : (widget.defaultTop ?? screenHeight * 0.60);
                  if (defaultTop != null) {
                    final dist = (newY - defaultTop).abs();
                    if (dist < 25) {
                      if (!_snapHapticFired) {
                        _snapHapticFired = true;
                        HapticFeedback.selectionClick();
                      }
                      final pull = (1.0 - dist / 25.0).clamp(0.0, 1.0) * 0.45;
                      newY = newY + (defaultTop - newY) * pull;
                    } else {
                      _snapHapticFired = false;
                    }
                  }
                  _dragY = newY;
                });
              },
              onVerticalDragEnd: (details) {
                if (_dragY != null && _currentSession != null) {
                  final defaultTop = widget.isCrossPage
                      ? null
                      : (widget.defaultTop ?? screenHeight * 0.60);
                  final currentY = _dragY!;
                  final snapToDefault =
                      defaultTop != null && (currentY - defaultTop).abs() < 30;
                  if (snapToDefault) {
                    ref
                        .read(subtitleSettingsProvider.notifier)
                        .updatePosition(_currentSession!.id, -1);
                  } else {
                    ref
                        .read(subtitleSettingsProvider.notifier)
                        .updatePosition(_currentSession!.id, currentY);
                  }
                  setState(() {
                    _dragY = null;
                  });
                }
              },
              onVerticalDragCancel: () {
                setState(() {
                  _dragY = null;
                });
              },
              child: SubtitleWindowVisual(
                settings: settings,
                text: _subtitleText ?? '',
                maxTextWidth: screenWidth * 0.8,
                enableBackdropBlur: !isTinyWindow,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
