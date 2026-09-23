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
import '../../../../core/media/time_text_formatters.dart';
import '../../../../core/logging/app_log_service.dart';
import '../../../../core/ui/ui_interaction_coordinator.dart';
import '../../../../core/widgets/app_feedback.dart';
import '../../application/playback_session_snapshot.dart';
import '../../application/playback_subtitle_service.dart';
import '../playback_error_text.dart';
import '../playback_position_ui_gate.dart';
import '../playback_providers.dart';
import 'playlist_shared_helpers.dart';

class _DashedLinePainter extends CustomPainter {
  const _DashedLinePainter({
    required this.color,
  });

  static const double _dashWidth = 4.0;
  static const double _dashSpace = 4.0;
  static const double _strokeWidth = 1.0;

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = _strokeWidth
      ..style = PaintingStyle.stroke;
    final y = size.height / 2;
    var startX = 0.0;
    while (startX < size.width) {
      final endX = min(startX + _dashWidth, size.width);
      canvas.drawLine(Offset(startX, y), Offset(endX, y), paint);
      startX += _dashWidth + _dashSpace;
    }
  }

  @override
  bool shouldRepaint(covariant _DashedLinePainter oldDelegate) {
    return oldDelegate.color != color;
  }
}

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
    _subtitleTrack = track;
    _updateSubtitleIndex(_positionGate.value.position);
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
        : AppDesignTokens.of(context).motionStandard;

    late final Widget content;
    final subtitleTrack = _subtitleTrack;
    if (!widget.subtitleEnabled) {
      content = Center(
        key: const ValueKey('subtitle_empty'),
        child: Text(
          i18n.tr('no_subtitle_for_track'),
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: sessionDetailForeground(
              Theme.of(context).colorScheme,
              SessionDetailForegroundLevel.muted,
              darkFallback: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
            ),
            fontSize: 14,
          ),
        ),
      );
    } else if (isLoading) {
      content = Center(
        key: const ValueKey('subtitle_loading'),
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
    } else {
      final playbackSubtitleIndex = _playbackSubtitleIndex;
      if (subtitleTrack != null &&
          subtitleTrack.cues.isNotEmpty &&
          playbackSubtitleIndex != null) {
        content = _TimelineSubtitleView(
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
                darkFallback: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
              ),
              fontSize: 14,
            ),
          ),
        );
      }
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
  (Object, int, int, double, double?, TextScaler, TextDirection, TextStyle)?
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
    if ((_scrollController.offset - targetOffset).abs() < 0.05) return;
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

  void _updateLayoutMetrics(List<double> itemExtents, {double? availableHeight}) {
    if (itemExtents.isEmpty) {
      _itemExtents = const [];
      _itemCenters = const [];
      _viewportHeight = (availableHeight != null && availableHeight.isFinite)
          ? max(0.0, availableHeight)
          : _minimumViewportHeight;
      _leadingPadding = 0.0;
      _trailingPadding = 0.0;
      return;
    }
    final contentMinHeight = max(_minimumViewportHeight, itemExtents.reduce(max));
    final viewportHeight = (availableHeight != null && availableHeight.isFinite)
        ? max(0.0, availableHeight)
        : contentMinHeight;
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
      if ((_scrollController.offset - targetOffset).abs() < 0.05) return;
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
    final cs = Theme.of(context).colorScheme;
    final baseTextStyle =
        Theme.of(context).textTheme.bodyMedium ?? const TextStyle();
    final focusedTextStyle = baseTextStyle.copyWith(
      color: cs.primary,
      fontWeight: FontWeight.w700,
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

    if (widget.cues.isEmpty) {
      return Center(
        key: const ValueKey('subtitle_empty'),
        child: Text(
          i18n.tr('no_subtitle_for_track'),
          style: unfocusedTextStyle,
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final textWidth = max(
          0.0,
          constraints.maxWidth - (_textHorizontalPadding * 2),
        );
        final availableHeight = constraints.maxHeight.isFinite
            ? max(0.0, constraints.maxHeight - 8.0)
            : null;
        final textScaler = MediaQuery.textScalerOf(context);
        final textDirection = Directionality.of(context);
        final layoutSignature = (
          widget.cues,
          _windowStart,
          _windowEnd,
          textWidth,
          availableHeight,
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
              previous.$6 == textScaler &&
              previous.$7 == textDirection &&
              previous.$8 == focusedTextStyle;
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
          _updateLayoutMetrics(itemExtents, availableHeight: availableHeight);
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
                          return Semantics(
                            selected: isFocused,
                            child: Opacity(
                              opacity: isFocused ? 1 : 0.30,
                              child: SizedBox(
                                key: ValueKey('subtitle_timeline_cue_$index'),
                                child: Padding(
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
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    if (_isBrowsing &&
                        widget.cues.isNotEmpty &&
                        _focusedIndex >= 0 &&
                        _focusedIndex < widget.cues.length)
                      Positioned(
                        left: 16,
                        right: 8,
                        top: max(0.0, (_viewportHeight - 44) / 2),
                        height: 44,
                        child: Row(
                          children: [
                            Expanded(
                              child: IgnorePointer(
                                child: CustomPaint(
                                  painter: _DashedLinePainter(
                                    color: cs.primary.withValues(alpha: 0.5),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            IgnorePointer(
                              child: Text(
                                formatDurationCompact(
                                  widget.cues[_focusedIndex].start,
                                ),
                                style: Theme.of(context)
                                    .textTheme
                                    .labelSmall
                                    ?.copyWith(
                                      color: cs.primary,
                                      fontWeight: FontWeight.w700,
                                      fontFeatures: const [
                                        FontFeature.tabularFigures(),
                                      ],
                                    ),
                              ),
                            ),
                            const SizedBox(width: 4),
                            SizedBox(
                              width: 44,
                              height: 44,
                              child: IconButton(
                                key: const ValueKey(
                                  'subtitle_timeline_seek_button',
                                ),
                                tooltip: i18n.tr('seek_to_subtitle'),
                                onPressed: _seekToFocusedSubtitle,
                                icon: Icon(
                                  Icons.play_arrow_rounded,
                                  color: cs.primary,
                                  size: 26,
                                ),
                              ),
                            ),
                          ],
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
