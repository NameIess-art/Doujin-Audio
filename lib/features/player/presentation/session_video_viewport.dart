import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../../../core/widgets/app_transitions.dart';

typedef SessionVideoSurfaceBuilder = Widget Function(BuildContext context);

enum SessionVideoGestureZone { left, center, right }

enum SessionVideoVerticalGestureSide { left, right }

const sessionVideoFullscreenControlBarHeight = 64.0;
const sessionVideoFullscreenGestureHorizontalInset = 24.0;

bool sessionVideoControlsVisibleAfterBlankTap(bool controlsVisible) {
  return !controlsVisible;
}

bool sessionVideoShouldAutoHideControls({
  required bool controlsVisible,
  required bool controlsInteracting,
}) {
  return controlsVisible && !controlsInteracting;
}

Rect sessionVideoFullscreenGestureRect({
  required Size viewportSize,
  required bool controlsVisible,
}) {
  final horizontalInset = sessionVideoFullscreenGestureHorizontalInset.clamp(
    0.0,
    viewportSize.width / 2,
  );
  final bottom =
      (viewportSize.height -
              (controlsVisible ? sessionVideoFullscreenControlBarHeight : 0))
          .clamp(0.0, viewportSize.height);
  return Rect.fromLTRB(
    horizontalInset,
    0,
    viewportSize.width - horizontalInset,
    bottom,
  );
}

SessionVideoGestureZone sessionVideoGestureZone(
  double localX,
  double viewportWidth,
) {
  if (viewportWidth <= 0) return SessionVideoGestureZone.center;
  if (localX < viewportWidth * 0.25) {
    return SessionVideoGestureZone.left;
  }
  if (localX >= viewportWidth * 0.75) {
    return SessionVideoGestureZone.right;
  }
  return SessionVideoGestureZone.center;
}

SessionVideoVerticalGestureSide sessionVideoVerticalGestureSide(
  double localX,
  double viewportWidth,
) {
  return localX < viewportWidth / 2
      ? SessionVideoVerticalGestureSide.left
      : SessionVideoVerticalGestureSide.right;
}

double sessionVideoVerticalGestureValue({
  required double startValue,
  required double dragDy,
  required double viewportHeight,
  required double minimum,
  required double maximum,
}) {
  if (viewportHeight <= 0 || maximum <= minimum) return startValue;
  final range = maximum - minimum;
  return (startValue - (dragDy / viewportHeight) * range).clamp(
    minimum,
    maximum,
  );
}

Duration sessionVideoHorizontalSeekTarget({
  required Duration startPosition,
  required Duration duration,
  required double dragDx,
  required double viewportWidth,
  Duration fullWidthDelta = const Duration(seconds: 90),
}) {
  if (viewportWidth <= 0 || duration <= Duration.zero) return startPosition;
  final deltaMs = (dragDx / viewportWidth * fullWidthDelta.inMilliseconds)
      .round();
  final targetMs = (startPosition.inMilliseconds + deltaMs).clamp(
    0,
    duration.inMilliseconds,
  );
  return Duration(milliseconds: targetMs);
}

Duration sessionVideoSkipTarget({
  required Duration position,
  required Duration duration,
  required Duration delta,
}) {
  if (duration <= Duration.zero) return position;
  return Duration(
    milliseconds: (position.inMilliseconds + delta.inMilliseconds).clamp(
      0,
      duration.inMilliseconds,
    ),
  );
}

class SessionVideoBlurredBackdrop extends StatelessWidget {
  const SessionVideoBlurredBackdrop({
    super.key,
    required this.child,
    this.sigma = 20,
  });

  final Widget child;
  final double sigma;

  @override
  Widget build(BuildContext context) {
    return Stack(
      key: const ValueKey<String>('session_video_blurred_backdrop'),
      fit: StackFit.expand,
      children: [
        Transform.scale(
          scale: 1.08,
          child: ImageFiltered(
            imageFilter: ImageFilter.blur(
              sigmaX: sigma,
              sigmaY: sigma,
              tileMode: TileMode.clamp,
            ),
            child: child,
          ),
        ),
        ColoredBox(color: Colors.black.withValues(alpha: 0.26)),
      ],
    );
  }
}

class SessionVideoViewport extends StatefulWidget {
  const SessionVideoViewport({
    super.key,
    required this.poster,
    required this.videoReady,
    required this.surfaceBuilder,
    required this.onFullscreen,
    required this.fullscreenTooltip,
    this.isFullscreen = false,
    this.controlsTimeout = const Duration(seconds: 3),
  });

  final Widget poster;
  final bool videoReady;
  final SessionVideoSurfaceBuilder surfaceBuilder;
  final Future<void> Function() onFullscreen;
  final String fullscreenTooltip;
  final bool isFullscreen;
  final Duration controlsTimeout;

  @override
  State<SessionVideoViewport> createState() => _SessionVideoViewportState();
}

class _SessionVideoViewportState extends State<SessionVideoViewport> {
  Timer? _controlsTimer;
  bool _controlsVisible = false;
  bool _surfaceSuspended = false;
  bool _fullscreenActionRunning = false;

  @override
  void didUpdateWidget(covariant SessionVideoViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.videoReady) return;
    _controlsTimer?.cancel();
    _controlsVisible = false;
    _surfaceSuspended = false;
  }

  @override
  void dispose() {
    _controlsTimer?.cancel();
    super.dispose();
  }

  void _toggleControls() {
    if (!widget.videoReady || _fullscreenActionRunning) return;
    _controlsTimer?.cancel();
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) {
      _controlsTimer = Timer(widget.controlsTimeout, () {
        if (!mounted) return;
        setState(() => _controlsVisible = false);
      });
    }
  }

  Future<void> _handleFullscreen() async {
    if (_fullscreenActionRunning || !widget.videoReady) return;
    _fullscreenActionRunning = true;
    _controlsTimer?.cancel();
    setState(() {
      _controlsVisible = false;
      _surfaceSuspended = true;
    });
    await WidgetsBinding.instance.endOfFrame;
    try {
      await widget.onFullscreen();
    } finally {
      _fullscreenActionRunning = false;
      if (mounted && widget.videoReady) {
        setState(() => _surfaceSuspended = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final showSurface = widget.videoReady && !_surfaceSuspended;
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.poster,
        if (showSurface)
          KeyedSubtree(
            key: const ValueKey<String>('session_video_surface'),
            child: widget.surfaceBuilder(context),
          ),
        if (widget.videoReady)
          Positioned.fill(
            child: GestureDetector(
              key: const ValueKey<String>('session_video_tap_target'),
              behavior: HitTestBehavior.opaque,
              onTap: _toggleControls,
              child: const ColoredBox(color: Colors.transparent),
            ),
          ),
        if (widget.videoReady)
          Positioned(
            right: 12,
            bottom: 12,
            child: AnimatedOpacity(
              key: const ValueKey<String>('session_video_fullscreen_control'),
              opacity: _controlsVisible ? 1 : 0,
              duration: kAppMotionFast,
              child: IgnorePointer(
                ignoring: !_controlsVisible,
                child: Material(
                  color: Colors.black.withValues(alpha: 0.58),
                  shape: const CircleBorder(),
                  child: IconButton(
                    tooltip: widget.fullscreenTooltip,
                    onPressed: _handleFullscreen,
                    color: Colors.white,
                    icon: Icon(
                      widget.isFullscreen
                          ? Icons.fullscreen_exit_rounded
                          : Icons.fullscreen_rounded,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
