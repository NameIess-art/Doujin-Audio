import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../application/native_playback_repository.dart';
import '../application/native_playback_bridge.dart';

@visibleForTesting
Size? resolveAndroidVideoSurfaceLogicalSize({
  required ({int width, int height})? videoSize,
  required Size displayPhysicalSize,
  required double devicePixelRatio,
}) {
  if (videoSize == null ||
      videoSize.width <= 0 ||
      videoSize.height <= 0 ||
      devicePixelRatio <= 0) {
    return null;
  }
  final rawSize = Size(
    videoSize.width.toDouble(),
    videoSize.height.toDouble(),
  );
  final longSide = math.max(
    displayPhysicalSize.width,
    displayPhysicalSize.height,
  );
  final shortSide = math.min(
    displayPhysicalSize.width,
    displayPhysicalSize.height,
  );
  final physicalTarget = longSide > 0 && shortSide > 0
      ? applyBoxFit(
          BoxFit.scaleDown,
          rawSize,
          videoSize.width >= videoSize.height
              ? Size(longSide, shortSide)
              : Size(shortSide, longSide),
        ).destination
      : rawSize;
  final logicalWidth = physicalTarget.width / devicePixelRatio;
  final logicalHeight = physicalTarget.height / devicePixelRatio;
  if (!logicalWidth.isFinite ||
      !logicalHeight.isFinite ||
      logicalWidth <= 0 ||
      logicalHeight <= 0) {
    return null;
  }
  return Size(logicalWidth, logicalHeight);
}

class NativeSessionVideoSurface extends StatefulWidget {
  const NativeSessionVideoSurface({
    super.key,
    required this.sessionId,
    required this.nativeRepository,
  });

  static const viewType = 'com.doujin.audio/native_video_surface';

  final String sessionId;
  final NativePlaybackRepository nativeRepository;

  @override
  State<NativeSessionVideoSurface> createState() =>
      _NativeSessionVideoSurfaceState();
}

class _NativeSessionVideoSurfaceState extends State<NativeSessionVideoSurface> {
  final GlobalKey _androidViewKey = GlobalKey(
    debugLabel: 'native_android_video_view',
  );
  StreamSubscription<NativePlaybackSnapshot>? _subscription;
  VideoController? _controller;
  ({int width, int height})? _androidVideoSize;
  String? _attachedSessionId;
  NativePlaybackRepository? _attachedRepository;

  @override
  void initState() {
    super.initState();
    _subscribeToRuntime();
  }

  void _subscribeToRuntime() {
    if (Platform.isWindows) {
      _attachedSessionId = widget.sessionId;
      _attachedRepository = widget.nativeRepository;
      widget.nativeRepository.attachVideoSurface(widget.sessionId);
      _controller = widget.nativeRepository.videoControllerForSession(
        widget.sessionId,
      );
      _subscription = widget.nativeRepository.snapshots.listen((snapshot) {
        if (!mounted || snapshot.sessionId != widget.sessionId) return;
        final controller = widget.nativeRepository.videoControllerForSession(
          widget.sessionId,
        );
        if (!identical(controller, _controller)) {
          setState(() => _controller = controller);
        }
      });
      return;
    }
    if (!Platform.isAndroid) return;
    _androidVideoSize = widget.nativeRepository.videoSizeForSession(
      widget.sessionId,
    );
    _subscription = widget.nativeRepository.snapshots.listen((snapshot) {
      if (!mounted || snapshot.sessionId != widget.sessionId) return;
      final width = snapshot.videoWidth;
      final height = snapshot.videoHeight;
      final next = width != null && width > 0 && height != null && height > 0
          ? (width: width, height: height)
          : widget.nativeRepository.videoSizeForSession(widget.sessionId);
      if (next != null && next != _androidVideoSize) {
        setState(() => _androidVideoSize = next);
      }
    });
  }

  void _unsubscribeFromRuntime() {
    unawaited(_subscription?.cancel());
    _subscription = null;
    final attachedId = _attachedSessionId;
    final attachedRepo = _attachedRepository;
    _attachedSessionId = null;
    _attachedRepository = null;
    if (attachedId != null && attachedRepo != null) {
      attachedRepo.detachVideoSurface(attachedId);
    }
  }

  @override
  void didUpdateWidget(covariant NativeSessionVideoSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionId != widget.sessionId ||
        oldWidget.nativeRepository != widget.nativeRepository) {
      _unsubscribeFromRuntime();
      _subscribeToRuntime();
    }
  }

  @override
  void dispose() {
    _unsubscribeFromRuntime();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sessionId = widget.sessionId;
    if (Platform.isWindows) {
      final controller = _controller;
      if (controller == null) return const SizedBox.shrink();
      return Video(
        key: ValueKey<String>('native_video_surface_$sessionId'),
        controller: controller,
        controls: null,
        // Subtitles are rendered by the existing synchronized subtitle UI.
        subtitleViewConfiguration: const SubtitleViewConfiguration(
          visible: false,
        ),
      );
    }
    if (!Platform.isAndroid) return const SizedBox.shrink();
    final androidView = AndroidView(
      key: _androidViewKey,
      viewType: NativeSessionVideoSurface.viewType,
      creationParams: <String, Object?>{'sessionId': sessionId},
      creationParamsCodec: const StandardMessageCodec(),
      hitTestBehavior: PlatformViewHitTestBehavior.transparent,
      layoutDirection: TextDirection.ltr,
    );
    final view = View.of(context);
    final dpr = view.devicePixelRatio;
    var displayPhysical = view.display.size;
    if (displayPhysical.isEmpty) {
      displayPhysical = view.physicalSize;
    }
    final logicalSurfaceSize = resolveAndroidVideoSurfaceLogicalSize(
      videoSize: _androidVideoSize,
      displayPhysicalSize: displayPhysical,
      devicePixelRatio: dpr,
    );
    if (logicalSurfaceSize == null) {
      return KeyedSubtree(
        key: ValueKey<String>('native_video_surface_$sessionId'),
        child: androidView,
      );
    }
    // Keep the platform view at a constant video-aspect-ratio buffer size so
    // fullscreen morphs and screen rotations transform on the GPU instead of
    // asynchronously reallocating the Android virtual display per frame.
    return KeyedSubtree(
      key: ValueKey<String>('native_video_surface_$sessionId'),
      child: ClipRect(
        child: FittedBox(
          child: SizedBox(
            width: logicalSurfaceSize.width,
            height: logicalSurfaceSize.height,
            child: androidView,
          ),
        ),
      ),
    );
  }
}
