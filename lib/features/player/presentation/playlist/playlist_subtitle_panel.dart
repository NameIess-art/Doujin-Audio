import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/presentation/app_presentation_providers.dart';
import '../../../../app/state/app_runtime_providers.dart';
import '../../../../app/theme/app_design_tokens.dart';
import '../../../../core/media/subtitle_parser.dart';
import '../../../../core/logging/app_log_service.dart';
import '../../../../core/ui/ui_interaction_coordinator.dart';
import '../../../../core/widgets/app_feedback.dart';
import '../../../settings/application/settings_state.dart';
import '../../../settings/presentation/settings_providers.dart';
import '../../application/playback_session_snapshot.dart';
import '../playback_error_text.dart';
import '../playback_position_ui_gate.dart';
import '../playback_providers.dart';
import 'playlist_shared_helpers.dart';

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
  final SubtitleTextCache _subtitleTextCache = SubtitleTextCache();
  SubtitleTrack? _subtitleTrack;
  String? _subtitleText;
  int? _playbackSubtitleIndex;
  String? _loadedPath;
  bool _tickerModeEnabled = true;
  int _loadGeneration = 0;
  late final String _commitKey = 'detail_subtitle_${identityHashCode(this)}';
  VoidCallback? _pendingSubtitle;

  @override
  void initState() {
    super.initState();
    widget.transitionActive?.addListener(_schedulePendingSubtitle);
    _positionGate = PlaybackPositionUiGate(
      session: widget.session,
      includeBufferedPosition: false,
    )..addListener(_handlePositionTick);
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
    widget.transitionActive?.removeListener(_schedulePendingSubtitle);
    UiInteractionCoordinator.instance.cancelCommit(_commitKey);
    _positionGate
      ..removeListener(_handlePositionTick)
      ..dispose();
    super.dispose();
  }

  void _handlePositionTick() {
    _updateSubtitleText(_positionGate.value.position);
  }

  void _scheduleSubtitleTrackLoad() {
    final generation = ++_loadGeneration;
    final sessionId = widget.session.id;
    _pendingSubtitle = null;
    UiInteractionCoordinator.instance.cancelCommit(_commitKey);
    final trackPath = widget.session.currentTrackPath;
    _loadedPath = trackPath;
    _subtitleTextCache.clear();
    setState(() {
      _subtitleTrack = null;
      _subtitleText = null;
      _playbackSubtitleIndex = null;
    });
    final subtitles = ref.read(playbackSubtitleServiceProvider);
    if (subtitles.hasResult(trackPath)) {
      _applySubtitleTrack(trackPath, subtitles.trackSync(trackPath));
      return;
    }
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

  void _applySubtitleTrack(String trackPath, SubtitleTrack? track) {
    if (!mounted || _loadedPath != trackPath) return;
    _subtitleTrack = track;
    _subtitleTextCache.clear();
    _updateSubtitleText(_positionGate.value.position);
  }

  void _updateSubtitleText(Duration position) {
    if (!_tickerModeEnabled) return;
    final track = _subtitleTrack;
    final nextText = _subtitleTextCache.resolve(
      trackPath: widget.session.currentTrackPath,
      position: position,
      track: track,
    );
    final nextIndex = _timelineSubtitleIndexAt(track, position);
    if (_subtitleText == nextText && _playbackSubtitleIndex == nextIndex) {
      return;
    }
    setState(() {
      _subtitleText = nextText;
      _playbackSubtitleIndex = nextIndex;
    });
  }

  int? _timelineSubtitleIndexAt(SubtitleTrack? track, Duration position) {
    final cues = track?.cues;
    if (cues == null || cues.isEmpty) return null;
    if (position < cues.first.start) return 0;

    var low = 0;
    var high = cues.length - 1;
    var result = 0;
    while (low <= high) {
      final mid = low + ((high - low) >> 1);
      if (cues[mid].start <= position) {
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
          state?.isLoading,
        ),
      ),
    );
    final playbackError = detail.$1;
    final isLoading = detail.$2 ?? widget.session.isPlaybackLoading;
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final transitionDuration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : AppDesignTokens.of(context).motionStandard;

    late final Widget content;
    if (!widget.subtitleEnabled) {
      content = const SizedBox.shrink(key: ValueKey('subtitle_empty'));
    } else if (isLoading) {
      content = Container(
        key: const ValueKey('subtitle_loading'),
        margin: const EdgeInsets.only(top: 8),
        width: double.infinity,
        height: 44,
        padding: EdgeInsets.zero,
        alignment: Alignment.topLeft,
        child: ClipRect(
          child: Text(
            i18n.tr('playback_loading'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
              fontSize: 16,
              height: 1.3,
            ),
          ),
        ),
      );
    } else if (playbackError != null) {
      content = Container(
        key: const ValueKey('subtitle_error'),
        margin: const EdgeInsets.only(top: 8),
        width: double.infinity,
        height: 44,
        padding: EdgeInsets.zero,
        alignment: Alignment.topLeft,
        child: ClipRect(
          child: Text(
            localizedPlaybackErrorText(i18n, playbackError),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Colors.redAccent,
              fontWeight: FontWeight.w600,
              fontSize: 16,
              height: 1.3,
            ),
          ),
        ),
      );
    } else {
      final subtitleStyle = ref.watch(
        settingsStateProvider.select(
          (state) =>
              state.value?.playbackDetailSubtitleStyle ??
              PlaybackDetailSubtitleStyle.compact,
        ),
      );
      final subtitleTrack = _subtitleTrack;
      final playbackSubtitleIndex = _playbackSubtitleIndex;
      if (subtitleStyle == PlaybackDetailSubtitleStyle.timeline &&
          subtitleTrack != null &&
          subtitleTrack.cues.isNotEmpty &&
          playbackSubtitleIndex != null) {
        content = _TimelineSubtitleView(
          key: ValueKey<Object>((widget.session.id, subtitleTrack)),
          cues: subtitleTrack.cues,
          playbackSubtitleIndex: playbackSubtitleIndex,
          onSeek: (position) => ref
              .read(playbackFacadeProvider)
              .seekSession(widget.session.id, position),
        );
      } else {
        final subtitleText = _subtitleText;
        content = subtitleText == null
            ? const SizedBox.shrink(key: ValueKey('subtitle_empty'))
            : _SubtitleChip(key: ValueKey(subtitleText), text: subtitleText);
      }
    }

    return AnimatedSize(
      duration: transitionDuration,
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: AnimatedSwitcher(
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
            alignment: Alignment.topCenter,
            children: [...previousChildren, ?currentChild],
          );
        },
        child: content,
      ),
    );
  }
}

class _SubtitleChip extends StatelessWidget {
  const _SubtitleChip({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      width: double.infinity,
      height: 44,
      padding: EdgeInsets.zero,
      alignment: Alignment.topCenter,
      child: ClipRect(
        child: SizedBox(
          width: double.infinity,
          child: Text(
            text,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: sessionDetailForeground(
                cs,
                SessionDetailForegroundLevel.medium,
                darkFallback: cs.onSurface.withValues(alpha: 0.85),
              ),
              fontWeight: FontWeight.w600,
              fontSize: 16,
              height: 1.3,
            ),
          ),
        ),
      ),
    );
  }
}

class _TimelineSubtitleView extends StatefulWidget {
  const _TimelineSubtitleView({
    super.key,
    required this.cues,
    required this.playbackSubtitleIndex,
    required this.onSeek,
  });

  final List<SubtitleCue> cues;
  final int playbackSubtitleIndex;
  final Future<void> Function(Duration position) onSeek;

  @override
  State<_TimelineSubtitleView> createState() => _TimelineSubtitleViewState();
}

class _TimelineSubtitleViewState extends State<_TimelineSubtitleView> {
  @visibleForTesting
  int debugMeasuredCueCount = 0;
  @visibleForTesting
  int get debugFocusedIndex => _focusedIndex;
  static const int _initialWindowRadius = 30;
  static const int _windowExpansionSize = 30;
  static const int _windowExpansionThreshold = 4;
  static const double _minimumItemExtent = 48;
  static const double _minimumViewportHeight = _minimumItemExtent * 2;
  static const double _textHorizontalPadding = 20;
  static const double _textVerticalPadding = 6;
  static const Duration _returnDelay = Duration(seconds: 3);
  static const Duration _focusHapticInterval = Duration(milliseconds: 110);

  late final ScrollController _scrollController;
  late int _focusedIndex;
  int _windowStart = 0;
  int _windowEnd = 0;
  List<double> _itemExtents = const <double>[];
  List<double> _itemCenters = const <double>[];
  double _viewportHeight = _minimumViewportHeight;
  double _leadingPadding = _minimumItemExtent / 2;
  double _trailingPadding = _minimumItemExtent / 2;
  (Object, int, int, double, TextScaler, TextDirection, TextStyle)?
  _layoutSignature;
  Timer? _returnTimer;
  bool _isBrowsing = false;
  bool _isSnapping = false;
  bool _isProgrammaticScroll = false;
  bool _isPointerDown = false;
  bool _snapScheduled = false;
  bool _layoutAlignmentScheduled = false;
  int? _wheelTargetIndex;

  int get _lastIndex => widget.cues.length - 1;
  int get _windowLength => _windowEnd - _windowStart;
  bool get _hasCurrentWindowLayout =>
      _layoutSignature?.$2 == _windowStart &&
      _layoutSignature?.$3 == _windowEnd;

  @override
  void initState() {
    super.initState();
    _focusedIndex = widget.playbackSubtitleIndex.clamp(0, _lastIndex);
    _resetWindowAround(_focusedIndex);
    _scrollController = ScrollController()
      ..addListener(_handleScrollOffsetChanged);
  }

  @override
  void didUpdateWidget(covariant _TimelineSubtitleView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final playbackIndex = widget.playbackSubtitleIndex.clamp(0, _lastIndex);
    if (!identical(oldWidget.cues, widget.cues)) {
      _focusedIndex = playbackIndex;
      _wheelTargetIndex = null;
      _resetWindowAround(playbackIndex);
      return;
    }
    if (_isBrowsing || _isPointerDown) {
      if (_focusedIndex == playbackIndex) {
        _returnTimer?.cancel();
        _isBrowsing = false;
      }
      return;
    }
    if (oldWidget.playbackSubtitleIndex != widget.playbackSubtitleIndex) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_isBrowsing && !_isPointerDown) {
          _scrollToIndex(playbackIndex);
        }
      });
    }
  }

  @override
  void dispose() {
    _returnTimer?.cancel();
    _scrollController
      ..removeListener(_handleScrollOffsetChanged)
      ..dispose();
    super.dispose();
  }

  void _handlePointerDown(PointerDownEvent event) {
    _isPointerDown = true;
    _wheelTargetIndex = null;
    _returnTimer?.cancel();
  }

  void _handlePointerReleased(PointerEvent event) {
    _isPointerDown = false;
    if (_isBrowsing) _scheduleImmediateSnap();
  }

  void _handlePointerSignal(PointerSignalEvent signal) {
    if (defaultTargetPlatform == TargetPlatform.windows &&
        signal is PointerScrollEvent) {
      GestureBinding.instance.pointerSignalResolver.register(signal, (event) {
        final scrollEvent = event as PointerScrollEvent;
        if (scrollEvent.scrollDelta.dy == 0) return;
        final delta = scrollEvent.scrollDelta.dy > 0 ? 1 : -1;
        _scrollByOneLine(delta);
      });
    }
  }

  void _scrollByOneLine(int delta) {
    if (widget.cues.isEmpty) return;
    final baseIndex = _wheelTargetIndex ?? _focusedIndex;
    final nextIndex = (baseIndex + delta).clamp(0, _lastIndex);
    if (nextIndex == _focusedIndex && _wheelTargetIndex == nextIndex) return;
    _wheelTargetIndex = nextIndex;

    _returnTimer?.cancel();
    if (!_isBrowsing) {
      AppInteractionFeedback.resetContinuous();
      setState(() => _isBrowsing = true);
    }
    _scrollToIndex(nextIndex);
    _extendWindowNearFocusedIndex();

    unawaited(
      AppInteractionFeedback.continuous(
        '${widget.key}:$_focusedIndex',
        interval: _focusHapticInterval,
      ),
    );

    final playbackIndex = widget.playbackSubtitleIndex.clamp(0, _lastIndex);
    if (_focusedIndex == playbackIndex) {
      setState(() => _isBrowsing = false);
    } else {
      _returnTimer = Timer(_returnDelay, _returnToPlaybackSubtitle);
    }
  }

  void _scheduleImmediateSnap() {
    if (_snapScheduled || _isSnapping) return;
    _snapScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _snapScheduled = false;
      if (mounted && _isBrowsing && !_isPointerDown) {
        _finishManualScroll();
      }
    });
  }

  void _handleScrollOffsetChanged() {
    if (!_scrollController.hasClients ||
        _itemCenters.isEmpty ||
        !_hasCurrentWindowLayout) {
      return;
    }
    final viewportCenter = _scrollController.offset + (_viewportHeight / 2);
    final nextIndex = _windowStart + _nearestWindowItemIndex(viewportCenter);
    if (nextIndex == _focusedIndex || !mounted) return;
    _wheelTargetIndex = null;
    setState(() => _focusedIndex = nextIndex);
    if (_isBrowsing) {
      unawaited(
        AppInteractionFeedback.continuous(
          '${widget.key}:$nextIndex',
          interval: _focusHapticInterval,
        ),
      );
    }
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    if (_isProgrammaticScroll) return false;
    if (notification is ScrollStartNotification ||
        (notification is ScrollUpdateNotification &&
            notification.scrollDelta != null &&
            notification.scrollDelta!.abs() > 0)) {
      _returnTimer?.cancel();
      if (!_isBrowsing) {
        AppInteractionFeedback.resetContinuous();
        setState(() => _isBrowsing = true);
      }
    } else if (notification is ScrollEndNotification) {
      _wheelTargetIndex = null;
      if (_isBrowsing && !_isPointerDown) {
        _finishManualScroll();
      }
    }
    return false;
  }

  void _finishManualScroll() {
    if (_isSnapping || !mounted) return;
    _isSnapping = true;
    try {
      _extendWindowNearFocusedIndex();
      _scrollToIndex(_focusedIndex);
    } finally {
      _isSnapping = false;
    }
    if (!mounted || !_isBrowsing) return;
    final playbackIndex = widget.playbackSubtitleIndex.clamp(0, _lastIndex);
    if (_focusedIndex == playbackIndex) {
      setState(() => _isBrowsing = false);
      return;
    }
    _returnTimer?.cancel();
    _returnTimer = Timer(_returnDelay, _returnToPlaybackSubtitle);
  }

  void _returnToPlaybackSubtitle() {
    _returnTimer = null;
    _wheelTargetIndex = null;
    if (!mounted) return;
    final playbackIndex = widget.playbackSubtitleIndex.clamp(0, _lastIndex);
    setState(() => _isBrowsing = false);
    _scrollToIndex(playbackIndex);
  }

  void _scrollToIndex(int index) {
    final targetIndex = index.clamp(0, _lastIndex);
    if (_focusedIndex != targetIndex || !_windowContains(targetIndex)) {
      setState(() {
        _focusedIndex = targetIndex;
        if (!_windowContains(targetIndex)) {
          _resetWindowAround(targetIndex);
        }
      });
    }
    if (!_scrollController.hasClients ||
        _itemCenters.isEmpty ||
        !_hasCurrentWindowLayout) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scrollToIndex(targetIndex);
      });
      return;
    }
    final position = _scrollController.position;
    final localIndex = targetIndex - _windowStart;
    final targetOffset = (_itemCenters[localIndex] - (_viewportHeight / 2))
        .clamp(position.minScrollExtent, position.maxScrollExtent)
        .toDouble();
    if ((_scrollController.offset - targetOffset).abs() < 0.5) return;
    _isProgrammaticScroll = true;
    try {
      _scrollController.jumpTo(targetOffset);
    } finally {
      _isProgrammaticScroll = false;
    }
  }

  void _seekToFocusedSubtitle() {
    _wheelTargetIndex = null;
    _returnTimer?.cancel();
    if (_isBrowsing) {
      setState(() => _isBrowsing = false);
    }
    unawaited(widget.onSeek(widget.cues[_focusedIndex].start));
  }

  int _nearestWindowItemIndex(double viewportCenter) {
    var low = 0;
    var high = _itemCenters.length;
    while (low < high) {
      final mid = low + ((high - low) >> 1);
      if (_itemCenters[mid] < viewportCenter) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    if (low == 0) return 0;
    if (low == _itemCenters.length) return _itemCenters.length - 1;
    final previous = low - 1;
    return viewportCenter - _itemCenters[previous] <=
            _itemCenters[low] - viewportCenter
        ? previous
        : low;
  }

  bool _windowContains(int index) =>
      index >= _windowStart && index < _windowEnd;

  void _resetWindowAround(int index) {
    final targetIndex = index.clamp(0, _lastIndex);
    _windowStart = max(0, targetIndex - _initialWindowRadius);
    _windowEnd = min(
      widget.cues.length,
      targetIndex + _initialWindowRadius + 1,
    );
    _invalidateLayoutMetrics();
  }

  void _extendWindowNearFocusedIndex() {
    var nextStart = _windowStart;
    var nextEnd = _windowEnd;
    if (_focusedIndex - _windowStart <= _windowExpansionThreshold) {
      nextStart = max(0, _windowStart - _windowExpansionSize);
    }
    if ((_windowEnd - 1) - _focusedIndex <= _windowExpansionThreshold) {
      nextEnd = min(widget.cues.length, _windowEnd + _windowExpansionSize);
    }
    if (nextStart == _windowStart && nextEnd == _windowEnd) return;
    setState(() {
      _windowStart = nextStart;
      _windowEnd = nextEnd;
    });
  }

  void _invalidateLayoutMetrics() {
    _layoutSignature = null;
    _itemExtents = const <double>[];
    _itemCenters = const <double>[];
  }

  double _measureCueExtent(
    SubtitleCue cue, {
    required double textWidth,
    required TextStyle textStyle,
    required TextDirection textDirection,
    required TextScaler textScaler,
  }) {
    assert(() {
      debugMeasuredCueCount++;
      return true;
    }());
    final painter = TextPainter(
      text: TextSpan(text: cue.text, style: textStyle),
      textAlign: TextAlign.center,
      textDirection: textDirection,
      textScaler: textScaler,
    )..layout(maxWidth: textWidth);
    return max(
      _minimumItemExtent,
      (painter.height * 1.03) + (_textVerticalPadding * 2),
    );
  }

  void _updateLayoutMetrics(List<double> itemExtents) {
    if (itemExtents.isEmpty) {
      _itemExtents = const [];
      _itemCenters = const [];
      _viewportHeight = _minimumViewportHeight;
      _leadingPadding = 0.0;
      _trailingPadding = 0.0;
      return;
    }
    final viewportHeight = max(_minimumViewportHeight, itemExtents.reduce(max));
    final leadingPadding = max(0.0, (viewportHeight - itemExtents.first) / 2);
    final trailingPadding = max(0.0, (viewportHeight - itemExtents.last) / 2);
    var offset = leadingPadding;
    final itemCenters = <double>[];
    for (final extent in itemExtents) {
      itemCenters.add(offset + (extent / 2));
      offset += extent;
    }
    _itemExtents = itemExtents;
    _itemCenters = itemCenters;
    _viewportHeight = viewportHeight;
    _leadingPadding = leadingPadding;
    _trailingPadding = trailingPadding;
    _scheduleLayoutAlignment();
  }

  void _scheduleLayoutAlignment() {
    if (_layoutAlignmentScheduled) return;
    _layoutAlignmentScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _layoutAlignmentScheduled = false;
      if (!mounted ||
          _isBrowsing ||
          _isPointerDown ||
          !_scrollController.hasClients) {
        return;
      }
      if (!_windowContains(_focusedIndex) ||
          _itemCenters.length != _windowLength) {
        return;
      }
      final position = _scrollController.position;
      final localIndex = _focusedIndex - _windowStart;
      final targetOffset = (_itemCenters[localIndex] - (_viewportHeight / 2))
          .clamp(position.minScrollExtent, position.maxScrollExtent)
          .toDouble();
      if ((_scrollController.offset - targetOffset).abs() < 0.5) return;
      _isProgrammaticScroll = true;
      try {
        _scrollController.jumpTo(targetOffset);
      } finally {
        _isProgrammaticScroll = false;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.cues.isEmpty) {
      return const SizedBox.shrink();
    }
    final cs = Theme.of(context).colorScheme;
    final baseTextStyle =
        Theme.of(context).textTheme.bodyMedium ?? const TextStyle();
    final focusedTextStyle = baseTextStyle.copyWith(
      color: sessionDetailForeground(
        cs,
        SessionDetailForegroundLevel.medium,
        darkFallback: cs.onSurface.withValues(alpha: 0.85),
      ),
      fontWeight: FontWeight.w600,
      fontSize: 16,
      height: 1.3,
    );
    final unfocusedTextStyle = focusedTextStyle.copyWith(
      color: sessionDetailForeground(
        cs,
        SessionDetailForegroundLevel.muted,
        darkFallback: cs.onSurface.withValues(alpha: 0.72),
      ),
      fontWeight: FontWeight.w500,
      fontSize: 14,
    );
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    return LayoutBuilder(
      builder: (context, constraints) {
        final textWidth = max(
          0.0,
          constraints.maxWidth - (_textHorizontalPadding * 2),
        );
        final textScaler = MediaQuery.textScalerOf(context);
        final textDirection = Directionality.of(context);
        final layoutSignature = (
          widget.cues,
          _windowStart,
          _windowEnd,
          textWidth,
          textScaler,
          textDirection,
          focusedTextStyle,
        );
        if (_layoutSignature != layoutSignature) {
          final previous = _layoutSignature;
          final canReuse =
              previous != null &&
              identical(previous.$1, widget.cues) &&
              previous.$4 == textWidth &&
              previous.$5 == textScaler &&
              previous.$6 == textDirection &&
              previous.$7 == focusedTextStyle;
          _layoutSignature = layoutSignature;
          final itemExtents = <double>[
            for (var index = _windowStart; index < _windowEnd; index++)
              if (canReuse && index >= previous.$2 && index < previous.$3)
                _itemExtents[index - previous.$2]
              else
                _measureCueExtent(
                  widget.cues[index],
                  textWidth: textWidth,
                  textStyle: focusedTextStyle,
                  textDirection: textDirection,
                  textScaler: textScaler,
                ),
          ];
          _updateLayoutMetrics(itemExtents);
        }
        return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: SizedBox(
            key: const ValueKey('subtitle_timeline_viewport'),
            width: double.infinity,
            height: _viewportHeight,
            child: ClipRect(
              child: Listener(
                onPointerDown: _handlePointerDown,
                onPointerUp: _handlePointerReleased,
                onPointerCancel: _handlePointerReleased,
                child: Stack(
                  children: [
                    NotificationListener<ScrollNotification>(
                      onNotification: _handleScrollNotification,
                      child: ListView.builder(
                        key: const ValueKey('subtitle_timeline_list'),
                        controller: _scrollController,
                        padding: EdgeInsets.only(
                          top: _leadingPadding,
                          bottom: _trailingPadding,
                        ),
                        itemExtentBuilder: (index, _) => _itemExtents[index],
                        itemCount: _windowLength,
                        itemBuilder: (context, localIndex) {
                          final index = _windowStart + localIndex;
                          final cue = widget.cues[index];
                          final isFocused = index == _focusedIndex;
                          final isPlaybackSubtitle =
                              index == widget.playbackSubtitleIndex;
                          return Semantics(
                            selected: isFocused,
                            child: Opacity(
                              opacity: isFocused ? 1 : 0.45,
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 120),
                                curve: Curves.easeOutCubic,
                                decoration: BoxDecoration(
                                  color: isFocused
                                      ? cs.primary.withValues(alpha: 0.08)
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: Stack(
                                  key: ValueKey('subtitle_timeline_cue_$index'),
                                  fit: StackFit.expand,
                                  children: [
                                    Padding(
                                      key: ValueKey(
                                        'subtitle_timeline_text_padding_$index',
                                      ),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: _textHorizontalPadding,
                                        vertical: _textVerticalPadding,
                                      ),
                                      child: Center(
                                        child: AnimatedScale(
                                          scale: isFocused ? 1.03 : 1,
                                          duration: const Duration(milliseconds: 120),
                                          curve: Curves.easeOutCubic,
                                          child: SizedBox(
                                            width: double.infinity,
                                            child: Text(
                                              cue.text,
                                              key: ValueKey(
                                                'subtitle_timeline_text_$index',
                                              ),
                                              textAlign: TextAlign.center,
                                              style: isFocused
                                                  ? focusedTextStyle
                                                  : unfocusedTextStyle,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    if (_isBrowsing && isFocused && !isPlaybackSubtitle)
                                      Align(
                                        alignment: Alignment.centerRight,
                                        child: SizedBox(
                                          width: 48,
                                          height: 48,
                                          child: IconButton(
                                            key: const ValueKey(
                                              'subtitle_timeline_seek_button',
                                            ),
                                            tooltip: i18n.tr('seek_to_subtitle'),
                                            onPressed: _seekToFocusedSubtitle,
                                            icon: Icon(
                                              Icons.play_arrow_rounded,
                                              color: sessionDetailForeground(
                                                cs,
                                                SessionDetailForegroundLevel.medium,
                                              ),
                                            ),
                                          ),
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
                    if (defaultTargetPlatform == TargetPlatform.windows)
                      Positioned.fill(
                        child: Listener(
                          behavior: HitTestBehavior.translucent,
                          onPointerSignal: _handlePointerSignal,
                        ),
                      ),
                  ],
                ),
              ),
          ),
        ),
      );
      },
    );
  }
}
