import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

class NativeSessionVideoSurface extends StatelessWidget {
  const NativeSessionVideoSurface({super.key, required this.sessionId});

  static const viewType = 'com.nameless.audio/native_video_surface';

  final String sessionId;

  @override
  Widget build(BuildContext context) {
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
