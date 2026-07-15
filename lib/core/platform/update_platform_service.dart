import 'package:flutter/services.dart';

import '../errors/native_result.dart';
import 'platform_channels.dart';
import 'platform_method_client.dart';

class PlatformAppVersion {
  const PlatformAppVersion({
    required this.versionName,
    required this.buildNumber,
  });

  final String versionName;
  final int buildNumber;
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
    return _client.invoke<PlatformUpdateInstallResult>(
      UpdateMethod.installApk,
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
