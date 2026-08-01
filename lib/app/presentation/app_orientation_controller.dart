import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/logging/app_log_service.dart';

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

  static const current = AppOrientationPolicy._([
    DeviceOrientation.portraitUp,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  static const videoFullscreen = AppOrientationPolicy._([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  final List<DeviceOrientation> allowedOrientations;
}

final appOrientationControllerProvider = Provider<AppOrientationController>((
  ref,
) {
  return AppOrientationController();
});

class AppOrientationController {
  AppOrientationController({
    PreferredOrientationsSetter? setPreferredOrientations,
    SystemUiModeSetter? setSystemUiMode,
  }) : _setPreferredOrientations =
           setPreferredOrientations ?? _defaultSetPreferredOrientations,
       _setSystemUiMode = setSystemUiMode ?? _defaultSetSystemUiMode;

  final PreferredOrientationsSetter _setPreferredOrientations;
  final SystemUiModeSetter _setSystemUiMode;
  final Set<int> _fullscreenLeaseIds = <int>{};

  bool _portraitLockEnabled = false;
  int _nextLeaseId = 0;

  bool get isVideoFullscreen => _fullscreenLeaseIds.isNotEmpty;

  Future<void> setPortraitLockEnabled(bool enabled) async {
    _portraitLockEnabled = enabled;
    if (isVideoFullscreen) return;
    await _applyPreferredOrientation();
  }

  Future<AppVideoFullscreenLease> enterVideoFullscreen() async {
    final wasFullscreen = isVideoFullscreen;
    final leaseId = ++_nextLeaseId;
    _fullscreenLeaseIds.add(leaseId);
    if (!wasFullscreen) {
      await _runPlatformUpdate(
        'video_fullscreen_orientation_enter_failed',
        () => _setPreferredOrientations(
          AppOrientationPolicy.videoFullscreen.allowedOrientations,
        ),
      );
      await _runPlatformUpdate(
        'video_fullscreen_system_ui_enter_failed',
        () => _setSystemUiMode(SystemUiMode.immersiveSticky),
      );
    }
    return AppVideoFullscreenLease._(this, leaseId);
  }

  Future<void> _releaseVideoFullscreen(int leaseId) async {
    if (!_fullscreenLeaseIds.remove(leaseId) || isVideoFullscreen) return;
    await _runPlatformUpdate(
      'video_fullscreen_system_ui_restore_failed',
      () => _setSystemUiMode(SystemUiMode.edgeToEdge),
    );
    await _applyPreferredOrientation();
  }

  Future<void> _applyPreferredOrientation() {
    return _runPlatformUpdate(
      'orientation_preference_update_failed',
      () => _setPreferredOrientations(
        _portraitLockEnabled
            ? AppOrientationPolicy.portrait.allowedOrientations
            : AppOrientationPolicy.current.allowedOrientations,
      ),
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
  AppVideoFullscreenLease._(this._controller, this._leaseId);

  final AppOrientationController _controller;
  final int _leaseId;
  bool _released = false;

  Future<void> release() async {
    if (_released) return;
    _released = true;
    await _controller._releaseVideoFullscreen(_leaseId);
  }
}
