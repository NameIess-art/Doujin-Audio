import 'dart:async';

import 'package:flutter/material.dart';

typedef SessionVideoSurfaceBuilder = Widget Function(BuildContext context);

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
              duration: const Duration(milliseconds: 160),
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
