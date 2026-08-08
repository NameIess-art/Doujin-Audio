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

  Future<bool> terminateForPendingRestore() async {
    if (!_isAndroid) {
      await SystemNavigator.pop();
      return true;
    }
    final result = await _client.invoke<void>(
      AppLifecycleMethod.terminateForPendingRestore,
      decode: (_) {},
    );
    return result.isOk;
  }
}
