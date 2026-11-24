import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'scroll_activity_gate.dart';

/// An animated audio equalizer sound wave indicator with vertical jumping bars.
/// Commonly placed next to the track name in media lists to mark the active item.
class PlayingSoundWaveIndicator extends StatefulWidget {
  const PlayingSoundWaveIndicator({
    super.key,
    this.color,
    this.isPlaying = true,
    this.size = 14.0,
    this.barCount = 4,
    this.barWidth = 2.2,
    this.barSpacing = 1.6,
  });

  /// The color of the waveform bars. Defaults to [ColorScheme.primary].
  final Color? color;

  /// Whether playback is actively running. When false, bars remain at calm idle heights.
  final bool isPlaying;

  /// The height (and target bounds) of the indicator. Defaults to 14.0.
  final double size;

  /// Number of equalizer bars. Defaults to 4.
  final int barCount;

  /// Width of each bar. Defaults to 2.2.
  final double barWidth;

  /// Gap between adjacent bars. Defaults to 1.6.
  final double barSpacing;

  @override
  State<PlayingSoundWaveIndicator> createState() =>
      _PlayingSoundWaveIndicatorState();
}

class _PlayingSoundWaveIndicatorState extends State<PlayingSoundWaveIndicator>
    with SingleTickerProviderStateMixin {
  static const double _cycleSeconds = 22.0;
  static const double _dampSpan = 0.18 / _cycleSeconds;

  late final AnimationController _controller;
  final ValueNotifier<double> _energy = ValueNotifier<double>(1.0);
  double? _dampingStartValue;
  ValueListenable<bool>? _scrollActivity;
  bool _tickerEnabled = false;
  bool _disableAnimations = false;

  @override
  void initState() {
    super.initState();
    _energy.value = widget.isPlaying ? 1.0 : 0.0;
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 22),
    )..addListener(_handleTick);
  }

  void _handleTick() {
    final start = _dampingStartValue;
    if (start == null) return;
    var delta = _controller.value - start;
    if (delta < 0) delta += 1.0;
    if (delta >= _dampSpan) {
      _dampingStartValue = null;
      _energy.value = 0.0;
      _controller.stop();
    } else {
      _energy.value = (1.0 - delta / _dampSpan).clamp(0.0, 1.0);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickerEnabled = TickerMode.valuesOf(context).enabled;
    _disableAnimations =
        MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final activity = ScrollActivityGate.scrollingListenableOf(context);
    if (!identical(activity, _scrollActivity)) {
      _scrollActivity?.removeListener(_syncAnimation);
      _scrollActivity = activity;
      _scrollActivity?.addListener(_syncAnimation);
    }
    _syncAnimation();
  }

  void _syncAnimation() {
    final scrolling = _scrollActivity?.value ?? false;
    final canAnimate = _tickerEnabled && !_disableAnimations && !scrolling;
    if (widget.isPlaying && canAnimate) {
      _dampingStartValue = null;
      _energy.value = 1.0;
      if (!_controller.isAnimating) {
        _controller.repeat();
      }
      return;
    }
    if (!canAnimate) {
      _dampingStartValue = null;
      _energy.value = widget.isPlaying && !_disableAnimations ? 1.0 : 0.0;
      if (_controller.isAnimating) {
        _controller.stop();
      }
      return;
    }
    // Smoothly damp bar heights toward calm idle pose over 180ms using the
    // single existing ticker when playback pauses while visible and stationary.
    if (_energy.value > 0.0 && _controller.isAnimating) {
      _dampingStartValue ??= _controller.value;
    } else {
      _dampingStartValue = null;
      _energy.value = 0.0;
      if (_controller.isAnimating) {
        _controller.stop();
      }
    }
  }

  @override
  void didUpdateWidget(covariant PlayingSoundWaveIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncAnimation();
  }

  @override
  void dispose() {
    _scrollActivity?.removeListener(_syncAnimation);
    _controller.dispose();
    _energy.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final effectiveColor =
        widget.color ?? Theme.of(context).colorScheme.primary;
    final totalWidth =
        widget.barCount * widget.barWidth +
        (widget.barCount - 1) * widget.barSpacing;

    return RepaintBoundary(
      child: SizedBox(
        width: totalWidth,
        height: widget.size,
        child: CustomPaint(
          size: Size(totalWidth, widget.size),
          painter: _SoundWavePainter(
            animation: _controller,
            energy: _energy,
            color: effectiveColor,
            isPlaying: widget.isPlaying && !_disableAnimations,
            barCount: widget.barCount,
            barWidth: widget.barWidth,
            barSpacing: widget.barSpacing,
          ),
        ),
      ),
    );
  }
}

class _SoundWavePainter extends CustomPainter {
  _SoundWavePainter({
    required this.animation,
    required this.energy,
    required this.color,
    required this.isPlaying,
    required this.barCount,
    required this.barWidth,
    required this.barSpacing,
  }) : super(repaint: Listenable.merge([animation, energy]));

  final Animation<double> animation;
  final ValueListenable<double> energy;
  final Color color;
  final bool isPlaying;
  final int barCount;
  final double barWidth;
  final double barSpacing;

  // Whole cycles in 22 seconds preserve the bar speeds and match both height
  // and velocity at the loop boundary.
  static const List<int> _cycles = [20, 29, 23, 32];
  static const List<double> _phases = [0.0, 1.2, 2.7, 4.1];
  static const List<double> _minHeights = [0.25, 0.35, 0.20, 0.30];
  static const List<double> _maxHeights = [0.85, 1.0, 0.75, 0.95];
  static const List<double> _idleHeights = [0.45, 0.8, 0.6, 0.35];

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final radius = Radius.circular(barWidth / 2);
    final e = Curves.easeOutCubic.transform(energy.value.clamp(0.0, 1.0));
    final t = e > 0 ? animation.value : 0.0;

    for (var i = 0; i < barCount; i++) {
      final cycles = _cycles[i % _cycles.length];
      final phase = _phases[i % _phases.length];
      final minH = _minHeights[i % _minHeights.length];
      final maxH = _maxHeights[i % _maxHeights.length];
      final idleH = _idleHeights[i % _idleHeights.length];

      final double fraction;
      if (e > 0) {
        final sinVal = math.sin((2 * math.pi * cycles * t) + phase);
        final waveH = minH + (maxH - minH) * ((sinVal + 1) / 2);
        fraction = idleH + (waveH - idleH) * e;
      } else {
        fraction = idleH;
      }

      final barHeight = (size.height * fraction).clamp(barWidth, size.height);
      final left = i * (barWidth + barSpacing);
      final top = size.height - barHeight;

      final rrect = RRect.fromRectAndRadius(
        Rect.fromLTWH(left, top, barWidth, barHeight),
        radius,
      );
      canvas.drawRRect(rrect, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _SoundWavePainter oldDelegate) {
    return oldDelegate.color != color ||
        oldDelegate.isPlaying != isPlaying ||
        oldDelegate.barCount != barCount ||
        oldDelegate.barWidth != barWidth ||
        oldDelegate.barSpacing != barSpacing;
  }
}
