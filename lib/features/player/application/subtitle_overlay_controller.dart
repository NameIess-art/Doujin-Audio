import 'dart:async';

import 'package:flutter/services.dart';

import '../../../core/errors/native_result.dart';
import '../../../core/logging/app_log_service.dart';
import '../../../core/platform/platform_channels.dart';
import '../../../core/platform/platform_method_client.dart';

class SubtitleOverlayController {
  static const _channel = MethodChannel(SubtitleOverlayChannel.name);
  static const _client = PlatformMethodClient(_channel);

  static Future<bool> canDrawOverlays() async {
    return _invokeBool(SubtitleOverlayMethod.canDrawOverlays);
  }

  static Future<bool> openOverlaySettings() async {
    return _invokeBool(SubtitleOverlayMethod.openOverlaySettings);
  }

  static Timer? _stopTimer;

  static Future<void> startOverlay() async {
    _stopTimer?.cancel();
    _stopTimer = null;
    await _invokeBestEffort(SubtitleOverlayMethod.startOverlay);
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
    await _invokeBestEffort(SubtitleOverlayMethod.stopOverlay);
  }

  static Future<void> updateSubtitle(String text) async {
    await _invokeBestEffort(
      SubtitleOverlayMethod.updateSubtitle,
      <String, Object?>{'text': text},
    );
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
    await _invokeBestEffort(SubtitleOverlayMethod.updateStyle, args);
  }

  static Future<bool> _invokeBool(String method) async {
    final result = await _client.invoke<bool>(
      method,
      decode: (value) => value as bool,
    );
    _logFailure(method, result);
    return result.valueOrNull ?? false;
  }

  static Future<void> _invokeBestEffort(
    String method, [
    Object? arguments,
  ]) async {
    final result = await _client.invoke<Object?>(
      method,
      arguments: arguments,
      decode: (value) => value,
    );
    _logFailure(method, result);
  }

  static void _logFailure<T>(String method, NativeResult<T> result) {
    if (result case NativeFailure<T>(
      :final code,
      :final message,
      :final details,
    )) {
      AppLogService.warning(
        'subtitle_overlay_method_failed method=$method code=$code',
        error: <String, Object?>{'message': message, 'details': details},
      );
    }
  }
}
