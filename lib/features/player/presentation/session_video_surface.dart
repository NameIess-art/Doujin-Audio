import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../application/native_playback_repository.dart';

class NativeSessionVideoSurface extends StatelessWidget {
  const NativeSessionVideoSurface({
    super.key,
    required this.sessionId,
    required this.nativeRepository,
  });

  static const viewType = 'com.doujin.audio/native_video_surface';

  final String sessionId;
  final NativePlaybackRepository nativeRepository;
  @override
  Widget build(BuildContext context) {
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
      viewType: viewType,
      creationParams: <String, Object?>{'sessionId': sessionId},
      creationParamsCodec: const StandardMessageCodec(),
      hitTestBehavior: PlatformViewHitTestBehavior.transparent,
      layoutDirection: TextDirection.ltr,
    );
  }
}
