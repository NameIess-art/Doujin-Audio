import 'dart:async';
import 'package:flutter/services.dart';

class SubtitleOverlayController {
  static const _channel = MethodChannel('nameless_audio/subtitle_overlay');

  static Future<bool> canDrawOverlays() async {
    try {
      return await _channel.invokeMethod<bool>('canDrawOverlays') ?? false;
    } on PlatformException catch (_) {
      return false;
    }
  }

  static Future<bool> openOverlaySettings() async {
    try {
      return await _channel.invokeMethod<bool>('openOverlaySettings') ?? false;
    } on PlatformException catch (_) {
      return false;
    }
  }

  static Timer? _stopTimer;
  static bool _isActive = false;

  static Future<void> startOverlay() async {
    _stopTimer?.cancel();
    _stopTimer = null;
    _isActive = true;
    try {
      await _channel.invokeMethod('startOverlay');
    } on PlatformException catch (_) {}
  }

  static Future<void> stopOverlay({bool immediate = false}) async {
    _stopTimer?.cancel();
    _stopTimer = null;
    if (immediate) {
      await _doStop();
    } else {
      _stopTimer = Timer(const Duration(milliseconds: 300), () {
        _doStop();
      });
    }
  }

  static Future<void> _doStop() async {
    _stopTimer?.cancel();
    _stopTimer = null;
    _isActive = false;
    try {
      await _channel.invokeMethod('stopOverlay');
    } on PlatformException catch (_) {}
  }

  static Future<void> updateSubtitle(String text) async {
    try {
      await _channel.invokeMethod('updateSubtitle', {'text': text});
    } on PlatformException catch (_) {}
  }

  static Future<void> updateStyle({
    double? fontSize,
    String? backgroundColor,
    String? textColor,
  }) async {
    try {
      await _channel.invokeMethod('updateStyle', {
        if (fontSize != null) 'fontSize': fontSize,
        if (backgroundColor != null) 'backgroundColor': backgroundColor,
        if (textColor != null) 'textColor': textColor,
      });
    } on PlatformException catch (_) {}
  }
}
