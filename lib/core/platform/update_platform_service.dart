import 'package:flutter/services.dart';

import '../errors/native_result.dart';
import 'platform_channels.dart';
import 'platform_method_client.dart';

class PlatformAppVersion {
  const PlatformAppVersion({
    required this.versionName,
    required this.buildNumber,
    this.androidAssetVariant,
    this.platform = 'android',
  });

  final String versionName;
  final int buildNumber;
  final String? androidAssetVariant;
  final String platform;
}

class PlatformUpdateInstallResult {
  const PlatformUpdateInstallResult({
    required this.ok,
    required this.needsPermission,
    this.message,
  });

  final bool ok;
  final bool needsPermission;
  final String? message;
}

class UpdatePlatformService {
  UpdatePlatformService({MethodChannel? channel})
    : _client = PlatformMethodClient(
        channel ?? const MethodChannel(UpdateChannel.name),
      );

  final PlatformMethodClient _client;

  Future<NativeResult<PlatformAppVersion>> getAppVersion() {
    return _client.invoke<PlatformAppVersion>(
      UpdateMethod.getAppVersion,
      decode: (value) {
        final map = Map<Object?, Object?>.from(value as Map);
        return PlatformAppVersion(
          versionName: map['versionName'] as String,
          buildNumber: (map['buildNumber'] as num).toInt(),
          androidAssetVariant: map['androidAssetVariant'] as String?,
          platform: map['platform'] as String? ?? 'android',
        );
      },
    );
  }

  Future<NativeResult<bool>> canInstallUnknownApps() {
    return _invokeBool(UpdateMethod.canInstallUnknownApps);
  }

  Future<NativeResult<bool>> openInstallPermissionSettings() {
    return _invokeBool(UpdateMethod.openInstallPermissionSettings);
  }

  Future<NativeResult<bool>> openReleasePage(String url) {
    return _invokeBool(
      UpdateMethod.openReleasePage,
      arguments: <String, Object?>{'url': url},
    );
  }

  Future<NativeResult<PlatformUpdateInstallResult>> installApk(String path) {
    return _install(UpdateMethod.installApk, path);
  }

  Future<NativeResult<PlatformUpdateInstallResult>> installWindowsUpdate(
    String path,
  ) {
    return _install('installWindowsUpdate', path);
  }

  Future<NativeResult<PlatformUpdateInstallResult>> _install(
    String method,
    String path,
  ) {
    return _client.invoke<PlatformUpdateInstallResult>(
      method,
      arguments: <String, Object?>{'path': path},
      decode: (value) {
        final map = Map<Object?, Object?>.from(value as Map);
        return PlatformUpdateInstallResult(
          ok: map['ok'] == true,
          needsPermission: map['needsPermission'] == true,
          message: map['message'] as String?,
        );
      },
    );
  }

  Future<NativeResult<bool>> _invokeBool(String method, {Object? arguments}) {
    return _client.invoke<bool>(
      method,
      arguments: arguments,
      decode: (value) => value as bool,
    );
  }
}
