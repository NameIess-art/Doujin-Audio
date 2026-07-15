import 'package:flutter/services.dart';

import '../errors/native_result.dart';
import '../logging/app_log_service.dart';
import 'platform_channels.dart';
import 'platform_method_client.dart';

class SubtitleOverlayPlatformService {
  SubtitleOverlayPlatformService({MethodChannel? channel})
    : _client = PlatformMethodClient(
        channel ?? const MethodChannel(SubtitleOverlayChannel.name),
      );

  final PlatformMethodClient _client;

  Future<bool> canDrawOverlays() {
    return _invokeBool(SubtitleOverlayMethod.canDrawOverlays);
  }

  Future<bool> openOverlaySettings() {
    return _invokeBool(SubtitleOverlayMethod.openOverlaySettings);
  }

  Future<void> startOverlay() {
    return _invokeBestEffort(SubtitleOverlayMethod.startOverlay);
  }

  Future<void> stopOverlay() {
    return _invokeBestEffort(SubtitleOverlayMethod.stopOverlay);
  }

  Future<void> updateSubtitle(String text) {
    return _invokeBestEffort(
      SubtitleOverlayMethod.updateSubtitle,
      <String, Object?>{'text': text},
    );
  }

  Future<void> updateStyle(Map<String, Object?> style) {
    return _invokeBestEffort(SubtitleOverlayMethod.updateStyle, style);
  }

  Future<bool> _invokeBool(String method) async {
    final result = await _client.invoke<bool>(
      method,
      decode: (value) => value as bool,
    );
    _logFailure(method, result);
    return result.valueOrNull ?? false;
  }

  Future<void> _invokeBestEffort(String method, [Object? arguments]) async {
    final result = await _client.invoke<Object?>(
      method,
      arguments: arguments,
      decode: (value) => value,
    );
    _logFailure(method, result);
  }

  void _logFailure<T>(String method, NativeResult<T> result) {
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
