class AppVersionInfo {
  const AppVersionInfo({
    required this.versionName,
    required this.buildNumber,
    this.androidAssetVariant,
  });

  final String versionName;
  final int buildNumber;
  final String? androidAssetVariant;
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
    required this.tagPrefix,
    required this.androidAssetPrefix,
  });

  final String tagPrefix;
  final String androidAssetPrefix;

  String get platformAssetPrefix => androidAssetPrefix;

  String androidAssetPrefixFor(String? variant) {
    return switch (variant) {
      'arm64' => 'DoujinAudio-android-arm64-',
      'armv7' => 'DoujinAudio-android-armv7-',
      'x64' => 'DoujinAudio-android-x64-',
      _ => androidAssetPrefix,
    };
  }

  static const ReleaseChannelConfig stable = ReleaseChannelConfig(
    tagPrefix: '',
    androidAssetPrefix: 'DoujinAudio-android-universal-',
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
