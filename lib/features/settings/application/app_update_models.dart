import 'dart:io';

class AppVersionInfo {
  const AppVersionInfo({required this.versionName, required this.buildNumber});

  final String versionName;
  final int buildNumber;
}

enum AppUpdateStatus {
  updateAvailable,
  upToDate,
  noCompatibleRelease,
  missingAsset,
  missingChecksum,
}

class ReleaseChannelConfig {
  const ReleaseChannelConfig({
    required this.major,
    required this.tagPrefix,
    required this.androidAssetPrefix,
    required this.windowsAssetPrefix,
  });

  final int major;
  final String tagPrefix;
  final String androidAssetPrefix;
  final String windowsAssetPrefix;

  String get platformAssetPrefix =>
      Platform.isWindows ? windowsAssetPrefix : androidAssetPrefix;

  static const ReleaseChannelConfig stable = ReleaseChannelConfig(
    major: 0,
    tagPrefix: '',
    androidAssetPrefix: 'NamelessAudio-android-universal-',
    windowsAssetPrefix: 'NamelessAudio-windows-x64-',
  );
}

class AppUpdateInfo {
  const AppUpdateInfo({
    required this.currentVersion,
    required this.latestVersionName,
    required this.tagName,
    required this.assetName,
    required this.assetUrl,
    required this.checksumAssetUrl,
    required this.releaseUrl,
    required this.isUpdateAvailable,
    this.status = AppUpdateStatus.updateAvailable,
    this.releaseName,
    this.publishedAt,
  });

  final AppVersionInfo currentVersion;
  final String latestVersionName;
  final String tagName;
  final String? releaseName;
  final String? assetName;
  final String? assetUrl;
  final String? checksumAssetUrl;
  final String releaseUrl;
  final DateTime? publishedAt;
  final bool isUpdateAvailable;
  final AppUpdateStatus status;

  bool get canDownload =>
      isUpdateAvailable &&
      assetName != null &&
      assetName!.isNotEmpty &&
      assetUrl != null &&
      assetUrl!.isNotEmpty &&
      checksumAssetUrl != null &&
      checksumAssetUrl!.isNotEmpty;
}

class UpdateInstallResult {
  const UpdateInstallResult({
    required this.ok,
    required this.needsPermission,
    this.message,
  });

  final bool ok;
  final bool needsPermission;
  final String? message;
}
