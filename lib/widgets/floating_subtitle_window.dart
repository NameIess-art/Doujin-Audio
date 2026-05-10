import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/audio_provider.dart';
import '../providers/audio_provider_riverpod.dart';
import '../providers/subtitle_settings_provider.dart';
import '../services/audio_state_services.dart';
import '../services/subtitle_parser.dart';

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

class _FloatingSubtitleWindowState
    extends ConsumerState<FloatingSubtitleWindow> {
  ProviderSubscription<AsyncValue<PlaybackStateSliceData>>? _playbackStateSub;
  ProviderSubscription<SubtitleSettingsState>? _subtitleSettingsSub;
  StreamSubscription<Duration>? _positionSub;
  SubtitleTrack? _subtitleTrack;
  String? _subtitleText;
  String? _loadedPath;
  PlaybackSession? _currentSession;
  double? _dragY;
  bool _snapHapticFired = false;

  @override
  void initState() {
    super.initState();
    _playbackStateSub = ref.listenManual<AsyncValue<PlaybackStateSliceData>>(
      playbackStateProvider,
      (previous, next) {
        _syncSession(next.valueOrNull);
      },
      fireImmediately: true,
    );
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
      _positionSub = _currentSession!.positionStream.listen(_updateSubtitleText);
      _loadSubtitleTrack();
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
    if (_subtitleText == nextText) return;
    setState(() {
      _subtitleText = nextText;
    });
  }

  @override
  void didUpdateWidget(covariant FloatingSubtitleWindow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionId != widget.sessionId) {
      _syncSession(ref.read(playbackStateProvider).valueOrNull);
    }
  }

  @override
  void dispose() {
    _playbackStateSub?.close();
    _positionSub?.cancel();
    super.dispose();
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
        // Also update text immediately if possible
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
          top = screenHeight - 151; // Above the bottom playback card (3px optical offset)
        } else {
          top = widget.defaultTop ?? screenHeight * 0.60;
        }
      }
    }

    // Ensure it's within bounds
    // Ensure it's within bounds, allowing more freedom near bottom but keeping it visible
    top = top.clamp(40.0, screenHeight - 60.0);

    final isSmallWindow = screenWidth < 450 || screenHeight < 400;

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
                      // Apply magnetic pull: toned down to make it easier to drag out
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
                  final snapToDefault = defaultTop != null && (currentY - defaultTop).abs() < 30;

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
              child: ClipRect(
                child: BackdropFilter(
                  filter: ImageFilter.blur(
                    sigmaX: settings.backgroundBlur, 
                    sigmaY: settings.backgroundBlur,
                  ),
                  child: Container(
                    constraints: const BoxConstraints(minHeight: 34),
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                    decoration: BoxDecoration(
                      color: settings.backgroundColor != null
                          ? settings.backgroundColor!.withValues(alpha: settings.backgroundOpacity)
                          : Theme.of(context).colorScheme.surface.withValues(alpha: settings.backgroundOpacity),
                      border: Border(
                        top: BorderSide(
                          color: Colors.white.withValues(alpha: 0.1 * settings.borderDepth),
                          width: settings.borderDepth,
                        ),
                        bottom: BorderSide(
                          color: Colors.white.withValues(alpha: 0.1 * settings.borderDepth),
                          width: settings.borderDepth,
                        ),
                      ),
                    ),
                    child: _buildSubtitleContent(context, settings, screenWidth),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSubtitleContent(BuildContext context, SubtitleSettingsState settings, double screenWidth) {
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: screenWidth * 0.8),
        child: Text(
          _subtitleText ?? '',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
            color: settings.fontColor ??
                Theme.of(context).colorScheme.onSurface,
            fontWeight: FontWeight.w700,
            fontSize: settings.fontSize,
            fontFamily:
                settings.fontFamily.isEmpty
                    ? null
                    : settings.fontFamily,
            shadows: [
              Shadow(
                color: Colors.black.withValues(alpha: 0.5),
                blurRadius: 4,
                offset: const Offset(0, 1),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
