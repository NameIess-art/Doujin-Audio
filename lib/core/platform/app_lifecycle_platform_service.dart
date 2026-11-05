import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'app_platform.dart';
import 'platform_channels.dart';
import 'platform_method_client.dart';

class AppLifecyclePlatformService {
  AppLifecyclePlatformService({
    MethodChannel? channel,
    @visibleForTesting bool? isAndroidOverride,
  }) : _client = PlatformMethodClient(
         channel ?? const MethodChannel(AppLifecycleChannel.name),
       ),
       _isAndroidOverride = isAndroidOverride;

  final PlatformMethodClient _client;
  final bool? _isAndroidOverride;

  bool get _isAndroid => _isAndroidOverride ?? AppPlatform.isAndroid;
  bool get _isWindows =>
      _isAndroidOverride == null &&
      defaultTargetPlatform == TargetPlatform.windows;

  Future<bool> terminateForPendingRestore() async {
    if (!_isAndroid && !_isWindows) {
      await SystemNavigator.pop();
      return true;
    }
    final result = await _client.invoke<void>(
      AppLifecycleMethod.terminateForPendingRestore,
      decode: (_) {},
    );
    return result.isOk;
  }

  Future<bool> syncAppTheme({
    required String preset,
    required String themeMode,
  }) async {
    if (!_isAndroid && !_isWindows) return true;
    final result = await _client.invoke<void>(
      AppLifecycleMethod.syncAppTheme,
      arguments: <String, Object>{'preset': preset, 'themeMode': themeMode},
      decode: (_) {},
    );
    return result.isOk;
  }

  Future<bool> syncTrayMenu({
    required String open,
    required String toggle,
    required String previous,
    required String next,
    required String exit,
  }) async {
    if (!_isWindows) return true;
    final result = await _client.invoke<void>(
      AppLifecycleMethod.syncTrayMenu,
      arguments: <String, String>{
        'open': open,
        'toggle': toggle,
        'previous': previous,
        'next': next,
        'exit': exit,
      },
      decode: (_) {},
    );
    return result.isOk;
  }
}
