import 'dart:async';

import '../../../core/platform/subtitle_overlay_platform_service.dart';

class SubtitleOverlayController {
  static final SubtitleOverlayPlatformService _platform =
      SubtitleOverlayPlatformService();

  static Future<bool> canDrawOverlays() async {
    return _platform.canDrawOverlays();
  }

  static Future<bool> openOverlaySettings() async {
    return _platform.openOverlaySettings();
  }

  static Timer? _stopTimer;

  static Future<void> startOverlay() async {
    _stopTimer?.cancel();
    _stopTimer = null;
    await _platform.startOverlay();
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
    await _platform.stopOverlay();
  }

  static Future<void> updateSubtitle(String text) async {
    await _platform.updateSubtitle(text);
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
    await _platform.updateStyle(args);
  }
}
