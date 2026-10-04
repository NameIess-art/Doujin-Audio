import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/state/app_runtime_providers.dart';
import '../../../../core/media/subtitle_parser.dart';
import '../../../../core/media/time_text_formatters.dart';
import '../../../../core/widgets/app_feedback.dart';
import 'playlist_shared_helpers.dart';

class _DashedLinePainter extends CustomPainter {
  const _DashedLinePainter({required this.color});

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

class TimelineSubtitleView extends StatefulWidget {
  const TimelineSubtitleView({
    super.key,
    required this.cues,
    required this.playbackSubtitleIndex,
    required this.onSeek,
  });

  final List<SubtitleCue> cues;
  final int playbackSubtitleIndex;
  final Future<void> Function(Duration position) onSeek;

  @override
  State<TimelineSubtitleView> createState() => _TimelineSubtitleViewState();
}

class _TimelineSubtitleViewState extends State<TimelineSubtitleView> {
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
  void didUpdateWidget(covariant TimelineSubtitleView oldWidget) {
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
    _extendWindowNearFocusedIndex();
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
    _extendWindowNearFocusedIndex();
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
    final threshold =
        (_viewportHeight / (2 * _minimumItemExtent)).ceil() +
        _windowExpansionThreshold;
    var nextStart = _windowStart;
    var nextEnd = _windowEnd;
    if (_focusedIndex - _windowStart <= threshold) {
      nextStart = max(0, _windowStart - _windowExpansionSize);
    }
    if ((_windowEnd - 1) - _focusedIndex <= threshold) {
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

  void _updateLayoutMetrics(
    List<double> itemExtents, {
    double? availableHeight,
  }) {
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
    final contentMinHeight = max(
      _minimumViewportHeight,
      itemExtents.reduce(max),
    );
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
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
          final previousCenter =
              canReuse &&
                  _focusedIndex >= previous.$2 &&
                  _focusedIndex < previous.$3
              ? _itemCenters[_focusedIndex - previous.$2]
              : null;
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
          if (previousCenter != null &&
              previous!.$2 != _windowStart &&
              _scrollController.hasClients) {
            // Prepending measured cues must not move the subtitle under the
            // user's finger or interrupt an in-progress scroll activity.
            final shift =
                _itemCenters[_focusedIndex - _windowStart] - previousCenter;
            final position = _scrollController.position;
            position.correctPixels(position.pixels + shift);
          }
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
                      child: ScrollConfiguration(
                        behavior: ScrollConfiguration.of(
                          context,
                        ).copyWith(scrollbars: false),
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
                                        duration:
                                            MediaQuery.disableAnimationsOf(
                                              context,
                                            )
                                            ? Duration.zero
                                            : const Duration(milliseconds: 120),
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
                    ),
                    if (_isBrowsing &&
                        widget.cues.isNotEmpty &&
                        _focusedIndex >= 0 &&
                        _focusedIndex < widget.cues.length)
                      Positioned(
                        left: 12,
                        right: 6,
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
                              child: Container(
                                height: 24,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: isDark
                                      ? cs.surfaceContainerHighest.withValues(
                                          alpha: 0.85,
                                        )
                                      : cs.surfaceContainerHighest.withValues(
                                          alpha: 0.90,
                                        ),
                                  borderRadius: BorderRadius.circular(999),
                                  border: Border.all(
                                    color: cs.primary.withValues(alpha: 0.35),
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withValues(
                                        alpha: isDark ? 0.3 : 0.08,
                                      ),
                                      blurRadius: 4,
                                      offset: const Offset(0, 1),
                                    ),
                                  ],
                                ),
                                child: Text(
                                  formatDurationCompact(
                                    widget.cues[_focusedIndex].start,
                                  ),
                                  style: Theme.of(context).textTheme.labelSmall
                                      ?.copyWith(
                                        color: cs.primary,
                                        fontWeight: FontWeight.w700,
                                        fontSize: 11,
                                        fontFeatures: const [
                                          FontFeature.tabularFigures(),
                                        ],
                                      ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Container(
                              width: 38,
                              height: 38,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: cs.primary,
                                boxShadow: [
                                  BoxShadow(
                                    color: cs.primary.withValues(alpha: 0.40),
                                    blurRadius: 8,
                                    offset: const Offset(0, 2),
                                  ),
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.14),
                                    blurRadius: 4,
                                    offset: const Offset(0, 1),
                                  ),
                                ],
                              ),
                              child: Material(
                                type: MaterialType.transparency,
                                shape: const CircleBorder(),
                                clipBehavior: Clip.antiAlias,
                                child: IconButton(
                                  key: const ValueKey(
                                    'subtitle_timeline_seek_button',
                                  ),
                                  padding: EdgeInsets.zero,
                                  tooltip: i18n.tr('seek_to_subtitle'),
                                  onPressed: _seekToFocusedSubtitle,
                                  icon: Icon(
                                    Icons.play_arrow_rounded,
                                    color: cs.onPrimary,
                                    size: 24,
                                  ),
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
