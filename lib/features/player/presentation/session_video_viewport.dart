import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/widgets/app_transitions.dart';
import '../../../core/widgets/app_buttons.dart';

typedef SessionVideoSurfaceBuilder = Widget Function(BuildContext context);

enum SessionVideoGestureZone { left, center, right }

enum SessionVideoVerticalGestureSide { left, right }

const sessionVideoFullscreenControlBarHeight = 128.0;
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
  double controlBarHeight = sessionVideoFullscreenControlBarHeight,
}) {
  final horizontalInset = sessionVideoFullscreenGestureHorizontalInset.clamp(
    0.0,
    viewportSize.width / 2,
  );
  final bottom =
      (viewportSize.height - (controlsVisible ? controlBarHeight : 0)).clamp(
        0.0,
        viewportSize.height,
      );
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
  const SessionVideoBlurredBackdrop({super.key, required this.child});

  static final _blur = ImageFilter.blur(
    sigmaX: 20,
    sigmaY: 20,
    tileMode: TileMode.clamp,
  );

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      key: const ValueKey<String>('session_video_blurred_backdrop'),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Transform.scale(
            scale: 1.08,
            child: ImageFiltered(imageFilter: _blur, child: child),
          ),
          ColoredBox(color: Colors.black.withValues(alpha: 0.26)),
        ],
      ),
    );
  }
}

class SessionVideoControlsTarget extends StatefulWidget {
  const SessionVideoControlsTarget({
    super.key,
    required this.label,
    required this.controlsVisible,
    required this.onToggle,
  });

  final String label;
  final bool controlsVisible;
  final VoidCallback onToggle;

  @override
  State<SessionVideoControlsTarget> createState() =>
      _SessionVideoControlsTargetState();
}

class _SessionVideoControlsTargetState
    extends State<SessionVideoControlsTarget> {
  bool _showFocus = false;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: widget.label,
      button: true,
      toggled: widget.controlsVisible,
      onTap: widget.onToggle,
      child: FocusableActionDetector(
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) => widget.onToggle(),
          ),
        },
        onShowFocusHighlight: (show) => setState(() => _showFocus = show),
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: _showFocus
                ? const Border.fromBorderSide(
                    BorderSide(color: Colors.white, width: 2),
                  )
                : null,
          ),
          child: const SizedBox.expand(),
        ),
      ),
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
    required this.controlsLabel,
    this.isFullscreen = false,
    this.controlsTimeout = const Duration(seconds: 3),
  });

  final Widget poster;
  final bool videoReady;
  final SessionVideoSurfaceBuilder surfaceBuilder;
  final Future<void> Function() onFullscreen;
  final String fullscreenTooltip;
  final String controlsLabel;
  final bool isFullscreen;
  final Duration controlsTimeout;

  @override
  State<SessionVideoViewport> createState() => _SessionVideoViewportState();
}

class _SessionVideoViewportState extends State<SessionVideoViewport> {
  Timer? _controlsTimer;
  bool _controlsVisible = false;
  bool _cursorInside = false;
  bool _suppressedWhileHovered = false;
  Offset? _lastHoverPosition;
  bool _fullscreenActionRunning = false;
  bool _controlsHaveFocus = false;

  bool get _effectiveControlsVisible =>
      !_fullscreenActionRunning &&
      ((_cursorInside && !_suppressedWhileHovered) || _controlsVisible);

  @override
  void didUpdateWidget(covariant SessionVideoViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.videoReady) return;
    _controlsTimer?.cancel();
    _controlsVisible = false;
    _cursorInside = false;
    _suppressedWhileHovered = false;
    _lastHoverPosition = null;
  }

  @override
  void dispose() {
    _controlsTimer?.cancel();
    super.dispose();
  }

  void _toggleControls() {
    if (!widget.videoReady || _fullscreenActionRunning) return;
    final currentlyVisible = _effectiveControlsVisible;
    setState(() {
      if (currentlyVisible) {
        _controlsVisible = false;
        if (_cursorInside) {
          _suppressedWhileHovered = true;
        }
      } else {
        _controlsVisible = true;
        _suppressedWhileHovered = false;
      }
    });
    _scheduleControlsHide();
  }

  void _scheduleControlsHide() {
    _controlsTimer?.cancel();
    if (!_controlsVisible || _controlsHaveFocus) return;
    _controlsTimer = Timer(widget.controlsTimeout, () {
      if (!mounted) return;
      setState(() => _controlsVisible = false);
    });
  }

  Future<void> _handleFullscreen() async {
    if (_fullscreenActionRunning || !widget.videoReady) return;
    _controlsTimer?.cancel();
    setState(() {
      _controlsVisible = false;
      _cursorInside = false;
      _suppressedWhileHovered = false;
      _lastHoverPosition = null;
      _fullscreenActionRunning = true;
    });
    try {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || !widget.videoReady) return;
      await widget.onFullscreen();
    } finally {
      if (mounted) {
        setState(() => _fullscreenActionRunning = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final showSurface = widget.videoReady && !_fullscreenActionRunning;
    final controlsVisible = _effectiveControlsVisible;
    final viewport = MouseRegion(
      onEnter: widget.videoReady
          ? (event) => setState(() {
              _cursorInside = true;
              _suppressedWhileHovered = false;
              _lastHoverPosition = event.localPosition;
            })
          : null,
      onHover: widget.videoReady
          ? (event) {
              final previousPosition = _lastHoverPosition;
              final movedEnough =
                  previousPosition == null ||
                  (event.localPosition - previousPosition).distance > 2.0;
              if (!_suppressedWhileHovered || movedEnough) {
                _lastHoverPosition = event.localPosition;
              }
              if (!_cursorInside || (_suppressedWhileHovered && movedEnough)) {
                setState(() {
                  _cursorInside = true;
                  if (movedEnough) {
                    _suppressedWhileHovered = false;
                  }
                });
              }
            }
          : null,
      onExit: widget.videoReady
          ? (_) => setState(() {
              _cursorInside = false;
              _suppressedWhileHovered = false;
              _lastHoverPosition = null;
              if (_controlsHaveFocus && !_fullscreenActionRunning) {
                _controlsVisible = true;
              }
            })
          : null,
      child: Stack(
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
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  key: const ValueKey<String>('session_video_tap_target'),
                  excludeFromSemantics: true,
                  behavior: HitTestBehavior.opaque,
                  onTap: _toggleControls,
                  child: SessionVideoControlsTarget(
                    label: widget.controlsLabel,
                    controlsVisible: controlsVisible,
                    onToggle: _toggleControls,
                  ),
                ),
              ),
            ),
          if (widget.videoReady)
            Positioned(
              right: 12,
              top: 12,
              child: AnimatedOpacity(
                curve: kAppFadeCurve,
                key: const ValueKey<String>('session_video_fullscreen_control'),
                opacity: controlsVisible ? 1 : 0,
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : kAppFadeDuration,
                child: IgnorePointer(
                  ignoring: !controlsVisible,
                  child: ExcludeFocus(
                    excluding: !controlsVisible,
                    child: ExcludeSemantics(
                      excluding: !controlsVisible,
                      child: Semantics(
                        container: true,
                        label: TooltipVisibility.of(context)
                            ? null
                            : widget.fullscreenTooltip,
                        child: AppOverlayIconButton(
                          tooltip: widget.fullscreenTooltip,
                          onPressed: _handleFullscreen,
                          buttonSize: 48,
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
              ),
            ),
        ],
      ),
    );
    return Focus(
      canRequestFocus: false,
      descendantsAreFocusable: !_fullscreenActionRunning,
      includeSemantics: false,
      onFocusChange: (focused) {
        _controlsHaveFocus = focused;
        _scheduleControlsHide();
      },
      child: viewport,
    );
  }
}
