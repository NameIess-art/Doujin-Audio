import 'dart:async';

import 'package:flutter/services.dart';

import '../../../core/platform/platform_channels.dart';

class SubtitleOverlayController {
  static const _channel = MethodChannel(SubtitleOverlayChannel.name);

  static Future<bool> canDrawOverlays() async {
    try {
      return await _channel.invokeMethod<bool>(
            SubtitleOverlayMethod.canDrawOverlays,
          ) ??
          false;
    } on PlatformException catch (_) {
      return false;
    }
  }

  static Future<bool> openOverlaySettings() async {
    try {
      return await _channel.invokeMethod<bool>(
            SubtitleOverlayMethod.openOverlaySettings,
          ) ??
          false;
    } on PlatformException catch (_) {
      return false;
    }
  }

  static Timer? _stopTimer;

  static Future<void> startOverlay() async {
    _stopTimer?.cancel();
    _stopTimer = null;
    try {
      await _channel.invokeMethod(SubtitleOverlayMethod.startOverlay);
    } on PlatformException catch (_) {
      // Overlay support is optional on platforms without the native channel.
    }
  }

  static Future<void> stopOverlay({bool immediate = false}) async {
    _stopTimer?.cancel();
    _stopTimer = null;
    if (immediate) {
      await _doStop();
    } else {
      _stopTimer = Timer(const Duration(milliseconds: 300), () {
        unawaited(_doStop());
      });
    }
  }

  static Future<void> _doStop() async {
    _stopTimer?.cancel();
    _stopTimer = null;
    try {
      await _channel.invokeMethod(SubtitleOverlayMethod.stopOverlay);
    } on PlatformException catch (_) {
      // Overlay support is optional on platforms without the native channel.
    }
  }

  static Future<void> updateSubtitle(String text) async {
    try {
      await _channel.invokeMethod(SubtitleOverlayMethod.updateSubtitle, {
        'text': text,
      });
    } on PlatformException catch (_) {
      // Subtitle updates are best effort when the overlay is unavailable.
    }
  }

  static Future<void> updatePlaybackState(bool isPlaying) async {
    // The Android overlay receives playback state through its service.
  }

  static Future<void> updateStyle({
    double? fontSize,
    String? backgroundColor,
    String? textColor,
    double? backgroundOpacity,
    String? fontFamily,
    double? borderDepth,
  }) async {
    final args = <String, Object?>{
      'fontSize': fontSize,
      'backgroundColor': backgroundColor,
      'textColor': textColor,
      'backgroundOpacity': backgroundOpacity,
      'fontFamily': fontFamily,
      'borderDepth': borderDepth,
    }..removeWhere((_, value) => value == null);
    try {
      await _channel.invokeMethod(SubtitleOverlayMethod.updateStyle, args);
    } on PlatformException catch (_) {
      // Style updates are best effort when the overlay is unavailable.
    }
  }
}
