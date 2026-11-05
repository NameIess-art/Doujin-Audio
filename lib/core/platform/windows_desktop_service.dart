import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'platform_channels.dart';

/// Windows shell events enter the existing application runtime through this gateway.
class WindowsDesktopService {
  WindowsDesktopService({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('doujin_audio/windows_desktop');

  static final instance = WindowsDesktopService();
  final MethodChannel _channel;
  final _maximized = ValueNotifier(false);
  ValueListenable<bool> get maximized => _maximized;

  Future<void> attach(Future<void> Function(String action) onAction) async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'action' && call.arguments is String) {
        await onAction(call.arguments as String);
      } else if (call.method == 'windowMaximized' && call.arguments is bool) {
        _maximized.value = call.arguments as bool;
      }
    });
    await _channel.invokeMethod<void>('ready');
  }

  Future<void> setFullscreen(bool enabled) =>
      _channel.invokeMethod<void>('setFullscreen', {'enabled': enabled});

  Future<void> runWindowCommand(WindowsWindowCommand command) =>
      _channel.invokeMethod<void>('windowCommand', {'command': command.name});

  Future<Map<String, bool>> getHotkeyStatus() async {
    final status = await _channel.invokeMapMethod<String, bool>(
      'getHotkeyStatus',
    );
    if (status == null) {
      throw const FormatException('Missing Windows hotkey registration status');
    }
    return status;
  }

  Future<void> exit() => _channel.invokeMethod<void>('exit');
}
