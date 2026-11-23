import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../../../core/media/time_text_formatters.dart';
import '../../../../core/widgets/app_feedback.dart';
import '../../../../core/widgets/app_transitions.dart';
import '../../application/playback_facade.dart';
import '../../application/playback_session_snapshot.dart';
import '../../domain/time_segment_label.dart';
import '../playback_position_ui_gate.dart';
import 'playlist_volume_timer_widgets.dart';
import 'session_detail_theme.dart';

typedef _ProgressSliderValue = ({
  double maxMillis,
  double sliderValue,
  double bufferedValue,
  Duration duration,
  bool hasKnownDuration,
  bool canSeek,
});

typedef _ProgressTimecodeValue = ({int elapsedSeconds, int? durationSeconds});

extension on _ProgressTimecodeValue {
  String get elapsedText =>
      formatDurationCompact(Duration(seconds: elapsedSeconds));

  String get remainingText {
    final duration = durationSeconds;
    return duration == null
        ? '--:--'
        : '-${formatDurationCompact(Duration(seconds: duration - elapsedSeconds))}';
  }

  String get widthText {
    final duration = durationSeconds;
    return duration == null
        ? '00:00:00'
        : formatDurationCompact(Duration(seconds: duration));
  }
}

double _progressTrackWidth(double sliderWidth) =>
    max(1.0, sliderWidth - 2 * sessionDetailProgressTrackInset);

class SessionProgressBar extends StatelessWidget {
  const SessionProgressBar({
    super.key,
    required this.session,
    required this.playback,
    this.inlineTimecodes = false,
    this.timeSegmentLabels = const <TimeSegmentLabel>[],
    this.selectedSegmentId,
    this.onSeekStart,
    this.onSeekCancel,
    this.onManualSeek,
  });

  static final Set<_ProgressSliderFrameState> _mountedFrames =
      <_ProgressSliderFrameState>{};

  static double get seekTargetHeight =>
      defaultTargetPlatform == TargetPlatform.android
      ? kMinInteractiveDimension
      : 20.0;

  static double preferredHeight(
    BuildContext context, {
    bool inlineTimecodes = false,
  }) {
    final timecodeHeight = MediaQuery.textScalerOf(context).scale(13) * 1.1;
    return inlineTimecodes
        ? max(seekTargetHeight, timecodeHeight)
        : seekTargetHeight + max(20.0, timecodeHeight);
  }

  static bool get isInteracting =>
      _mountedFrames.any((frame) => frame._sliderDragging || frame._pointerDown);

  static bool isInProgressOrBottomControlsZone(Offset globalPosition) {
    for (final frame in _mountedFrames) {
      if (!frame.mounted) continue;
      final box =
          frame.widget.sliderKey.currentContext?.findRenderObject()
              as RenderBox?;
      if (box == null || !box.attached || !box.hasSize) continue;
      final topLeft = box.localToGlobal(Offset.zero);
      if (globalPosition.dy >= topLeft.dy - 16) {
        return true;
      }
    }
    return false;
  }

  final PlaybackSessionSnapshot session;
  final PlaybackFacade playback;
  final bool inlineTimecodes;
  final List<TimeSegmentLabel> timeSegmentLabels;
  final String? selectedSegmentId;
  final VoidCallback? onSeekStart;
  final VoidCallback? onSeekCancel;
  final ValueChanged<Duration>? onManualSeek;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final primaryColor = cs.primary;
    final staticLayer = _ProgressBarStaticLayer(
      session: session,
      labels: timeSegmentLabels,
      selectedSegmentId: selectedSegmentId,
      colorScheme: cs,
    );
    return _ProgressSliderAndTimecodes(
      session: session,
      playback: playback,
      primaryColor: primaryColor,
      staticLayer: staticLayer,
      timeSegmentLabels: timeSegmentLabels,
      selectedSegmentId: selectedSegmentId,
      onSeekStart: onSeekStart,
      onSeekCancel: onSeekCancel,
      onManualSeek: onManualSeek,
      inlineTimecodes: inlineTimecodes,
    );
  }
}

class _ProgressSliderAndTimecodes extends StatefulWidget {
  const _ProgressSliderAndTimecodes({
    required this.session,
    required this.playback,
    required this.primaryColor,
    required this.staticLayer,
    required this.timeSegmentLabels,
    required this.selectedSegmentId,
    required this.onSeekStart,
    required this.onSeekCancel,
    required this.onManualSeek,
    required this.inlineTimecodes,
  });

  final PlaybackSessionSnapshot session;
  final PlaybackFacade playback;
  final Color primaryColor;
  final Widget staticLayer;
  final List<TimeSegmentLabel> timeSegmentLabels;
  final String? selectedSegmentId;
  final VoidCallback? onSeekStart;
  final VoidCallback? onSeekCancel;
  final ValueChanged<Duration>? onManualSeek;
  final bool inlineTimecodes;

  @override
  State<_ProgressSliderAndTimecodes> createState() =>
      _ProgressSliderAndTimecodesState();
}

class _ProgressSliderAndTimecodesState
    extends State<_ProgressSliderAndTimecodes> {
  late final PlaybackPositionUiGate _positionGate;
  late final ValueNotifier<_ProgressSliderValue> _sliderValue;
  late final ValueNotifier<_ProgressTimecodeValue> _timecodeValue;
  late final ValueNotifier<_ProgressTooltipState?> _tooltipValue;
  bool _isDragging = false;
  double? _dragValueMs;
  double? _hoverValueMs;
  bool _tickerModeEnabled = true;
  double _devicePixelRatio = 1.0;
  final _sliderKey = GlobalKey();
  final _frameKey = GlobalKey<_ProgressSliderFrameState>();

  @override
  void initState() {
    super.initState();
    _positionGate = PlaybackPositionUiGate(
      session: widget.session,
      minUpdateInterval: const Duration(milliseconds: 16),
      alignToFrame: true,
    )..addListener(_handlePositionTick);
    _sliderValue = ValueNotifier<_ProgressSliderValue>(
      _buildSliderValue(_positionGate.value),
    );
    _timecodeValue = ValueNotifier<_ProgressTimecodeValue>(
      _buildTimecodeValue(_sliderValue.value),
    );
    _tooltipValue = ValueNotifier<_ProgressTooltipState?>(null);
  }

  void _cancelActiveDrag() {
    final wasDragging = _isDragging || _dragValueMs != null;
    _isDragging = false;
    _dragValueMs = null;
    _hoverValueMs = null;
    _clearTooltip();
    _frameKey.currentState?.cancelDrag();
    if (wasDragging) {
      _positionGate.tickerModeEnabled = _tickerModeEnabled;
      widget.onSeekCancel?.call();
    }
  }

  @override
  void didUpdateWidget(covariant _ProgressSliderAndTimecodes oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) {
      final sessionChanged =
          oldWidget.session.id != widget.session.id ||
          oldWidget.session.currentTrackPath != widget.session.currentTrackPath;
      _positionGate.updateSession(widget.session);
      final nextCanSeek = _buildSliderValue(_positionGate.value).canSeek;
      final shouldCancelDrag = sessionChanged || (_isDragging && !nextCanSeek);
      if (shouldCancelDrag) {
        _cancelActiveDrag();
      }
      _publishProgressValue(force: sessionChanged || shouldCancelDrag);
    } else if (oldWidget.timeSegmentLabels != widget.timeSegmentLabels ||
        oldWidget.selectedSegmentId != widget.selectedSegmentId) {
      _clearTooltip();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _devicePixelRatio = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
    final nextTickerMode = TickerMode.valuesOf(context).enabled;
    if (_tickerModeEnabled == nextTickerMode) return;
    _tickerModeEnabled = nextTickerMode;
    if (!_isDragging) {
      _positionGate.tickerModeEnabled = nextTickerMode;
    }
  }

  @override
  void dispose() {
    if (_isDragging || _dragValueMs != null) {
      _isDragging = false;
      _dragValueMs = null;
      final onSeekCancel = widget.onSeekCancel;
      if (onSeekCancel != null) {
        SchedulerBinding.instance.addPostFrameCallback((_) => onSeekCancel());
      }
    }
    _positionGate
      ..removeListener(_handlePositionTick)
      ..dispose();
    _sliderValue.dispose();
    _timecodeValue.dispose();
    _tooltipValue.dispose();
    super.dispose();
  }

  void _handlePositionTick() {
    if (_isDragging) return;
    _publishProgressValue();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: _ProgressSliderFrame(
        key: _frameKey,
        sliderValue: _sliderValue,
        timecodeValue: _timecodeValue,
        tooltipValue: _tooltipValue,
        staticLayer: widget.staticLayer,
        primaryColor: widget.primaryColor,
        onHover: _handleSliderHover,
        onHoverExit: _handleSliderHoverExit,
        onChangeStart: _handleSliderChangeStart,
        onChanged: _handleSliderChanged,
        onChangeEnd: _handleSliderChangeEnd,
        inlineTimecodes: widget.inlineTimecodes,
        sliderKey: _sliderKey,
      ),
    );
  }

  void _publishProgressValue({bool force = false}) {
    final nextSlider = _buildSliderValue(_positionGate.value);
    if (force || _shouldUpdateSliderValue(_sliderValue.value, nextSlider)) {
      _sliderValue.value = nextSlider;
    }
    _timecodeValue.value = _buildTimecodeValue(
      nextSlider,
      overridePositionMs: _isDragging ? null : _hoverValueMs,
    );
  }

  bool _shouldUpdateSliderValue(
    _ProgressSliderValue current,
    _ProgressSliderValue next,
  ) {
    if (_isDragging ||
        current.maxMillis != next.maxMillis ||
        current.bufferedValue != next.bufferedValue ||
        current.duration != next.duration ||
        current.hasKnownDuration != next.hasKnownDuration ||
        current.canSeek != next.canSeek) {
      return current != next;
    }
    if (current.sliderValue == next.sliderValue) return false;
    if (next.sliderValue <= 0 || next.sliderValue >= next.maxMillis) {
      return true;
    }
    final box = _sliderKey.currentContext?.findRenderObject() as RenderBox?;
    final width = box?.hasSize == true ? box!.size.width : 0.0;
    if (width <= 0 || next.maxMillis <= 0) return true;
    final trackWidth = _progressTrackWidth(width);
    final physicalPixelsDelta =
        ((next.sliderValue - current.sliderValue).abs() / next.maxMillis) *
        trackWidth *
        _devicePixelRatio;
    return physicalPixelsDelta >= 0.5;
  }

  _ProgressSliderValue _buildSliderValue(PlaybackPositionUiSnapshot snapshot) {
    final duration = snapshot.duration;
    final bufferedPosition = snapshot.bufferedPosition;
    final hasKnownDuration = duration != null;
    final effectiveDuration = duration ?? Duration.zero;
    var position = snapshot.position;
    if (hasKnownDuration && position > effectiveDuration) {
      position = effectiveDuration;
    }
    final durationMs = hasKnownDuration
        ? max(1, effectiveDuration.inMilliseconds)
        : max(1, max(position.inMilliseconds, bufferedPosition.inMilliseconds));
    final maxMillis = durationMs.toDouble();
    final basePositionMs = position.inMilliseconds
        .clamp(0, durationMs)
        .toDouble();
    final sliderValue =
        (_isDragging ? (_dragValueMs ?? basePositionMs) : basePositionMs).clamp(
          0.0,
          maxMillis,
        );
    final bufferedValue =
        (_isDragging
                ? max(bufferedPosition.inMilliseconds, sliderValue.round())
                : bufferedPosition.inMilliseconds)
            .clamp(0, durationMs)
            .toDouble();
    return (
      maxMillis: maxMillis,
      sliderValue: sliderValue,
      bufferedValue: bufferedValue,
      duration: effectiveDuration,
      hasKnownDuration: hasKnownDuration,
      canSeek: hasKnownDuration && effectiveDuration.inMilliseconds > 0,
    );
  }

  _ProgressTimecodeValue _buildTimecodeValue(
    _ProgressSliderValue value, {
    double? overridePositionMs,
  }) {
    final elapsed = (overridePositionMs ?? value.sliderValue).round() ~/ 1000;
    final duration = value.hasKnownDuration ? value.duration.inSeconds : null;
    return (
      elapsedSeconds: duration == null ? elapsed : elapsed.clamp(0, duration),
      durationSeconds: duration,
    );
  }

  void _handleSliderHover(Offset localPosition) {
    if (_isDragging) return;
    final hoverMs = _sliderValueAt(localPosition);
    if (hoverMs == null) return;
    _hoverValueMs = hoverMs;
    _publishProgressValue();
    _showLabelsAtSliderValue(hoverMs);
  }

  void _handleSliderHoverExit() {
    if (_isDragging) return;
    if (_hoverValueMs == null) return;
    _hoverValueMs = null;
    _clearTooltip();
    _publishProgressValue();
  }

  double? _sliderValueAt(Offset localPosition) {
    final value = _sliderValue.value;
    if (!value.canSeek) return null;
    final box = _sliderKey.currentContext?.findRenderObject() as RenderBox?;
    final width = box?.size.width ?? 0;
    if (width <= 0) return null;
    final fraction =
        (localPosition.dx - sessionDetailProgressTrackInset) /
        _progressTrackWidth(width);
    return value.maxMillis * fraction.clamp(0.0, 1.0);
  }

  void _handleSliderChangeStart(double value) {
    widget.onSeekStart?.call();
    AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection);
    _positionGate.tickerModeEnabled = false;
    _isDragging = true;
    _dragValueMs = value;
    _hoverValueMs = null;
    _publishProgressValue();
    _showLabelsAtSliderValue(value);
  }

  void _handleSliderChanged(double value) {
    _isDragging = true;
    _dragValueMs = value;
    _hoverValueMs = null;
    _publishProgressValue();
    _showLabelsAtSliderValue(value);
  }

  void _handleSliderChangeEnd(double value) {
    AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection);
    final position = Duration(milliseconds: value.round());
    widget.onManualSeek?.call(position);
    widget.playback.seekSession(widget.session.id, position);
    final committedPosition = widget.playback
        .sessionById(widget.session.id)
        ?.position;
    if (committedPosition != null) {
      _positionGate.syncPosition(committedPosition);
    }
    _isDragging = false;
    _dragValueMs = null;
    _hoverValueMs = null;
    _clearTooltip();
    _publishProgressValue(force: true);
    _positionGate.tickerModeEnabled = _tickerModeEnabled;
  }

  void _showLabelsAtSliderValue(double valueMs) {
    final labels = _overlayLabels;
    if (labels.isEmpty) {
      _clearTooltip();
      return;
    }
    final slider = _sliderValue.value;
    final state = _tooltipStateForSliderValue(
      valueMs,
      slider.maxMillis,
      labels,
    );
    _showLabelsAtPosition(state);
  }

  List<TimeSegmentLabel> get _overlayLabels =>
      _sliderValue.value.hasKnownDuration
      ? widget.timeSegmentLabels
      : const <TimeSegmentLabel>[];

  _ProgressTooltipState? _tooltipStateForSliderValue(
    double valueMs,
    double maxMillis,
    List<TimeSegmentLabel> labels,
  ) {
    if (labels.isEmpty) return null;
    final box = _sliderKey.currentContext?.findRenderObject() as RenderBox?;
    final width = box?.size.width ?? 0;
    if (width <= 0) return null;
    final trackWidth = _progressTrackWidth(width);
    final ratio = (valueMs / maxMillis).clamp(0.0, 1.0);
    final dx = sessionDetailProgressTrackInset + trackWidth * ratio;
    final position = Duration(milliseconds: valueMs.round());
    return _tooltipStateForPosition(position, dx, width, labels);
  }

  void _showLabelsAtPosition(_ProgressTooltipState? state) {
    final previous = _tooltipValue.value;
    if (previous == state) return;
    if (_isDragging && !listEquals(previous?.labels, state?.labels)) {
      AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection);
    }
    _tooltipValue.value = state;
  }

  _ProgressTooltipState? _tooltipStateForPosition(
    Duration position,
    double dx,
    double width,
    List<TimeSegmentLabel> labels,
  ) {
    if (labels.isEmpty) return null;
    final hits = labels
        .where((label) => label.contains(position))
        .toList(growable: false);
    if (hits.isEmpty) return null;
    return _ProgressTooltipState(
      labels: hits,
      dx: dx,
      left: (dx - 96).clamp(0.0, max(0.0, width - 192)),
    );
  }

  void _clearTooltip() {
    if (_tooltipValue.value == null) return;
    _tooltipValue.value = null;
  }
}

class _ProgressSliderFrame extends StatefulWidget {
  const _ProgressSliderFrame({
    super.key,
    required this.sliderValue,
    required this.timecodeValue,
    required this.tooltipValue,
    required this.staticLayer,
    required this.primaryColor,
    required this.onHover,
    required this.onHoverExit,
    required this.onChangeStart,
    required this.onChanged,
    required this.onChangeEnd,
    required this.inlineTimecodes,
    required this.sliderKey,
  });

  final ValueListenable<_ProgressSliderValue> sliderValue;
  final ValueListenable<_ProgressTimecodeValue> timecodeValue;
  final ValueListenable<_ProgressTooltipState?> tooltipValue;
  final Widget staticLayer;
  final Color primaryColor;
  final ValueChanged<Offset> onHover;
  final VoidCallback onHoverExit;
  final ValueChanged<double> onChangeStart;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;
  final bool inlineTimecodes;
  final GlobalKey sliderKey;

  @override
  State<_ProgressSliderFrame> createState() => _ProgressSliderFrameState();
}

class _ProgressSliderFrameState extends State<_ProgressSliderFrame>
    with SingleTickerProviderStateMixin {
  final OverlayPortalController _tooltipPortalController =
      OverlayPortalController();
  final LayerLink _layerLink = LayerLink();
  late final AnimationController _tooltipAnimation;
  late final CurvedAnimation _tooltipOpacity;
  _ProgressTooltipState? _lastTooltip;
  bool _tooltipVisible = false;
  bool _disableAnimations = false;
  bool _sliderHovered = false;
  bool _sliderDragging = false;
  bool _pointerDown = false;
  double _scrubScale = 1.0;
  bool _usedFineScrub = false;
  double? _lastPointerLocalX;
  double? _fineValueMs;

  void _setSliderHovered(bool hovered) {
    if (_sliderHovered == hovered) return;
    setState(() => _sliderHovered = hovered);
  }

  void _setSliderDragging(bool dragging) {
    if (_sliderDragging == dragging) return;
    setState(() => _sliderDragging = dragging);
  }

  void cancelDrag() {
    final wasDragging = _sliderDragging;
    _resetFineScrub();
    _pointerDown = false;
    if (wasDragging && mounted) {
      _setSliderDragging(false);
    } else {
      _sliderDragging = false;
    }
  }

  double? _currentTrackWidth() {
    final box =
        widget.sliderKey.currentContext?.findRenderObject() as RenderBox?;
    final width = box?.size.width ?? 0;
    if (width <= 0) return null;
    return _progressTrackWidth(width);
  }

  double _scrubScaleForOffset(Offset localPosition) {
    final verticalDistance =
        (localPosition.dy - SessionProgressBar.seekTargetHeight / 2).abs();
    if (verticalDistance >= 96.0) return 0.25;
    if (verticalDistance >= 48.0) return 0.5;
    return 1.0;
  }

  void _handlePointerMoveScrub(PointerMoveEvent event) {
    final localPosition = event.localPosition;
    final prevX = _lastPointerLocalX;
    _lastPointerLocalX = localPosition.dx;
    if (!_sliderDragging) {
      _scrubScale = _scrubScaleForOffset(localPosition);
      return;
    }
    final nextScale = _scrubScaleForOffset(localPosition);
    if (nextScale != _scrubScale) {
      setState(() {
        _scrubScale = nextScale;
        if (nextScale < 1.0) {
          _usedFineScrub = true;
        }
      });
      AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection);
    }
    if (!_usedFineScrub) return;
    final value = widget.sliderValue.value;
    if (!value.canSeek || value.maxMillis <= 0) return;
    final trackWidth = _currentTrackWidth();
    if (trackWidth == null || trackWidth <= 0) return;
    final dx = prevX == null ? event.delta.dx : (localPosition.dx - prevX);
    if (dx == 0) return;
    final currentMs = _fineValueMs ?? value.sliderValue;
    final rawDeltaMs = (dx / trackWidth) * value.maxMillis;
    double nextFine;
    if (_scrubScale < 1.0) {
      nextFine = (currentMs + rawDeltaMs * _scrubScale).clamp(
        0.0,
        value.maxMillis,
      );
    } else {
      final prevFingerMs = prevX == null
          ? ((localPosition.dx - dx - sessionDetailProgressTrackInset) /
                    trackWidth) *
                value.maxMillis
          : ((prevX - sessionDetailProgressTrackInset) / trackWidth) *
                value.maxMillis;
      final nextFingerMs =
          ((localPosition.dx - sessionDetailProgressTrackInset) / trackWidth) *
          value.maxMillis;
      var scale = 1.0;
      if (dx > 0 && prevFingerMs >= 0 && prevFingerMs < value.maxMillis - 1.0) {
        final remFinger = value.maxMillis - prevFingerMs;
        final remThumb = value.maxMillis - currentMs;
        scale = (remThumb / remFinger).clamp(0.25, 3.0);
      } else if (dx < 0 &&
          prevFingerMs > 1.0 &&
          prevFingerMs <= value.maxMillis) {
        final remFinger = prevFingerMs;
        final remThumb = currentMs;
        scale = (remThumb / remFinger).clamp(0.25, 3.0);
      }
      nextFine = (currentMs + rawDeltaMs * scale).clamp(0.0, value.maxMillis);
      final clampedFingerMs = nextFingerMs.clamp(0.0, value.maxMillis);
      if ((nextFine - clampedFingerMs).abs() <= 1.0) {
        nextFine = clampedFingerMs;
        _usedFineScrub = false;
      }
    }
    _fineValueMs = nextFine;
    widget.onChanged(nextFine);
  }

  void _resetFineScrub() {
    _scrubScale = 1.0;
    _usedFineScrub = false;
    _lastPointerLocalX = null;
    _fineValueMs = null;
  }

  @override
  void initState() {
    super.initState();
    SessionProgressBar._mountedFrames.add(this);
    _tooltipAnimation =
        AnimationController(vsync: this, duration: kAppFadeDuration)
          ..addStatusListener((status) {
            if (status == AnimationStatus.dismissed && !_tooltipVisible) {
              _setTooltipPortalVisible(false);
            }
          });
    _tooltipOpacity = CurvedAnimation(
      parent: _tooltipAnimation,
      curve: kAppSpringCurve,
      reverseCurve: Curves.easeInCubic,
    );
    widget.tooltipValue.addListener(_handleTooltipChanged);
    _syncTooltipState();
  }

  @override
  void didUpdateWidget(covariant _ProgressSliderFrame oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tooltipValue != widget.tooltipValue) {
      oldWidget.tooltipValue.removeListener(_handleTooltipChanged);
      widget.tooltipValue.addListener(_handleTooltipChanged);
      _syncTooltipState();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _disableAnimations = MediaQuery.disableAnimationsOf(context);
    _tooltipAnimation.duration = _disableAnimations
        ? Duration.zero
        : kAppFadeDuration;
    if (!TickerMode.valuesOf(context).enabled) {
      _tooltipVisible = false;
      _tooltipAnimation.value = 0;
      _setTooltipPortalVisible(false);
    } else if (_disableAnimations) {
      _tooltipAnimation.value = _tooltipVisible ? 1 : 0;
    }
  }

  @override
  void dispose() {
    SessionProgressBar._mountedFrames.remove(this);
    widget.tooltipValue.removeListener(_handleTooltipChanged);
    _tooltipOpacity.dispose();
    _tooltipAnimation.dispose();
    super.dispose();
  }

  void _handleTooltipChanged() {
    _syncTooltipState();
  }

  void _setTooltipPortalVisible(bool visible) {
    void update() {
      if (!mounted || visible != _tooltipVisible) return;
      if (visible) {
        _tooltipPortalController.show();
      } else {
        _tooltipPortalController.hide();
      }
    }

    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => update());
    } else {
      update();
    }
  }

  void _syncTooltipState() {
    final state = widget.tooltipValue.value;
    final shouldShow = state != null && state.labels.isNotEmpty;
    if (shouldShow) _lastTooltip = state;
    if (shouldShow == _tooltipVisible) return;
    _tooltipVisible = shouldShow;
    if (shouldShow) {
      _setTooltipPortalVisible(true);
      _tooltipAnimation.forward();
    } else if (_disableAnimations) {
      _tooltipAnimation.value = 0;
      _setTooltipPortalVisible(false);
    } else {
      _tooltipAnimation.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sliderHeight = SessionProgressBar.seekTargetHeight;
    final showFineScrubBadge = _sliderDragging && _scrubScale < 1.0;
    final fineScrubText = _scrubScale <= 0.25 ? '0.25×' : '0.5×';
    final slider = CompositedTransformTarget(
      key: widget.sliderKey,
      link: _layerLink,
      child: MouseRegion(
        hitTestBehavior: HitTestBehavior.translucent,
        onEnter: (event) {
          _setSliderHovered(true);
          widget.onHover(event.localPosition);
        },
        onHover: (event) => widget.onHover(event.localPosition),
        onExit: (_) {
          _setSliderHovered(false);
          widget.onHoverExit();
        },
        child: SizedBox(
          height: sliderHeight,
          child: Stack(
            fit: StackFit.expand,
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(child: widget.staticLayer),
              TweenAnimationBuilder<double>(
                tween: Tween<double>(
                  end: (_sliderHovered || _sliderDragging) ? 1.0 : 0.0,
                ),
                duration:
                    (_disableAnimations ||
                        !TickerMode.valuesOf(context).enabled)
                    ? Duration.zero
                    : kAppMotionFast,
                curve: kAppSpringCurve,
                builder: (context, engagement, _) {
                  final baseTheme = sessionDetailProgressSliderTheme(
                    context,
                    widget.primaryColor,
                  );
                  final sliderTheme = engagement == 0.0
                      ? baseTheme
                      : baseTheme.copyWith(
                          trackHeight: 3.0 + 2.0 * engagement,
                          thumbShape: RoundSliderThumbShape(
                            enabledThumbRadius: 6.0 + 2.0 * engagement,
                            elevation: 2,
                            pressedElevation: 5,
                          ),
                        );
                  return SliderTheme(
                    data: sliderTheme,
                    child: ValueListenableBuilder<_ProgressSliderValue>(
                      valueListenable: widget.sliderValue,
                      builder: (context, value, child) {
                        return Listener(
                          behavior: HitTestBehavior.translucent,
                          onPointerDown: (event) {
                            _pointerDown = true;
                            if (!_sliderDragging) {
                              _resetFineScrub();
                              _scrubScale = _scrubScaleForOffset(
                                event.localPosition,
                              );
                            }
                            _lastPointerLocalX = event.localPosition.dx;
                          },
                          onPointerMove: _handlePointerMoveScrub,
                          onPointerUp: (_) => _pointerDown = false,
                          onPointerCancel: (_) => _pointerDown = false,
                          child: Slider(
                            max: value.maxMillis,
                            value: value.sliderValue,
                            secondaryTrackValue: value.bufferedValue,
                            onChangeStart: value.canSeek
                                ? (v) {
                                    _setSliderDragging(true);
                                    _fineValueMs = v;
                                    _usedFineScrub = _scrubScale < 1.0;
                                    widget.onChangeStart(v);
                                  }
                                : null,
                            onChanged: value.canSeek
                                ? (v) {
                                    if (_usedFineScrub) {
                                      return;
                                    }
                                    _fineValueMs = v;
                                    widget.onChanged(v);
                                  }
                                : null,
                            onChangeEnd: value.canSeek
                                ? (v) {
                                    final resolved = _usedFineScrub
                                        ? (_fineValueMs ?? v)
                                        : v;
                                    _resetFineScrub();
                                    _pointerDown = false;
                                    _setSliderDragging(false);
                                    widget.onChangeEnd(resolved);
                                  }
                                : null,
                            semanticFormatterCallback: (rawValue) {
                              final position = Duration(
                                milliseconds: rawValue.round(),
                              );
                              return '${formatDurationCompact(position)} / '
                                  '${formatDurationCompact(value.duration)}';
                            },
                          ),
                        );
                      },
                    ),
                  );
                },
              ),
              if (showFineScrubBadge)
                Positioned(
                  top: sliderHeight / 2 - 32,
                  left: 0,
                  right: 0,
                  child: IgnorePointer(
                    child: Center(
                      child: DecoratedBox(
                        key: const ValueKey('progress_fine_scrub_badge'),
                        decoration: BoxDecoration(
                          color: cs.surfaceContainerHigh.withValues(
                            alpha: 0.94,
                          ),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: widget.primaryColor.withValues(alpha: 0.35),
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          child: Text(
                            fineScrubText,
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(
                                  color: widget.primaryColor,
                                  fontWeight: FontWeight.w700,
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
      ),
    );
    return OverlayPortal(
      controller: _tooltipPortalController,
      overlayChildBuilder: (context) {
        return ValueListenableBuilder<_ProgressTooltipState?>(
          valueListenable: widget.tooltipValue,
          builder: (context, currentValue, child) {
            final value = currentValue ?? _lastTooltip;
            if (value == null || value.labels.isEmpty) {
              return const SizedBox.shrink();
            }
            return Align(
              alignment: Alignment.topLeft,
              child: CompositedTransformFollower(
                link: _layerLink,
                showWhenUnlinked: false,
                followerAnchor: Alignment.bottomLeft,
                offset: Offset(value.left, sliderHeight / 2 - 18),
                child: ScaleTransition(
                  scale: Tween<double>(
                    begin: 0.92,
                    end: 1,
                  ).animate(_tooltipOpacity),
                  alignment: Alignment.bottomLeft,
                  child: FadeTransition(
                    opacity: _tooltipOpacity,
                    child: _TimeSegmentDragTooltip(labels: value.labels),
                  ),
                ),
              ),
            );
          },
        );
      },
      child: widget.inlineTimecodes
          ? ValueListenableBuilder<_ProgressTimecodeValue>(
              valueListenable: widget.timecodeValue,
              child: slider,
              builder: (context, value, child) {
                final widthText = value.widthText;
                return Row(
                  children: [
                    TimecodeLabel(
                      text: value.elapsedText,
                      reserveText: widthText,
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: child!),
                    const SizedBox(width: 8),
                    TimecodeLabel(
                      text: value.remainingText,
                      reserveText: '-$widthText',
                      alignEnd: true,
                    ),
                  ],
                );
              },
            )
          : Column(
              children: [
                slider,
                Transform.translate(
                  offset: const Offset(0, -3),
                  child: ValueListenableBuilder<_ProgressTimecodeValue>(
                    valueListenable: widget.timecodeValue,
                    builder: (context, value, child) =>
                        _ProgressTimecodeRow(value: value),
                  ),
                ),
              ],
            ),
    );
  }
}

class _ProgressTimecodeRow extends StatelessWidget {
  const _ProgressTimecodeRow({required this.value});

  final _ProgressTimecodeValue value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          Expanded(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: TimecodeLabel(text: value.elapsedText),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: TimecodeLabel(text: value.remainingText, alignEnd: true),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProgressBarStaticLayer extends StatelessWidget {
  const _ProgressBarStaticLayer({
    required this.session,
    required this.labels,
    required this.selectedSegmentId,
    required this.colorScheme,
  });

  final PlaybackSessionSnapshot session;
  final List<TimeSegmentLabel> labels;
  final String? selectedSegmentId;
  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration?>(
      stream: session.durationStream,
      initialData: session.duration,
      builder: (context, snapshot) {
        final duration = snapshot.data ?? Duration.zero;
        final paintLabels = duration.inMilliseconds > 0
            ? labels
            : const <TimeSegmentLabel>[];
        return RepaintBoundary(
          child: CustomPaint(
            painter: _TimeSegmentProgressPainter(
              labels: paintLabels,
              duration: duration,
              selectedSegmentId: selectedSegmentId,
              colorScheme: colorScheme,
            ),
          ),
        );
      },
    );
  }
}

class _ProgressTooltipState {
  const _ProgressTooltipState({
    required this.labels,
    required this.dx,
    required this.left,
  });

  final List<TimeSegmentLabel> labels;
  final double dx;
  final double left;

  @override
  bool operator ==(Object other) {
    return other is _ProgressTooltipState &&
        listEquals(other.labels, labels) &&
        other.dx == dx &&
        other.left == left;
  }

  @override
  int get hashCode => Object.hash(Object.hashAll(labels), dx, left);
}

class _TimeSegmentProgressPainter extends CustomPainter {
  _TimeSegmentProgressPainter({
    required this.labels,
    required this.duration,
    required this.selectedSegmentId,
    required this.colorScheme,
  });

  final List<TimeSegmentLabel> labels;
  final Duration duration;
  final String? selectedSegmentId;
  final ColorScheme colorScheme;
  double? _markerWidth;
  List<({double x, double top})> _markers = const [];
  @visibleForTesting
  int debugMarkerLayoutBuilds = 0;
  @visibleForTesting
  List<({double x, double top})> get debugMarkers => _markers;

  void _layoutMarkers(Rect trackRect) {
    if (_markerWidth == trackRect.width) return;
    _markerWidth = trackRect.width;
    assert(() {
      debugMarkerLayoutBuilds++;
      return true;
    }());
    final positions = <double>[
      for (final label in labels)
        for (final position in [label.start, label.end])
          trackRect.left +
              trackRect.width *
                  (position.inMilliseconds / duration.inMilliseconds).clamp(
                    0.0,
                    1.0,
                  ),
    ];
    final sorted = List<double>.of(positions)..sort();
    final counts = List<int>.filled(sorted.length + 1, 0);
    int boundary(double value, {double offset = 0, bool afterEqual = false}) {
      var low = 0;
      var high = sorted.length;
      while (low < high) {
        final mid = (low + high) ~/ 2;
        final difference = sorted[mid] - value;
        if (difference < offset || (afterEqual && difference == offset)) {
          low = mid + 1;
        } else {
          high = mid;
        }
      }
      return low;
    }

    int prefixCount(int end) {
      var count = 0;
      for (var index = end; index > 0; index -= index & -index) {
        count += counts[index];
      }
      return count;
    }

    // Preserve original drawing order and strict 14px overlap parity without
    // scanning every preceding marker on every progress repaint.
    _markers = [];
    for (final x in positions) {
      final nearby =
          prefixCount(boundary(x, offset: 14)) -
          prefixCount(boundary(x, offset: -14, afterEqual: true));
      for (
        var index = boundary(x) + 1;
        index < counts.length;
        index += index & -index
      ) {
        counts[index]++;
      }
      _markers.add((x: x, top: nearby.isOdd ? 7.0 : 0.0));
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (labels.isEmpty || duration.inMilliseconds <= 0) return;
    const trackStart = sessionDetailProgressTrackInset;
    final trackWidth = _progressTrackWidth(size.width);
    final trackY = size.height / 2.0;
    final trackRect = Rect.fromLTWH(trackStart, trackY - 2.5, trackWidth, 5);

    for (final label in labels) {
      final color = Color(label.colorValue);
      final startRatio = label.start.inMilliseconds / duration.inMilliseconds;
      final endRatio = label.end.inMilliseconds / duration.inMilliseconds;
      final left = trackStart + trackWidth * startRatio.clamp(0.0, 1.0);
      final right = trackStart + trackWidth * endRatio.clamp(0.0, 1.0);
      if (right <= left) continue;
      final selected = label.id == selectedSegmentId;
      final segmentRect = Rect.fromLTRB(left, trackY - 3, right, trackY + 3);
      final rrect = RRect.fromRectAndRadius(
        segmentRect,
        const Radius.circular(4),
      );
      canvas.drawRRect(
        rrect,
        Paint()
          ..color = color.withValues(alpha: selected ? 0.72 : 0.38)
          ..style = PaintingStyle.fill,
      );
      if (selected) {
        canvas.drawRRect(
          rrect,
          Paint()
            ..color = colorScheme.onSurface.withValues(alpha: 0.78)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2,
        );
      }
    }

    _layoutMarkers(trackRect);
    for (var index = 0; index < labels.length; index++) {
      final label = labels[index];
      _drawMarker(
        canvas,
        trackRect,
        _markers[index * 2],
        Color(label.colorValue),
      );
      _drawMarker(
        canvas,
        trackRect,
        _markers[index * 2 + 1],
        Color(label.colorValue),
      );
    }
  }

  void _drawMarker(
    Canvas canvas,
    Rect trackRect,
    ({double x, double top}) marker,
    Color color,
  ) {
    final x = marker.x;
    final top = marker.top;
    final body = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(x, top + 3), width: 10, height: 6),
      const Radius.circular(2),
    );
    canvas.drawRRect(body, Paint()..color = color);
    final pointer = Path()
      ..moveTo(x - 3, top + 6)
      ..lineTo(x + 3, top + 6)
      ..lineTo(x, trackRect.top - 1)
      ..close();
    canvas.drawPath(pointer, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _TimeSegmentProgressPainter oldDelegate) {
    return oldDelegate.labels != labels ||
        oldDelegate.duration != duration ||
        oldDelegate.selectedSegmentId != selectedSegmentId ||
        oldDelegate.colorScheme != colorScheme;
  }
}

class _TimeSegmentDragTooltip extends StatelessWidget {
  const _TimeSegmentDragTooltip({required this.labels});

  final List<TimeSegmentLabel> labels;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 192),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: cs.surfaceContainerHigh.withValues(alpha: 0.96),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.4)),
          boxShadow: [
            BoxShadow(
              color: cs.shadow.withValues(alpha: 0.16),
              blurRadius: 16,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Wrap(
            spacing: 6,
            runSpacing: 4,
            children: labels
                .map(
                  (label) => DecoratedBox(
                    decoration: BoxDecoration(
                      color: Color(label.colorValue).withValues(alpha: 0.22),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      child: Text(
                        label.name,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: cs.onSurface,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                )
                .toList(growable: false),
          ),
        ),
      ),
    );
  }
}
