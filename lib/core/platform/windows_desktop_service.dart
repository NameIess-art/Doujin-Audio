import 'dart:async';

import 'package:flutter/services.dart';

/// Windows shell events enter the existing application runtime through this gateway.
class WindowsDesktopService {
  WindowsDesktopService({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('doujin_audio/windows_desktop');

  static final instance = WindowsDesktopService();
  final MethodChannel _channel;

  Future<void> attach(Future<void> Function(String action) onAction) async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'action' && call.arguments is String) {
        await onAction(call.arguments as String);
      }
    });
    await _channel.invokeMethod<void>('ready');
  }

  Future<void> setFullscreen(bool enabled) =>
      _channel.invokeMethod<void>('setFullscreen', {'enabled': enabled});

  Future<void> exit() => _channel.invokeMethod<void>('exit');
}
