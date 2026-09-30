import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../application/native_playback_repository.dart';
import '../application/native_playback_bridge.dart';

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
  StreamSubscription<NativePlaybackSnapshot>? _subscription;

  @override
  void initState() {
    super.initState();
    _acquire();
  }

  void _acquire() {
    if (!Platform.isWindows) return;
    _subscription = widget.nativeRepository.snapshots.listen((snapshot) {
      if (mounted && snapshot.sessionId == widget.sessionId) setState(() {});
    });
    widget.nativeRepository.acquireVideoSurface(widget.sessionId);
  }

  void _release(NativeSessionVideoSurface surface) {
    unawaited(_subscription?.cancel());
    _subscription = null;
    surface.nativeRepository.releaseVideoSurface(surface.sessionId);
  }

  @override
  void didUpdateWidget(covariant NativeSessionVideoSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionId != widget.sessionId ||
        oldWidget.nativeRepository != widget.nativeRepository) {
      _release(oldWidget);
      _acquire();
    }
  }

  @override
  void dispose() {
    _release(widget);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sessionId = widget.sessionId;
    final nativeRepository = widget.nativeRepository;
    if (Platform.isWindows) {
      final controller = nativeRepository.videoControllerForSession(sessionId);
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
    return AndroidView(
      key: ValueKey<String>('native_video_surface_$sessionId'),
      viewType: NativeSessionVideoSurface.viewType,
      creationParams: <String, Object?>{'sessionId': sessionId},
      creationParamsCodec: const StandardMessageCodec(),
      hitTestBehavior: PlatformViewHitTestBehavior.transparent,
      layoutDirection: TextDirection.ltr,
    );
  }
}
