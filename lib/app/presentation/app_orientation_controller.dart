import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show Orientation;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/logging/app_log_service.dart';
import '../../core/platform/video_display_platform_gateway.dart';
import '../state/app_runtime_providers.dart';

typedef PreferredOrientationsSetter =
    Future<void> Function(List<DeviceOrientation> orientations);
typedef SystemUiModeSetter = Future<void> Function(SystemUiMode mode);

Future<void> _defaultSetPreferredOrientations(
  List<DeviceOrientation> orientations,
) => SystemChrome.setPreferredOrientations(orientations);

Future<void> _defaultSetSystemUiMode(SystemUiMode mode) =>
    SystemChrome.setEnabledSystemUIMode(mode);

class AppOrientationPolicy {
  const AppOrientationPolicy._(this.allowedOrientations);

  static const portrait = AppOrientationPolicy._([
    DeviceOrientation.portraitUp,
  ]);

  static const rotatable = AppOrientationPolicy._([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  static const landscape = AppOrientationPolicy._([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  final List<DeviceOrientation> allowedOrientations;
}

final appOrientationControllerProvider = Provider<AppOrientationController>((
  ref,
) {
  final appLifecycle = ref.watch(appLifecyclePlatformServiceProvider);
  return AppOrientationController(
    videoDisplay: ref.watch(videoDisplayPlatformGatewayProvider),
    setSystemUiMode: defaultTargetPlatform == TargetPlatform.android
        ? (mode) => appLifecycle.setImmersiveMode(
            mode == SystemUiMode.immersiveSticky,
          )
        : null,
  );
});

class AppOrientationController {
  AppOrientationController({
    PreferredOrientationsSetter? setPreferredOrientations,
    SystemUiModeSetter? setSystemUiMode,
    VideoDisplayPlatformGateway? videoDisplay,
  }) : _setPreferredOrientations =
           setPreferredOrientations ?? _defaultSetPreferredOrientations,
       _setSystemUiMode = setSystemUiMode ?? _defaultSetSystemUiMode,
       _videoDisplay = videoDisplay;

  final PreferredOrientationsSetter _setPreferredOrientations;
  final SystemUiModeSetter _setSystemUiMode;
  final VideoDisplayPlatformGateway? _videoDisplay;
  final Set<int> _fullscreenLeaseIds = <int>{};
  PlatformBrightnessLease? _brightnessLease;

  bool _playbackDetailVisible = false;
  Orientation? _bedtimeCanvasOrientation;
  int _nextLeaseId = 0;
  AppOrientationPolicy? _appliedOrientation;
  SystemUiMode _appliedSystemUiMode = SystemUiMode.edgeToEdge;

  bool get isVideoFullscreen => _fullscreenLeaseIds.isNotEmpty;

  Future<void> updateTopRoute({
    required bool playbackDetailVisible,
    Orientation? bedtimeCanvasOrientation,
  }) async {
    if (defaultTargetPlatform == TargetPlatform.windows) return;
    _playbackDetailVisible = playbackDetailVisible;
    _bedtimeCanvasOrientation = bedtimeCanvasOrientation;
    if (isVideoFullscreen) return;
    await _applyPreferredOrientation();
    await _applySystemUiMode();
  }

  Future<void> setPlaybackDetailVisible(bool visible) => updateTopRoute(
    playbackDetailVisible: visible,
    bedtimeCanvasOrientation: _bedtimeCanvasOrientation,
  );

  Future<AppVideoFullscreenLease> enterVideoFullscreen() async {
    final wasFullscreen = isVideoFullscreen;
    final leaseId = ++_nextLeaseId;
    _fullscreenLeaseIds.add(leaseId);
    if (defaultTargetPlatform == TargetPlatform.windows) {
      return AppVideoFullscreenLease._(this, leaseId, initialBrightness: null);
    }
    if (!wasFullscreen) {
      await _beginBrightnessControl();
      await _applyPreferredOrientation();
      await _applySystemUiMode();
    }
    return AppVideoFullscreenLease._(
      this,
      leaseId,
      initialBrightness: _brightnessLease?.brightness,
    );
  }

  Future<void> _releaseVideoFullscreen(int leaseId) async {
    if (!_fullscreenLeaseIds.remove(leaseId) || isVideoFullscreen) return;
    if (defaultTargetPlatform == TargetPlatform.windows) {
      return;
    }
    await _endBrightnessControl();
    await _applySystemUiMode();
    await _applyPreferredOrientation();
  }

  Future<void> _beginBrightnessControl() async {
    final videoDisplay = _videoDisplay;
    if (videoDisplay == null) return;
    if (_brightnessLease != null) {
      await _endBrightnessControl();
      if (_brightnessLease != null) return;
    }
    final result = await videoDisplay.beginBrightnessControl();
    final lease = result.valueOrNull;
    if (lease != null) {
      _brightnessLease = lease;
      return;
    }
    AppLogService.warning(
      'video_fullscreen_brightness_enter_failed: '
      '${result.errorCodeOrNull} ${result.errorOrNull}',
    );
  }

  Future<bool> _setVideoBrightness(int leaseId, double brightness) async {
    final platformLease = _brightnessLease;
    final videoDisplay = _videoDisplay;
    if (!_fullscreenLeaseIds.contains(leaseId) ||
        platformLease == null ||
        videoDisplay == null) {
      return false;
    }
    final result = await videoDisplay.setBrightness(
      platformLease.token,
      brightness.clamp(0.05, 1.0),
    );
    if (result.isOk) return true;
    AppLogService.warning(
      'video_fullscreen_brightness_update_failed: '
      '${result.errorCodeOrNull} ${result.errorOrNull}',
    );
    return false;
  }

  Future<void> _endBrightnessControl() async {
    final platformLease = _brightnessLease;
    final videoDisplay = _videoDisplay;
    if (platformLease == null || videoDisplay == null) return;
    final result = await videoDisplay.endBrightnessControl(platformLease.token);
    if (result.isOk) {
      if (identical(_brightnessLease, platformLease)) {
        _brightnessLease = null;
      }
    } else {
      AppLogService.warning(
        'video_fullscreen_brightness_restore_failed: '
        '${result.errorCodeOrNull} ${result.errorOrNull}',
      );
    }
  }

  Future<void> _applyPreferredOrientation() {
    final policy = switch (_bedtimeCanvasOrientation) {
      Orientation.landscape => AppOrientationPolicy.landscape,
      Orientation.portrait => AppOrientationPolicy.portrait,
      null =>
        isVideoFullscreen || _playbackDetailVisible
            ? AppOrientationPolicy.rotatable
            : AppOrientationPolicy.portrait,
    };
    if (_appliedOrientation == policy) return Future.value();
    _appliedOrientation = policy;
    return _runPlatformUpdate(
      'orientation_preference_update_failed',
      () => _setPreferredOrientations(policy.allowedOrientations),
    );
  }

  Future<void> _applySystemUiMode() {
    if (defaultTargetPlatform == TargetPlatform.windows) return Future.value();
    final mode =
        (isVideoFullscreen ||
            ((_playbackDetailVisible || _bedtimeCanvasOrientation != null) &&
                defaultTargetPlatform == TargetPlatform.android))
        ? SystemUiMode.immersiveSticky
        : SystemUiMode.edgeToEdge;
    if (_appliedSystemUiMode == mode) return Future.value();
    _appliedSystemUiMode = mode;
    return _runPlatformUpdate(
      'system_ui_mode_update_failed',
      () => _setSystemUiMode(mode),
    );
  }

  Future<void> _runPlatformUpdate(
    String event,
    Future<void> Function() update,
  ) async {
    try {
      await update();
    } catch (error, stackTrace) {
      AppLogService.warning(event, error: error, stackTrace: stackTrace);
    }
  }
}

class AppVideoFullscreenLease {
  AppVideoFullscreenLease._(
    this._controller,
    this._leaseId, {
    required this.initialBrightness,
  });

  final AppOrientationController _controller;
  final int _leaseId;
  final double? initialBrightness;
  bool _released = false;

  Future<bool> setBrightness(double brightness) {
    if (_released) return Future<bool>.value(false);
    return _controller._setVideoBrightness(_leaseId, brightness);
  }

  Future<void> release() async {
    if (_released) return;
    _released = true;
    await _controller._releaseVideoFullscreen(_leaseId);
  }
}
