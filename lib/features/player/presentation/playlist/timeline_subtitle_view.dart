import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/state/app_runtime_providers.dart';
import '../../../../core/media/subtitle_parser.dart';
import '../../../../core/media/time_text_formatters.dart';
import '../../../../core/widgets/app_feedback.dart';
import '../../../../core/widgets/app_transitions.dart';
import '../../../../core/widgets/scroll_to_top_list.dart';
import '../../../../core/widgets/windows_smooth_scroll_controller.dart';
import 'playlist_shared_helpers.dart';

class _DashedLinePainter extends CustomPainter {
  const _DashedLinePainter({required this.color, this.fadeOutRight = false});

  static const double _dashWidth = 4.0;
  static const double _dashSpace = 4.0;
  static const double _strokeWidth = 1.0;

  final Color color;
  final bool fadeOutRight;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0) return;
    final paint = Paint()
      ..shader = ui.Gradient.linear(
        Offset.zero,
        Offset(size.width, 0),
        fadeOutRight
            ? <Color>[color, color.withValues(alpha: 0)]
            : <Color>[color.withValues(alpha: 0), color],
      )
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
    return oldDelegate.color != color ||
        oldDelegate.fadeOutRight != fadeOutRight;
  }
}

class TimelineSubtitleView extends StatefulWidget {
  const TimelineSubtitleView({
    super.key,
    required this.cues,
    required this.playbackSubtitleIndex,
    required this.onSeek,
    this.isLandscape = false,
  });

  final List<SubtitleCue> cues;
  final int playbackSubtitleIndex;
  final Future<void> Function(Duration position) onSeek;
  final bool isLandscape;

  @override
  State<TimelineSubtitleView> createState() => _TimelineSubtitleViewState();
}

class _TimelineSubtitleViewState extends State<TimelineSubtitleView> {
  @visibleForTesting
  int debugMeasuredCueCount = 0;
  @visibleForTesting
  int get debugFocusedIndex => _focusedIndex;
  static const int _initialWindowRadius = 30;
  static const int _windowExpansionSize = 12;
  static const int _windowExpansionThreshold = 4;
  static const double _minimumItemExtent = 48;
  static const double _minimumViewportHeight = _minimumItemExtent * 2;
  static const double _textHorizontalPadding = 20;
  static const double _textVerticalPadding = 6;
  static const Duration _returnDelay = Duration(seconds: 3);
  static const Duration _focusHapticInterval = Duration(milliseconds: 110);

  late final WindowsSmoothScrollController _scrollController;
  late final ValueNotifier<int> _focusedIndexNotifier;
  int get _focusedIndex => _focusedIndexNotifier.value;
  set _focusedIndex(int value) => _focusedIndexNotifier.value = value;
  int _windowStart = 0;
  int _windowEnd = 0;
  List<double> _itemExtents = const <double>[];
  List<double> _itemCenters = const <double>[];
  List<double> _itemOffsets = const <double>[];
  double _viewportHeight = _minimumViewportHeight;
  double _leadingPadding = _minimumItemExtent / 2;
  double _trailingPadding = _minimumItemExtent / 2;
  (Object, int, int, double, double?, TextScaler, TextDirection, TextStyle)?
  _layoutSignature;
  Timer? _returnTimer;
  bool _isBrowsing = false;
  bool _isSnapping = false;
  bool _isProgrammaticScroll = false;
  int _scrollAnimationGen = 0;
  bool _isPointerDown = false;
  bool _snapScheduled = false;
  bool _layoutAlignmentScheduled = false;
  int? _wheelTargetIndex;
  Rect? _cachedEdgeFadeBounds;
  bool? _cachedEdgeFadeTop;
  ui.Shader? _cachedEdgeFadeShader;

  int get _lastIndex => max(0, widget.cues.length - 1);
  int get _windowLength => _windowEnd - _windowStart;
  bool get _hasCurrentWindowLayout =>
      _layoutSignature?.$2 == _windowStart &&
      _layoutSignature?.$3 == _windowEnd;

  @override
  void initState() {
    super.initState();
    _focusedIndexNotifier = ValueNotifier<int>(
      widget.cues.isEmpty
          ? 0
          : widget.playbackSubtitleIndex.clamp(0, _lastIndex),
    );
    _resetWindowAround(_focusedIndex);
    _scrollController = WindowsSmoothScrollController()
      ..addListener(_handleScrollOffsetChanged);
  }

  @override
  void didUpdateWidget(covariant TimelineSubtitleView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.cues.isEmpty) {
      _returnTimer?.cancel();
      _returnTimer = null;
      _isBrowsing = false;
      _wheelTargetIndex = null;
      _focusedIndex = 0;
      _resetWindowAround(0);
      return;
    }
    final playbackIndex = widget.playbackSubtitleIndex.clamp(0, _lastIndex);
    if (!identical(oldWidget.cues, widget.cues)) {
      if (_scrollController.isWheelScrolling) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _wheelTargetIndex == null && widget.cues.isNotEmpty) {
            _scrollToIndex(_focusedIndex, animate: false);
          }
        });
      }
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
      _focusedIndex = playbackIndex;
      final windowReset = !_windowContains(playbackIndex);
      if (windowReset) {
        _resetWindowAround(playbackIndex);
      }
      _extendWindowNearFocusedIndex(inBuildOrUpdate: true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            !_isBrowsing &&
            !_isPointerDown &&
            widget.cues.isNotEmpty) {
          _scrollToIndex(playbackIndex, animate: !windowReset);
        }
      });
    }
  }

  @override
  void dispose() {
    _scrollAnimationGen++;
    _returnTimer?.cancel();
    _cachedEdgeFadeShader = null;
    _cachedEdgeFadeBounds = null;
    _cachedEdgeFadeTop = null;
    _focusedIndexNotifier.dispose();
    _scrollController
      ..removeListener(_handleScrollOffsetChanged)
      ..dispose();
    super.dispose();
  }

  void _handlePointerDown(PointerDownEvent event) {
    _isPointerDown = true;
    _wheelTargetIndex = null;
    _scrollAnimationGen++;
    _isProgrammaticScroll = false;
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
    _browseToIndex(nextIndex, fromWheel: true);
  }

  void _browseToIndex(int index, {bool fromWheel = false}) {
    if (widget.cues.isEmpty) return;
    _returnTimer?.cancel();
    if (!_isBrowsing) {
      AppInteractionFeedback.resetContinuous();
      setState(() => _isBrowsing = true);
    }
    _scrollToIndex(index, fromWheel: fromWheel);

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
        _isProgrammaticScroll ||
        _scrollController.isWheelScrolling ||
        _itemCenters.isEmpty ||
        !_hasCurrentWindowLayout) {
      return;
    }
    final viewportCenter = _scrollController.offset + (_viewportHeight / 2);
    final nextIndex = _windowStart + _nearestWindowItemIndex(viewportCenter);
    if (nextIndex == _focusedIndex || !mounted) return;
    _wheelTargetIndex = null;
    _focusedIndex = nextIndex;
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
    if (_isProgrammaticScroll || _scrollController.isWheelScrolling) {
      return false;
    }
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
    if (_isSnapping || !mounted || widget.cues.isEmpty) return;
    _isSnapping = true;
    try {
      _scrollToIndex(_focusedIndex);
    } finally {
      _isSnapping = false;
    }
    if (!mounted || !_isBrowsing || widget.cues.isEmpty) return;
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
    if (!mounted || widget.cues.isEmpty) return;
    final playbackIndex = widget.playbackSubtitleIndex.clamp(0, _lastIndex);
    setState(() => _isBrowsing = false);
    _scrollToIndex(playbackIndex);
  }

  void _scrollToIndex(
    int index, {
    bool fromWheel = false,
    bool animate = true,
  }) {
    if (widget.cues.isEmpty) return;
    final targetIndex = index.clamp(0, _lastIndex);
    final windowReset = !_windowContains(targetIndex);
    if (_focusedIndex != targetIndex) {
      _focusedIndex = targetIndex;
    }
    if (windowReset) {
      setState(() {
        _resetWindowAround(targetIndex);
      });
    }
    _extendWindowNearFocusedIndex();
    if (!_scrollController.hasClients ||
        _itemCenters.isEmpty ||
        !_hasCurrentWindowLayout) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            widget.cues.isNotEmpty &&
            (!fromWheel || _wheelTargetIndex == targetIndex)) {
          _scrollToIndex(
            targetIndex,
            fromWheel: fromWheel,
            animate: animate && !windowReset,
          );
        }
      });
      return;
    }
    final position = _scrollController.position;
    final localIndex = targetIndex - _windowStart;
    final targetOffset = (_itemCenters[localIndex] - (_viewportHeight / 2))
        .clamp(position.minScrollExtent, position.maxScrollExtent)
        .toDouble();
    final gen = ++_scrollAnimationGen;
    if (fromWheel) {
      _isProgrammaticScroll = true;
      try {
        _scrollController.scrollWheelTo(targetOffset);
      } finally {
        if (_scrollAnimationGen == gen) {
          _isProgrammaticScroll = false;
        }
      }
      return;
    }
    final delta = (_scrollController.offset - targetOffset).abs();
    if (!_scrollController.isWheelScrolling && delta < 0.05) {
      _isProgrammaticScroll = false;
      return;
    }
    final shouldAnimate =
        animate &&
        !windowReset &&
        delta >= 0.5 &&
        !MediaQuery.disableAnimationsOf(context) &&
        TickerMode.valuesOf(context).enabled;
    if (!shouldAnimate) {
      _isProgrammaticScroll = true;
      try {
        _scrollController.jumpTo(targetOffset);
      } finally {
        if (_scrollAnimationGen == gen) {
          _isProgrammaticScroll = false;
        }
      }
      return;
    }
    _isProgrammaticScroll = true;
    final adaptiveMs = (210 + delta / 3.2).round().clamp(210, 320);
    unawaited(
      _scrollController
          .animateTo(
            targetOffset,
            duration: Duration(milliseconds: adaptiveMs),
            curve: kAppSpringCurve,
          )
          .whenComplete(() {
            if (_scrollAnimationGen == gen) {
              _isProgrammaticScroll = false;
            }
          }),
    );
  }

  void _seekToFocusedSubtitle() {
    _wheelTargetIndex = null;
    _returnTimer?.cancel();
    if (_isBrowsing) {
      setState(() => _isBrowsing = false);
    }
    if (widget.cues.isEmpty ||
        _focusedIndex < 0 ||
        _focusedIndex >= widget.cues.length) {
      return;
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
    if (widget.cues.isEmpty) {
      _windowStart = 0;
      _windowEnd = 0;
      _invalidateLayoutMetrics();
      return;
    }
    final targetIndex = index.clamp(0, _lastIndex);
    _windowStart = max(0, targetIndex - _initialWindowRadius);
    _windowEnd = min(
      widget.cues.length,
      targetIndex + _initialWindowRadius + 1,
    );
    _invalidateLayoutMetrics();
  }

  void _extendWindowNearFocusedIndex({bool inBuildOrUpdate = false}) {
    if (widget.cues.isEmpty) return;
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
    if (inBuildOrUpdate) {
      _windowStart = nextStart;
      _windowEnd = nextEnd;
      return;
    }
    setState(() {
      _windowStart = nextStart;
      _windowEnd = nextEnd;
    });
  }

  void _invalidateLayoutMetrics() {
    _layoutSignature = null;
    _itemExtents = const <double>[];
    _itemCenters = const <double>[];
    _itemOffsets = const <double>[];
  }

  static TextStyle _layoutMetricsStyle(TextStyle style) => TextStyle(
    fontFamily: style.fontFamily,
    fontFamilyFallback: style.fontFamilyFallback,
    fontSize: style.fontSize,
    fontWeight: style.fontWeight,
    fontStyle: style.fontStyle,
    letterSpacing: style.letterSpacing,
    wordSpacing: style.wordSpacing,
    textBaseline: style.textBaseline,
    height: style.height,
    leadingDistribution: style.leadingDistribution,
    locale: style.locale,
    fontFeatures: style.fontFeatures,
    fontVariations: style.fontVariations,
    overflow: style.overflow,
  );

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
    );
    try {
      painter.layout(maxWidth: textWidth);
      return max(
        _minimumItemExtent,
        (painter.height * 1.03) + (_textVerticalPadding * 2),
      );
    } finally {
      painter.dispose();
    }
  }

  void _updateLayoutMetrics(
    List<double> itemExtents, {
    double? availableHeight,
  }) {
    if (itemExtents.isEmpty) {
      _itemExtents = const [];
      _itemCenters = const [];
      _itemOffsets = const [];
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
    var offset = 0.0;
    final itemCenters = <double>[];
    final itemOffsets = <double>[offset];
    for (final extent in itemExtents) {
      itemCenters.add(leadingPadding + offset + (extent / 2));
      offset += extent;
      itemOffsets.add(offset);
    }
    _itemExtents = itemExtents;
    _itemCenters = itemCenters;
    _itemOffsets = itemOffsets;
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
          _isProgrammaticScroll ||
          _scrollController.isWheelScrolling ||
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

  ui.Shader _edgeFadeShaderTopAndBottom(Rect bounds) =>
      _resolveEdgeFadeShader(bounds, fadeTop: true);

  ui.Shader _edgeFadeShaderBottomOnly(Rect bounds) =>
      _resolveEdgeFadeShader(bounds, fadeTop: false);

  ui.Shader _resolveEdgeFadeShader(Rect bounds, {required bool fadeTop}) {
    final cached = _cachedEdgeFadeShader;
    if (cached != null &&
        _cachedEdgeFadeBounds == bounds &&
        _cachedEdgeFadeTop == fadeTop) {
      return cached;
    }
    final fadeFraction = bounds.height > 0 ? min(0.25, 32 / bounds.height) : 0.0;
    final shader = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        if (fadeTop) Colors.transparent,
        Colors.black,
        Colors.black,
        Colors.transparent,
      ],
      stops: [0, if (fadeTop) fadeFraction, 1 - fadeFraction, 1],
    ).createShader(bounds);
    _cachedEdgeFadeBounds = bounds;
    _cachedEdgeFadeTop = fadeTop;
    _cachedEdgeFadeShader = shader;
    return shader;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fadeTop =
        defaultTargetPlatform == TargetPlatform.windows ||
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final textLeftInset = widget.isLandscape
        ? landscapeDetailTextInset
        : _textHorizontalPadding;
    final baseTextStyle =
        Theme.of(context).textTheme.bodyMedium ?? const TextStyle();
    final focusedTextStyle = baseTextStyle.copyWith(
      color: cs.primary,
      fontWeight: FontWeight.w700,
      fontSize: 16,
      height: 1.3,
    );
    final unfocusedColor = isDark
        ? cs.onSurface.withValues(alpha: 0.46)
        : Color.alphaBlend(
            cs.primary.withValues(alpha: 0.04),
            cs.onSurfaceVariant,
          ).withValues(alpha: 0.50);
    final unfocusedTextStyle = focusedTextStyle.copyWith(
      color: unfocusedColor,
      fontWeight: FontWeight.w500,
      fontSize: 14,
    );
    final emptyTextStyle = unfocusedTextStyle.copyWith(
      color: sessionDetailForeground(
        cs,
        SessionDetailForegroundLevel.medium,
      ),
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
          style: emptyTextStyle,
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final textWidth = max(
          0.0,
          constraints.maxWidth - textLeftInset - _textHorizontalPadding,
        );
        final availableHeight = constraints.maxHeight.isFinite
            ? max(0.0, constraints.maxHeight)
            : null;
        final textScaler = MediaQuery.textScalerOf(context);
        final textDirection = Directionality.of(context);
        // Strip color/paint-only properties so theme color transitions reuse
        // cached cue heights without re-running TextPainter layout every frame.
        final metricsStyle = _layoutMetricsStyle(focusedTextStyle);
        final layoutSignature = (
          widget.cues,
          _windowStart,
          _windowEnd,
          textWidth,
          availableHeight,
          textScaler,
          textDirection,
          metricsStyle,
        );
        if (_layoutSignature != layoutSignature) {
          final previous = _layoutSignature;
          final canReuse =
              previous != null &&
              identical(previous.$1, widget.cues) &&
              previous.$4 == textWidth &&
              previous.$6 == textScaler &&
              previous.$7 == textDirection &&
              previous.$8 == metricsStyle;
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
                  textStyle: metricsStyle,
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
        return SizedBox(
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
                  ShaderMask(
                    key: const ValueKey('subtitle_timeline_edge_fade'),
                    blendMode: BlendMode.dstIn,
                    shaderCallback: fadeTop
                        ? _edgeFadeShaderTopAndBottom
                        : _edgeFadeShaderBottomOnly,
                    child: NotificationListener<ScrollNotification>(
                      onNotification: _handleScrollNotification,
                      child: ScrollConfiguration(
                        behavior: ScrollConfiguration.of(
                          context,
                        ).copyWith(scrollbars: false),
                        child: RepaintBoundary(
                          child: ScrollToTopListView.builder(
                            key: const ValueKey('subtitle_timeline_list'),
                            controller: _scrollController,
                            padding: EdgeInsets.only(
                              top: _leadingPadding,
                              bottom: _trailingPadding,
                            ),
                            itemExtentBuilder: (index, _) =>
                                _itemExtents[index],
                            rowOffsets: _itemOffsets,
                            itemCount: _windowLength,
                            findChildIndexCallback: (key) {
                              if (key is! ValueKey<int>) return null;
                              final local = key.value - _windowStart;
                              return local >= 0 && local < _windowLength
                                  ? local
                                  : null;
                            },
                            itemBuilder: (context, localIndex) {
                              final index = _windowStart + localIndex;
                              final cue = widget.cues[index];
                              return _TimelineSubtitleRow(
                                key: ValueKey<int>(index),
                                index: index,
                                text: cue.text,
                                focusedIndexNotifier: _focusedIndexNotifier,
                                isBrowsing: _isBrowsing,
                                isLandscape: widget.isLandscape,
                                textLeftInset: textLeftInset,
                                textHorizontalPadding: _textHorizontalPadding,
                                textVerticalPadding: _textVerticalPadding,
                                focusedTextStyle: focusedTextStyle,
                                unfocusedTextStyle: unfocusedTextStyle,
                                onSeekFocused: _seekToFocusedSubtitle,
                                onBrowseToIndex: _browseToIndex,
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (_isBrowsing && widget.cues.isNotEmpty)
                    ValueListenableBuilder<int>(
                      valueListenable: _focusedIndexNotifier,
                      builder: (context, focusedIndex, _) {
                        if (focusedIndex < 0 ||
                            focusedIndex >= widget.cues.length) {
                          return const SizedBox.shrink();
                        }
                        const seekBarHeight = 44.0;
                        final seekBarTop = max(
                          0.0,
                          (_viewportHeight - seekBarHeight) / 2,
                        );
                        final cueTimeText = formatDurationCompact(
                          widget.cues[focusedIndex].start,
                        );
                        final timeTextStyle = Theme.of(context)
                            .textTheme
                            .labelSmall
                            ?.copyWith(
                              color: cs.primary,
                              fontWeight: FontWeight.w700,
                              fontSize: 11,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            );
                        final pillDecoration = BoxDecoration(
                          color: isDark
                              ? cs.surfaceContainerHighest.withValues(
                                  alpha: 0.92,
                                )
                              : cs.surfaceContainerHighest.withValues(
                                  alpha: 0.96,
                                ),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: cs.primary.withValues(
                              alpha: isDark ? 0.35 : 0.25,
                            ),
                            width: 0.8,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: cs.shadow.withValues(
                                alpha: isDark ? 0.35 : 0.08,
                              ),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        );
                        return Positioned(
                          left: widget.isLandscape ? 12 : 6,
                          right: widget.isLandscape ? 48 : 4,
                          top: seekBarTop,
                          height: seekBarHeight,
                          child: TweenAnimationBuilder<double>(
                            tween: Tween<double>(begin: 0.0, end: 1.0),
                            duration: MediaQuery.disableAnimationsOf(context)
                                ? Duration.zero
                                : const Duration(milliseconds: 160),
                            curve: Curves.easeOutCubic,
                            builder: (context, opacity, child) =>
                                opacity >= 0.999
                                ? child!
                                : Opacity(opacity: opacity, child: child),
                            child: Row(
                              children: [
                                if (widget.isLandscape)
                                  const Spacer()
                                else ...[
                                  IgnorePointer(
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                        vertical: 3,
                                      ),
                                      decoration: pillDecoration,
                                      child: Text(
                                        cueTimeText,
                                        style: timeTextStyle,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 3),
                                ],
                                SizedBox(
                                  key: const ValueKey(
                                    'subtitle_timeline_seek_dashes',
                                  ),
                                  width: widget.isLandscape ? 36 : 12,
                                  child: IgnorePointer(
                                    child: CustomPaint(
                                      painter: _DashedLinePainter(
                                        color: cs.primary.withValues(
                                          alpha: isDark ? 0.6 : 0.45,
                                        ),
                                        fadeOutRight: !widget.isLandscape,
                                      ),
                                    ),
                                  ),
                                ),
                                if (!widget.isLandscape) const Spacer(),
                                Tooltip(
                                  message: i18n.tr('seek_to_subtitle'),
                                  child: Semantics(
                                    button: true,
                                    label: i18n.tr('seek_to_subtitle'),
                                    child: Material(
                                      color: Colors.transparent,
                                      child: InkWell(
                                        key: const ValueKey(
                                          'subtitle_timeline_seek_button',
                                        ),
                                        borderRadius: BorderRadius.circular(
                                          999,
                                        ),
                                        onTap: _seekToFocusedSubtitle,
                                        child: ConstrainedBox(
                                          constraints: const BoxConstraints(
                                            minWidth: 44,
                                            minHeight: 44,
                                          ),
                                          child: Center(
                                            child: widget.isLandscape
                                                ? Container(
                                                    height: 32,
                                                    padding:
                                                        const EdgeInsets.only(
                                                          left: 10,
                                                          right: 4,
                                                        ),
                                                    decoration: pillDecoration,
                                                    child: Row(
                                                      mainAxisSize:
                                                          MainAxisSize.min,
                                                      children: [
                                                        Text(
                                                          cueTimeText,
                                                          style: timeTextStyle,
                                                        ),
                                                        const SizedBox(
                                                          width: 6,
                                                        ),
                                                        Container(
                                                          width: 24,
                                                          height: 24,
                                                          decoration:
                                                              BoxDecoration(
                                                                shape: BoxShape
                                                                    .circle,
                                                                color:
                                                                    cs.primary,
                                                              ),
                                                          child: Icon(
                                                            Icons
                                                                .play_arrow_rounded,
                                                            color: cs.onPrimary,
                                                            size: 16,
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  )
                                                : Container(
                                                    width: 32,
                                                    height: 32,
                                                    decoration: pillDecoration,
                                                    padding:
                                                        const EdgeInsets.all(3),
                                                    child: DecoratedBox(
                                                      decoration: BoxDecoration(
                                                        shape: BoxShape.circle,
                                                        color: cs.primary,
                                                      ),
                                                      child: Icon(
                                                        Icons
                                                            .play_arrow_rounded,
                                                        color: cs.onPrimary,
                                                        size: 17,
                                                      ),
                                                    ),
                                                  ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
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
        );
      },
    );
  }
}

class _TimelineSubtitleRow extends StatefulWidget {
  const _TimelineSubtitleRow({
    super.key,
    required this.index,
    required this.text,
    required this.focusedIndexNotifier,
    required this.isBrowsing,
    required this.isLandscape,
    required this.textLeftInset,
    required this.textHorizontalPadding,
    required this.textVerticalPadding,
    required this.focusedTextStyle,
    required this.unfocusedTextStyle,
    required this.onSeekFocused,
    required this.onBrowseToIndex,
  });

  final int index;
  final String text;
  final ValueListenable<int> focusedIndexNotifier;
  final bool isBrowsing;
  final bool isLandscape;
  final double textLeftInset;
  final double textHorizontalPadding;
  final double textVerticalPadding;
  final TextStyle focusedTextStyle;
  final TextStyle unfocusedTextStyle;
  final VoidCallback onSeekFocused;
  final ValueChanged<int> onBrowseToIndex;

  @override
  State<_TimelineSubtitleRow> createState() => _TimelineSubtitleRowState();
}

class _TimelineSubtitleRowState extends State<_TimelineSubtitleRow> {
  late bool _isFocused;

  @override
  void initState() {
    super.initState();
    _isFocused = widget.focusedIndexNotifier.value == widget.index;
    widget.focusedIndexNotifier.addListener(_handleFocusChanged);
  }

  @override
  void didUpdateWidget(covariant _TimelineSubtitleRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusedIndexNotifier != widget.focusedIndexNotifier) {
      oldWidget.focusedIndexNotifier.removeListener(_handleFocusChanged);
      widget.focusedIndexNotifier.addListener(_handleFocusChanged);
    }
    _isFocused = widget.focusedIndexNotifier.value == widget.index;
  }

  @override
  void dispose() {
    widget.focusedIndexNotifier.removeListener(_handleFocusChanged);
    super.dispose();
  }

  void _handleFocusChanged() {
    final nextFocused = widget.focusedIndexNotifier.value == widget.index;
    if (nextFocused != _isFocused && mounted) {
      setState(() => _isFocused = nextFocused);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isFocused = _isFocused;
    final canTapToSeek = isFocused && widget.isBrowsing;
    final scaleFocusedCue =
        isFocused && Theme.of(context).platform != TargetPlatform.android;
    return Semantics(
      selected: isFocused,
      button: !isFocused || canTapToSeek,
      child: MouseRegion(
        cursor: (!isFocused || canTapToSeek)
            ? SystemMouseCursors.click
            : MouseCursor.defer,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: isFocused
              ? (canTapToSeek ? widget.onSeekFocused : null)
              : () => widget.onBrowseToIndex(widget.index),
          child: SizedBox(
            key: ValueKey('subtitle_timeline_cue_${widget.index}'),
            child: Padding(
              key: ValueKey('subtitle_timeline_text_padding_${widget.index}'),
              padding: EdgeInsets.fromLTRB(
                widget.textLeftInset,
                widget.textVerticalPadding,
                widget.textHorizontalPadding,
                widget.textVerticalPadding,
              ),
              child: Align(
                alignment: widget.isLandscape
                    ? Alignment.centerLeft
                    : Alignment.center,
                child: AnimatedScale(
                  alignment: widget.isLandscape
                      ? Alignment.centerLeft
                      : Alignment.center,
                  scale: scaleFocusedCue ? 1.03 : 1,
                  duration: MediaQuery.disableAnimationsOf(context)
                      ? Duration.zero
                      : const Duration(milliseconds: 180),
                  curve: kAppSpringCurve,
                  child: Text(
                    widget.text,
                    key: ValueKey('subtitle_timeline_text_${widget.index}'),
                    style: isFocused
                        ? widget.focusedTextStyle
                        : widget.unfocusedTextStyle,
                    textAlign: widget.isLandscape
                        ? TextAlign.left
                        : TextAlign.center,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
