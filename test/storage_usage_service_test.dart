import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/core/platform/file_cache_platform_gateway.dart';
import 'package:doujin_audio/features/data_support/application/storage_usage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('test/storage_usage_service');
  const scanEvents = EventChannel('test/storage_usage_service/scan_events');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockStreamHandler(scanEvents, null);
  });

  MusicTrack track(String path, int? bytes) => MusicTrack(
    path: path,
    displayName: 'Track',
    groupKey: 'group',
    groupTitle: 'Group',
    groupSubtitle: '',
    isSingle: true,
    fileSizeBytes: bytes,
  );

  test('sums distinct local tracks and derives other occupied space', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      return <String, Object?>{
        'ok': true,
        'value': <String, Object?>{
          'totalBytes': 1000,
          'availableBytes': 400,
          'cacheBytes': 500,
        },
      };
    });
    final gateway = FileCachePlatformGateway(
      channel: channel,
      scanEvents: scanEvents,
      isAndroid: () => true,
    );
    final service = StorageUsageService(
      fileCacheGateway: gateway,
      libraryTracks: () => [
        track('/audio/a.mp3', 100),
        track('/audio/./a.mp3', 100),
        track('https://example.com/remote.mp3', 200),
        track('/audio/invalid.mp3', -1),
      ],
    );

    final snapshot = await service.load();

    expect(snapshot.isAvailable, isTrue);
    expect(snapshot.totalBytes, 1000);
    expect(snapshot.availableBytes, 400);
    expect(snapshot.audioLibraryBytes, 100);
    expect(snapshot.applicationCacheBytes, 500);
    expect(snapshot.otherUsedBytes, 0);
    expect(
      snapshot.audioLibraryBytes +
          snapshot.applicationCacheBytes +
          snapshot.otherUsedBytes +
          snapshot.availableBytes,
      snapshot.totalBytes,
    );
  });

  test(
    'returns unavailable when the platform cannot provide storage stats',
    () async {
      final gateway = FileCachePlatformGateway(
        channel: channel,
        scanEvents: scanEvents,
        isAndroid: () => false,
      );
      final service = StorageUsageService(
        fileCacheGateway: gateway,
        libraryTracks: () => const <MusicTrack>[],
      );

      final snapshot = await service.load();

      expect(snapshot.isAvailable, isFalse);
    },
  );

  test(
    'adds persistent covers to platform cache without double counting',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        return <String, Object?>{
          'ok': true,
          'value': <String, Object?>{
            'totalBytes': 1000,
            'availableBytes': 500,
            'cacheBytes': 100,
          },
        };
      });
      final service = StorageUsageService(
        fileCacheGateway: FileCachePlatformGateway(
          channel: channel,
          scanEvents: scanEvents,
          isAndroid: () => true,
        ),
        libraryTracks: () => const <MusicTrack>[],
        persistentCoverCacheBytes: () async => 25,
      );

      final snapshot = await service.load();

      expect(snapshot.applicationCacheBytes, 125);
      expect(snapshot.otherUsedBytes, 375);
    },
  );
}
