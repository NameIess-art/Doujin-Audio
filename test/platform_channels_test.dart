import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/services/platform_channels.dart';

void main() {
  test('platform channel names remain stable and unique', () {
    const names = <String>[
      NativePlaybackChannel.name,
      NativePlaybackChannel.eventName,
      PowerChannel.name,
      FileCacheChannel.name,
      FileCacheChannel.scanEvents,
      NotificationsChannel.name,
      UpdateChannel.name,
    ];

    expect(names.toSet(), hasLength(names.length));
    expect(UpdateChannel.name, 'nameless_audio/update');
    expect(FileCacheChannel.name, 'nameless_audio/file_cache');
  });

  test('critical method names remain protocol compatible', () {
    expect(NativePlaybackMethod.prepareSession, 'prepareSession');
    expect(NativePlaybackMethod.snapshot, 'snapshot');
    expect(FileCacheMethod.startFolderScan, 'startFolderScan');
    expect(FileCacheMethod.cancelFolderScan, 'cancelFolderScan');
    expect(
      NotificationsMethod.syncUnifiedPlaybackNotifications,
      'syncUnifiedPlaybackNotifications',
    );
    expect(UpdateMethod.getAppVersion, 'getAppVersion');
    expect(UpdateMethod.installApk, 'installApk');
    expect(UpdateMethod.openReleasePage, 'openReleasePage');
  });
}
