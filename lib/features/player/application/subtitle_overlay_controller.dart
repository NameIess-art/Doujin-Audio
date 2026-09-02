import 'dart:async';

import '../../../core/platform/subtitle_overlay_platform_service.dart';

typedef SubtitleOverlayStopTimerFactory =
    Timer Function(Duration duration, void Function() callback);

bool shouldRequestSubtitleOverlayPermission({required bool isAndroid}) {
  return isAndroid;
}

final class SubtitleOverlayController {
  SubtitleOverlayController({
    SubtitleOverlayPlatformService? platform,
    SubtitleOverlayStopTimerFactory? stopTimerFactory,
  }) : _platform = platform ?? SubtitleOverlayPlatformService(),
       _stopTimerFactory = stopTimerFactory ?? Timer.new;

  final SubtitleOverlayPlatformService _platform;
  final SubtitleOverlayStopTimerFactory _stopTimerFactory;
  Timer? _stopTimer;
  bool _disposed = false;
  int _commandGeneration = 0;

  Future<bool> canDrawOverlays() => _platform.canDrawOverlays();

  Future<bool> openOverlaySettings() => _platform.openOverlaySettings();

  Future<bool> startOverlay() async {
    if (_disposed) return false;
    final generation = ++_commandGeneration;
    _stopTimer?.cancel();
    _stopTimer = null;
    await _platform.startOverlay();
    if (_disposed || generation != _commandGeneration) {
      await _platform.stopOverlay();
      return false;
    }
    return true;
  }

  Future<void> stopOverlay({bool immediate = false}) async {
    final generation = ++_commandGeneration;
    _stopTimer?.cancel();
    _stopTimer = null;
    if (immediate) {
      await _doStop();
    } else {
      if (_disposed) return;
      _stopTimer = _stopTimerFactory(const Duration(milliseconds: 300), () {
        if (!_disposed && generation == _commandGeneration) {
          unawaited(_doStop());
        }
      });
    }
  }

  Future<void> _doStop() async {
    _stopTimer?.cancel();
    _stopTimer = null;
    await _platform.stopOverlay();
  }

  Future<void> updateSubtitle(String text) => _platform.updateSubtitle(text);

  Future<void> updateStyle({
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

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _commandGeneration++;
    _stopTimer?.cancel();
    _stopTimer = null;
    await _platform.stopOverlay();
  }
}
