import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/services.dart';

class SubtitleOverlayController {
  static const _channel = MethodChannel('nameless_audio/subtitle_overlay');
  static WindowController? _windowsOverlayController;
  static Map<String, Object?> _windowsStyleArgs = const {};
  static String _windowsSubtitleText = '';
  static bool? _windowsIsPlaying;

  static Future<bool> canDrawOverlays() async {
    if (Platform.isWindows) return true;
    try {
      return await _channel.invokeMethod<bool>('canDrawOverlays') ?? false;
    } on PlatformException catch (_) {
      return false;
    }
  }

  static Future<bool> openOverlaySettings() async {
    if (Platform.isWindows) return true;
    try {
      return await _channel.invokeMethod<bool>('openOverlaySettings') ?? false;
    } on PlatformException catch (_) {
      return false;
    }
  }

  static Timer? _stopTimer;

  static Future<void> startOverlay() async {
    _stopTimer?.cancel();
    _stopTimer = null;
    if (Platform.isWindows) {
      if (_windowsOverlayController == null) {
        final window = await WindowController.create(
          WindowConfiguration(
            hiddenAtLaunch: false,
            arguments: jsonEncode({
              'initialStyle': _windowsStyleArgs,
              'initialSubtitle': _windowsSubtitleText,
              if (_windowsIsPlaying != null)
                'initialIsPlaying': _windowsIsPlaying,
            }),
          ),
        );
        _windowsOverlayController = window;
        await _showWindowsOverlay(window);
      }
      final window = _windowsOverlayController;
      if (window != null) {
        _scheduleWindowsShow(window);
        _scheduleWindowsStateReplay(window);
      }
      return;
    }
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
        unawaited(_doStop());
      });
    }
  }

  static Future<void> _doStop() async {
    _stopTimer?.cancel();
    _stopTimer = null;
    if (Platform.isWindows) {
      if (_windowsOverlayController != null) {
        await _windowsOverlayController!.hide();
        _windowsOverlayController = null;
      }
      return;
    }
    try {
      await _channel.invokeMethod('stopOverlay');
    } on PlatformException catch (_) {}
  }

  static Future<void> updateSubtitle(String text) async {
    if (Platform.isWindows) {
      _windowsSubtitleText = text;
      final window = _windowsOverlayController;
      if (window != null) {
        unawaited(
          _invokeWindowsOverlay(window, 'updateSubtitle', {'text': text}),
        );
      }
      return;
    }
    try {
      await _channel.invokeMethod('updateSubtitle', {'text': text});
    } on PlatformException catch (_) {}
  }

  static Future<void> updatePlaybackState(bool isPlaying) async {
    if (Platform.isWindows) {
      _windowsIsPlaying = isPlaying;
      final window = _windowsOverlayController;
      if (window != null) {
        unawaited(
          _invokeWindowsOverlay(window, 'updatePlaybackState', {
            'isPlaying': isPlaying,
          }),
        );
      }
      return;
    }
  }

  static Future<void> updateStyle({
    double? fontSize,
    String? backgroundColor,
    String? textColor,
    double? backgroundOpacity,
    String? fontFamily,
    double? borderDepth,
    double? backgroundBlur,
  }) async {
    final args = <String, Object?>{
      'fontSize': fontSize,
      'backgroundColor': backgroundColor,
      'textColor': textColor,
      'backgroundOpacity': backgroundOpacity,
      'fontFamily': fontFamily,
      'borderDepth': borderDepth,
      'backgroundBlur': backgroundBlur,
    }..removeWhere((_, value) => value == null);
    if (Platform.isWindows) {
      _windowsStyleArgs = args;
      final window = _windowsOverlayController;
      if (window != null) {
        unawaited(_invokeWindowsOverlay(window, 'updateStyle', args));
      }
      return;
    }
    try {
      await _channel.invokeMethod('updateStyle', args);
    } on PlatformException catch (_) {}
  }

  static Future<void> _replayWindowsState(WindowController window) async {
    if (_windowsStyleArgs.isNotEmpty) {
      await _invokeWindowsOverlay(window, 'updateStyle', _windowsStyleArgs);
    }
    await _invokeWindowsOverlay(window, 'updateSubtitle', {
      'text': _windowsSubtitleText,
    });
    final isPlaying = _windowsIsPlaying;
    if (isPlaying != null) {
      await _invokeWindowsOverlay(window, 'updatePlaybackState', {
        'isPlaying': isPlaying,
      });
    }
  }

  static void _scheduleWindowsStateReplay(WindowController window) {
    unawaited(_replayWindowsState(window));
    unawaited(
      Future<void>.delayed(const Duration(milliseconds: 120), () {
        return _replayWindowsState(window);
      }),
    );
    unawaited(
      Future<void>.delayed(const Duration(milliseconds: 350), () {
        return _replayWindowsState(window);
      }),
    );
  }

  static Future<void> _showWindowsOverlay(WindowController window) async {
    try {
      await window.show();
    } catch (_) {}
  }

  static void _scheduleWindowsShow(WindowController window) {
    unawaited(_showWindowsOverlay(window));
    unawaited(
      Future<void>.delayed(const Duration(milliseconds: 120), () {
        return _showWindowsOverlay(window);
      }),
    );
    unawaited(
      Future<void>.delayed(const Duration(milliseconds: 350), () {
        return _showWindowsOverlay(window);
      }),
    );
  }

  static Future<void> _invokeWindowsOverlay(
    WindowController window,
    String method, [
    Object? arguments,
  ]) async {
    try {
      await window.invokeMethod(method, arguments);
    } on PlatformException catch (_) {
    } on MissingPluginException catch (_) {
    } catch (_) {}
  }

  static void initMethodHandler(
    Future<dynamic> Function(MethodCall call) handler,
  ) {
    if (Platform.isWindows) {
      WindowController.fromWindowId('0').setWindowMethodHandler(handler);
    }
  }
}
