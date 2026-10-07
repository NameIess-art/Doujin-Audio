import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/presentation/app_presentation_providers.dart';
import '../../../../app/state/app_runtime_providers.dart';
import '../../../../core/media/subtitle_parser.dart';
import '../../../../core/logging/app_log_service.dart';
import '../../../../core/widgets/app_transitions.dart';
import '../../../../core/widgets/shimmer_loading.dart';
import '../../../../core/ui/ui_interaction_coordinator.dart';
import '../../application/playback_session_snapshot.dart';
import '../../application/playback_subtitle_service.dart';
import '../playback_error_text.dart';
import '../playback_position_ui_gate.dart';
import '../playback_providers.dart';
import 'playlist_shared_helpers.dart';

import 'timeline_subtitle_view.dart';
export 'timeline_subtitle_view.dart' show TimelineSubtitleView;

class SessionSubtitlePanel extends ConsumerStatefulWidget {
  const SessionSubtitlePanel({
    super.key,
    required this.session,
    this.subtitleEnabled = true,
    this.transitionActive,
  });

  final PlaybackSessionSnapshot session;
  final bool subtitleEnabled;
  final ValueListenable<bool>? transitionActive;

  @override
  ConsumerState<SessionSubtitlePanel> createState() =>
      _SessionSubtitlePanelState();
}

class _SessionSubtitlePanelState extends ConsumerState<SessionSubtitlePanel> {
  late final PlaybackPositionUiGate _positionGate;
  SubtitleTrack? _subtitleTrack;
  int? _playbackSubtitleIndex;
  String? _loadedPath;
  bool _tickerModeEnabled = true;
  int _loadGeneration = 0;
  late final String _commitKey = 'detail_subtitle_${identityHashCode(this)}';
  VoidCallback? _pendingSubtitle;
  late final PlaybackSubtitleService _subtitleService;

  @override
  void initState() {
    super.initState();
    widget.transitionActive?.addListener(_schedulePendingSubtitle);
    _positionGate = PlaybackPositionUiGate(
      session: widget.session,
      includeBufferedPosition: false,
    )..addListener(_handlePositionTick);
    _subtitleService = ref.read(playbackSubtitleServiceProvider)
      ..addListener(_handleSubtitleServiceChanged);
    if (widget.subtitleEnabled) {
      _scheduleSubtitleTrackLoad();
    }
  }

  @override
  void didUpdateWidget(covariant SessionSubtitlePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.transitionActive != widget.transitionActive) {
      oldWidget.transitionActive?.removeListener(_schedulePendingSubtitle);
      widget.transitionActive?.addListener(_schedulePendingSubtitle);
      _schedulePendingSubtitle();
    }
    if (oldWidget.session != widget.session) {
      _positionGate.updateSession(widget.session);
    }
    if (oldWidget.session.id != widget.session.id ||
        _loadedPath != widget.session.currentTrackPath ||
        oldWidget.subtitleEnabled != widget.subtitleEnabled) {
      _loadGeneration++;
      _pendingSubtitle = null;
      UiInteractionCoordinator.instance.cancelCommit(_commitKey);
    }
    if (oldWidget.session.id != widget.session.id ||
        _loadedPath != widget.session.currentTrackPath ||
        (!oldWidget.subtitleEnabled && widget.subtitleEnabled)) {
      if (widget.subtitleEnabled) {
        _scheduleSubtitleTrackLoad();
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nextTickerMode = TickerMode.valuesOf(context).enabled;
    if (_tickerModeEnabled == nextTickerMode) return;
    _tickerModeEnabled = nextTickerMode;
    _positionGate.tickerModeEnabled = nextTickerMode;
    if (nextTickerMode) _handlePositionTick();
  }

  @override
  void dispose() {
    _loadGeneration++;
    _pendingSubtitle = null;
    _subtitleService.removeListener(_handleSubtitleServiceChanged);
    widget.transitionActive?.removeListener(_schedulePendingSubtitle);
    UiInteractionCoordinator.instance.cancelCommit(_commitKey);
    _positionGate
      ..removeListener(_handlePositionTick)
      ..dispose();
    super.dispose();
  }

  void _handlePositionTick() {
    _updateSubtitleIndex(_positionGate.value.position);
  }

  void _scheduleSubtitleTrackLoad() {
    final generation = ++_loadGeneration;
    final sessionId = widget.session.id;
    _pendingSubtitle = null;
    UiInteractionCoordinator.instance.cancelCommit(_commitKey);
    final trackPath = widget.session.currentTrackPath;
    final isTrackChanged = _loadedPath != trackPath;
    _loadedPath = trackPath;
    if (isTrackChanged) {
      setState(() {
        _subtitleTrack = null;
        _playbackSubtitleIndex = null;
      });
    }
    final subtitles = _subtitleService;
    if (subtitles.hasResult(trackPath)) {
      _applySubtitleTrack(trackPath, subtitles.trackSync(trackPath));
      return;
    }
    void load() {
      unawaited(
        subtitles
            .load(trackPath)
            .then(
              (track) {
                if (!mounted ||
                    generation != _loadGeneration ||
                    sessionId != widget.session.id ||
                    !widget.subtitleEnabled) {
                  return;
                }
                _pendingSubtitle = () => _applySubtitleTrack(trackPath, track);
                _schedulePendingSubtitle();
              },
              onError: (Object error, StackTrace stack) {
                if (!mounted || generation != _loadGeneration) return;
                AppLogService.warning(
                  'Detail subtitle failed to load',
                  error: error,
                  stackTrace: stack,
                );
              },
            ),
      );
    }

    // Defer the read/decoding and service notifications as well as the result.
    // Cached subtitles above remain available in the very first route frame.
    if (widget.transitionActive?.value == true ||
        UiInteractionCoordinator.instance.isInteracting) {
      _pendingSubtitle = load;
      _schedulePendingSubtitle();
    } else {
      load();
    }
  }

  void _schedulePendingSubtitle() {
    if (_pendingSubtitle == null || widget.transitionActive?.value == true) {
      return;
    }
    final generation = _loadGeneration;
    UiInteractionCoordinator.instance.scheduleCommit(
      key: _commitKey,
      commit: () {
        if (!mounted ||
            generation != _loadGeneration ||
            widget.transitionActive?.value == true) {
          return;
        }
        final apply = _pendingSubtitle;
        _pendingSubtitle = null;
        apply?.call();
      },
    );
  }

  void _handleSubtitleServiceChanged() {
    if (!mounted || !widget.subtitleEnabled) return;
    final trackPath = widget.session.currentTrackPath;
    final subtitles = _subtitleService;
    if (subtitles.hasResult(trackPath)) {
      final updated = subtitles.trackSync(trackPath);
      if (!identical(_subtitleTrack, updated) ||
          _subtitleTrack?.offset != updated?.offset) {
        if (widget.transitionActive?.value == true) {
          _pendingSubtitle = () => _applySubtitleTrack(trackPath, updated);
          _schedulePendingSubtitle();
        } else {
          _applySubtitleTrack(trackPath, updated);
        }
      }
    } else if (!subtitles.isLoading(trackPath)) {
      _scheduleSubtitleTrackLoad();
    }
  }

  void _applySubtitleTrack(String trackPath, SubtitleTrack? track) {
    if (!mounted || _loadedPath != trackPath) return;
    setState(() {
      _subtitleTrack = track;
      _playbackSubtitleIndex = _timelineSubtitleIndexAt(
        track,
        _positionGate.value.position,
      );
    });
  }

  void _updateSubtitleIndex(Duration position) {
    if (!_tickerModeEnabled) return;
    final track = _subtitleTrack;
    final nextIndex = _timelineSubtitleIndexAt(track, position);
    if (_playbackSubtitleIndex == nextIndex) return;
    setState(() {
      _playbackSubtitleIndex = nextIndex;
    });
  }

  int? _timelineSubtitleIndexAt(SubtitleTrack? track, Duration position) {
    final cues = track?.cues;
    if (cues == null || cues.isEmpty) return null;
    final effectivePosition = position - (track?.offset ?? Duration.zero);
    if (effectivePosition < cues.first.start) return 0;

    var low = 0;
    var high = cues.length - 1;
    var result = 0;
    while (low <= high) {
      final mid = low + ((high - low) >> 1);
      if (cues[mid].start <= effectivePosition) {
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
    final detail = ref.watch(
      sessionDetailTransportProvider(widget.session.id).select(
        (state) => (
          state == null ? widget.session.playbackError : state.playbackError,
          state?.isLoading ?? widget.session.isLoading,
        ),
      ),
    );
    final playbackError = detail.$1;
    final isLoading = detail.$2;
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final transitionDuration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : kPlaceholderContentTransitionDuration;

    late final Widget content;
    final subtitleTrack = _subtitleTrack;
    final trackPath = widget.session.currentTrackPath;
    final subtitles = _subtitleService;
    final hasTrack = trackPath.isNotEmpty;
    final hasResult = hasTrack && subtitles.hasResult(trackPath);
    final isSubtitlePending =
        hasTrack &&
        (isLoading ||
            _pendingSubtitle != null ||
            !hasResult ||
            (subtitleTrack == null && subtitles.isLoading(trackPath)));
    final playbackSubtitleIndex =
        _playbackSubtitleIndex ??
        (subtitleTrack != null && subtitleTrack.cues.isNotEmpty ? 0 : null);

    if (!widget.subtitleEnabled) {
      content = Center(
        key: const ValueKey('subtitle_empty'),
        child: Text(
          i18n.tr('no_subtitle_for_track'),
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: sessionDetailForeground(
              Theme.of(context).colorScheme,
              SessionDetailForegroundLevel.muted,
              darkFallback: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.6),
            ),
            fontSize: 14,
          ),
        ),
      );
    } else if (playbackError != null) {
      content = Center(
        key: const ValueKey('subtitle_error'),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Text(
            localizedPlaybackErrorText(i18n, playbackError),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Colors.redAccent,
              fontWeight: FontWeight.w600,
              fontSize: 14,
              height: 1.3,
            ),
          ),
        ),
      );
    } else if (isSubtitlePending) {
      content = const SessionSubtitlePlaceholder(
        key: ValueKey('subtitle_loading'),
      );
    } else if (subtitleTrack != null &&
        subtitleTrack.cues.isNotEmpty &&
        playbackSubtitleIndex != null) {
      content = TimelineSubtitleView(
        key: ValueKey<Object>((widget.session.id, subtitleTrack)),
        cues: subtitleTrack.cues,
        playbackSubtitleIndex: playbackSubtitleIndex,
        onSeek: (position) {
          final target = position + subtitleTrack.offset;
          final clamped = target < Duration.zero ? Duration.zero : target;
          return ref
              .read(playbackFacadeProvider)
              .seekSession(widget.session.id, clamped);
        },
      );
    } else {
      content = Center(
        key: const ValueKey('subtitle_empty'),
        child: Text(
          i18n.tr('no_subtitle_for_track'),
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: sessionDetailForeground(
              Theme.of(context).colorScheme,
              SessionDetailForegroundLevel.muted,
              darkFallback: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.6),
            ),
            fontSize: 14,
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final animatedContent = AnimatedSwitcher(
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
              alignment: Alignment.center,
              fit: constraints.maxHeight.isFinite
                  ? StackFit.expand
                  : StackFit.loose,
              children: [...previousChildren, ?currentChild],
            );
          },
          child: content,
        );

        if (constraints.maxHeight.isFinite) {
          return SizedBox.expand(child: animatedContent);
        }

        return AnimatedSize(
          duration: transitionDuration,
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: animatedContent,
        );
      },
    );
  }
}

class SessionSubtitlePlaceholder extends StatelessWidget {
  const SessionSubtitlePlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.maxWidth.isFinite
            ? max(0.0, constraints.maxWidth - 40.0)
            : 240.0;
        final centerWidth = min(240.0, max(80.0, availableWidth * 0.70));
        final topWidth = min(centerWidth * 0.75, max(60.0, availableWidth * 0.50));
        final bottomWidth = min(centerWidth * 0.85, max(70.0, availableWidth * 0.58));

        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Opacity(
                opacity: 0.35,
                child: ShimmerContainer(
                  width: topWidth,
                  height: 14,
                  borderRadius: 4,
                ),
              ),
              const SizedBox(height: 16),
              ShimmerContainer(
                width: centerWidth,
                height: 16,
                borderRadius: 4,
              ),
              const SizedBox(height: 16),
              Opacity(
                opacity: 0.35,
                child: ShimmerContainer(
                  width: bottomWidth,
                  height: 14,
                  borderRadius: 4,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
