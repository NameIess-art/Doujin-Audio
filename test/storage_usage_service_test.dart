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
          'storageRoots': <String>['/audio'],
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
      cacheBytes: () async => 500,
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

  test('counts only documents and files on the reported volume', () async {
    const primaryDocuments =
        'content://com.android.externalstorage.documents/tree/primary%3A';
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => {
        'ok': true,
        'value': {
          'totalBytes': 1000,
          'availableBytes': 400,
          'storageRoots': ['/storage/emulated/0', '/sdcard', primaryDocuments],
        },
      },
    );
    final service = StorageUsageService(
      fileCacheGateway: FileCachePlatformGateway(
        channel: channel,
        isAndroid: () => true,
      ),
      cacheBytes: () async => 100,
      libraryTracks: () => [
        track('/storage/emulated/0/Music/a.mp3', 50),
        track('/sdcard/Music/b.mp3', 50),
        track('$primaryDocuments/document/primary%3AMusic%2Fc.mp3', 50),
        track('$primaryDocuments::Music/d.mp3', 50),
        track(
          'content://com.android.externalstorage.documents/tree/1234-ABCD%3AMusic/document/1234-ABCD%3AMusic%2Fa.mp3',
          800,
        ),
        track('/storage/1234-ABCD/Music/a.mp3', 800),
        track('/storage/emulated/01/Music/a.mp3', 800),
        track('content://cloud.documents/document/primary%3AMusic', 800),
        track('https://example.com/a.mp3', 800),
      ],
    );

    final snapshot = await service.load();

    expect(snapshot.audioLibraryBytes, 200);
    expect(snapshot.applicationCacheBytes, 100);
    expect(snapshot.otherUsedBytes, 300);
  });

  test('unknown volume roots preserve cache and other used space', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => {
        'ok': true,
        'value': {'totalBytes': 1000, 'availableBytes': 400},
      },
    );
    final service = StorageUsageService(
      fileCacheGateway: FileCachePlatformGateway(
        channel: channel,
        isAndroid: () => true,
      ),
      cacheBytes: () async => 100,
      libraryTracks: () => [track('/unknown/a.mp3', 800)],
    );

    final snapshot = await service.load();

    expect(snapshot.audioLibraryBytes, 0);
    expect(snapshot.applicationCacheBytes, 100);
    expect(snapshot.otherUsedBytes, 500);
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

  test('uses shared cache accounting without native double counting', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      return <String, Object?>{
        'ok': true,
        'value': <String, Object?>{'totalBytes': 1000, 'availableBytes': 500},
      };
    });
    final service = StorageUsageService(
      fileCacheGateway: FileCachePlatformGateway(
        channel: channel,
        scanEvents: scanEvents,
        isAndroid: () => true,
      ),
      libraryTracks: () => const <MusicTrack>[],
      cacheBytes: () async => 125,
    );

    final snapshot = await service.load();

    expect(snapshot.applicationCacheBytes, 125);
    expect(snapshot.otherUsedBytes, 375);
  });
}
