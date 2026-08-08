import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/core/errors/native_result.dart';
import 'package:nameless_audio/core/platform/platform_channels.dart';

void main() {
  test('platform channel names remain stable and unique', () {
    const names = <String>[
      NativePlaybackChannel.name,
      NativePlaybackChannel.eventName,
      PowerChannel.name,
      FileCacheChannel.name,
      FileCacheChannel.scanEvents,
      NotificationsChannel.name,
      SubtitleOverlayChannel.name,
      UpdateChannel.name,
      VideoDisplayChannel.name,
    ];

    expect(names.toSet(), hasLength(names.length));
    expect(UpdateChannel.name, 'nameless_audio/update');
    expect(VideoDisplayChannel.name, 'nameless_audio/video_display');
    expect(FileCacheChannel.name, 'nameless_audio/file_cache');
  });

  test('critical method names remain protocol compatible', () {
    const fileCacheMethods = <String>[
      FileCacheMethod.discoverRootImages,
      FileCacheMethod.resolveTrackCover,
      FileCacheMethod.resolveTrackSubtitle,
      FileCacheMethod.resolveVideoFrame,
      FileCacheMethod.resolveMediaDuration,
      FileCacheMethod.cacheFromUri,
      FileCacheMethod.scanFolder,
      FileCacheMethod.startFolderScan,
      FileCacheMethod.cancelFolderScan,
      FileCacheMethod.listChildFolders,
      FileCacheMethod.renameDocument,
      FileCacheMethod.readJsonDocument,
      FileCacheMethod.writeJsonDocument,
      FileCacheMethod.deleteJsonDocument,
      FileCacheMethod.writeFileBytesToFolder,
      FileCacheMethod.documentPathExists,
      FileCacheMethod.resolveDocumentFileSystemPath,
      FileCacheMethod.ensureFolderPath,
      FileCacheMethod.copyFileToFolder,
      FileCacheMethod.exportFile,
      FileCacheMethod.deleteDocumentPath,
      FileCacheMethod.clearApplicationCache,
      FileCacheMethod.setApplicationCacheLimit,
      FileCacheMethod.enforceApplicationCacheLimit,
      FileCacheMethod.getStorageUsage,
      FileCacheMethod.pickAudioSource,
      FileCacheMethod.pickAudioFiles,
      FileCacheMethod.pickAudioFolder,
    ];
    const subtitleOverlayMethods = <String>[
      SubtitleOverlayMethod.canDrawOverlays,
      SubtitleOverlayMethod.openOverlaySettings,
      SubtitleOverlayMethod.startOverlay,
      SubtitleOverlayMethod.stopOverlay,
      SubtitleOverlayMethod.updateSubtitle,
      SubtitleOverlayMethod.updateStyle,
    ];

    expect(fileCacheMethods.toSet(), hasLength(fileCacheMethods.length));
    expect(
      subtitleOverlayMethods.toSet(),
      hasLength(subtitleOverlayMethods.length),
    );
    expect(NativePlaybackMethod.prepareSession, 'prepareSession');
    expect(NativePlaybackMethod.snapshot, 'snapshot');
    expect(NativePlaybackMethod.setTemporarySpeed, 'setTemporarySpeed');
    expect(FileCacheMethod.startFolderScan, 'startFolderScan');
    expect(FileCacheMethod.cancelFolderScan, 'cancelFolderScan');
    expect(FileCacheMethod.exportFile, 'exportFile');
    expect(FileCacheMethod.resolveTrackSubtitle, 'resolveTrackSubtitle');
    expect(SubtitleOverlayMethod.updateSubtitle, 'updateSubtitle');
    expect(
      NotificationsMethod.syncUnifiedPlaybackNotifications,
      'syncUnifiedPlaybackNotifications',
    );
    expect(UpdateMethod.getAppVersion, 'getAppVersion');
    expect(UpdateMethod.installApk, 'installApk');
    expect(UpdateMethod.openReleasePage, 'openReleasePage');
  });

  test('native failure codes remain protocol compatible', () {
    expect(NativeErrorCode.invalidArgument, 'invalid_argument');
    expect(NativeErrorCode.serviceUnavailable, 'service_unavailable');
    expect(NativeErrorCode.playerError, 'player_error');
    expect(NativeErrorCode.platformError, 'platform_error');
  });
}
