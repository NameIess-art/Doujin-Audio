import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/media/cover_image_format.dart';
import 'package:doujin_audio/core/cache/app_cache_service.dart';
import 'package:doujin_audio/core/platform/file_cache_platform_gateway.dart';
import 'package:doujin_audio/core/platform/platform_channels.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Android cache limit initialization', () {
    const channel = MethodChannel('test/application_cache');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late List<String> calls;
    var failSetter = false;

    setUp(() {
      calls = <String>[];
      failSetter = false;
      AppCacheService.resetForTest(
        isAndroid: true,
        fileCache: FileCachePlatformGateway(
          channel: channel,
          isAndroid: () => true,
        ),
      );
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (failSetter &&
            call.method == FileCacheMethod.setApplicationCacheLimit) {
          return <String, Object?>{
            'ok': false,
            'code': 'cache_failure',
            'message': 'Cannot trim cache',
          };
        }
        return <String, Object?>{'ok': true, 'value': null};
      });
    });

    tearDown(() {
      AppCacheService.resetForTest();
      messenger.setMockMethodCallHandler(channel, null);
    });

    test(
      'successful setter trims once and cancels pending enforcement',
      () async {
        AppCacheService.scheduleEnforce(
          idleDelay: const Duration(milliseconds: 10),
        );
        await AppCacheService.setMaxCacheBytes(100);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(calls, <String>[FileCacheMethod.setApplicationCacheLimit]);
      },
    );

    test('failed native setter retains the enforcement retry', () async {
      failSetter = true;
      await AppCacheService.setMaxCacheBytes(100);
      expect(calls, <String>[
        FileCacheMethod.setApplicationCacheLimit,
        FileCacheMethod.enforceApplicationCacheLimit,
      ]);
    });

    test('active lease defers native trimming until release', () async {
      final lease = AppCacheService.protectPaths(<String>['/active/cache']);
      await AppCacheService.setMaxCacheBytes(
        AppCacheService.defaultMaxCacheBytes,
      );
      expect(calls, isEmpty);
      lease.release();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(calls, <String>[FileCacheMethod.enforceApplicationCacheLimit]);
    });

    test('short leases retain scheduled enforcement debounce', () async {
      for (var index = 0; index < 3; index++) {
        final lease = AppCacheService.protectPaths(['/active/$index']);
        AppCacheService.scheduleEnforce(
          idleDelay: const Duration(milliseconds: 100),
          maxDelay: const Duration(seconds: 1),
        );
        lease.release();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(calls, isEmpty);
      }
      await Future<void>.delayed(const Duration(milliseconds: 130));
      expect(calls, [FileCacheMethod.enforceApplicationCacheLimit]);
    });

    test('a new lease preserves the scheduled maximum delay', () async {
      AppCacheService.scheduleEnforce(
        idleDelay: const Duration(seconds: 1),
        maxDelay: const Duration(milliseconds: 40),
      );
      final lease = AppCacheService.protectPaths(['/active/cache']);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(calls, isEmpty);
      lease.release();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(calls, [FileCacheMethod.enforceApplicationCacheLimit]);
    });

    test(
      'explicit enforcement supersedes a deferred scheduled request',
      () async {
        final lease = AppCacheService.protectPaths(['/active/cache']);
        AppCacheService.scheduleEnforce();
        await AppCacheService.enforceLimit();
        expect(calls, isEmpty);
        lease.release();
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(calls, [FileCacheMethod.enforceApplicationCacheLimit]);
      },
    );
  });

  test(
    'orphaned persistent imports are deleted without removing live files',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'persistent_import_cleanup_',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final retained = File(
        '${directory.path}${Platform.pathSeparator}live.flac',
      );
      final orphan = File(
        '${directory.path}${Platform.pathSeparator}orphan.flac',
      );
      await retained.writeAsBytes(<int>[1, 2, 3]);
      await orphan.writeAsBytes(<int>[4, 5, 6, 7]);

      final deletedBytes =
          await AppCacheService.cleanupOrphanedPersistentImports(<String>[
            retained.path,
          ], importDirectory: directory);

      expect(deletedBytes, 4);
      expect(await retained.exists(), isTrue);
      expect(await orphan.exists(), isFalse);
    },
  );

  test('cache clearing skips files protected by an active lease', () async {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    final tempDirectory = await Directory.systemTemp.createTemp(
      'protected_cache_cleanup_',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getTemporaryDirectory') {
            return tempDirectory.path;
          }
          return null;
        });
    addTearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      if (await tempDirectory.exists()) {
        await tempDirectory.delete(recursive: true);
      }
    });

    final cacheDirectory = Directory(
      '${tempDirectory.path}${Platform.pathSeparator}asmr_downloads',
    );
    await cacheDirectory.create(recursive: true);
    final protected = File(
      '${cacheDirectory.path}${Platform.pathSeparator}active.part',
    );
    final orphan = File(
      '${cacheDirectory.path}${Platform.pathSeparator}orphan.part',
    );
    await protected.writeAsBytes(<int>[1, 2, 3]);
    await orphan.writeAsBytes(<int>[4, 5]);
    final lease = AppCacheService.protectPaths(<String>[protected.path]);

    try {
      await AppCacheService.clearAllCaches();
      expect(await protected.exists(), isTrue);
      expect(await orphan.exists(), isFalse);
    } finally {
      lease.release();
    }
  });

  test(
    'translation cache is counted and cleared without deleting source files',
    () async {
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      final tempDirectory = await Directory.systemTemp.createTemp(
        'translation_cache_cleanup_',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'getTemporaryDirectory') return tempDirectory.path;
        return null;
      });
      addTearDown(() async {
        messenger.setMockMethodCallHandler(channel, null);
        if (await tempDirectory.exists()) {
          await tempDirectory.delete(recursive: true);
        }
      });
      final cacheDirectory = Directory(
        '${tempDirectory.path}${Platform.pathSeparator}page_translations',
      );
      await cacheDirectory.create();
      final cache = File(
        '${cacheDirectory.path}${Platform.pathSeparator}cache.json',
      );
      await cache.writeAsBytes(List<int>.filled(23, 1));
      final source = File(
        '${tempDirectory.path}${Platform.pathSeparator}source.txt',
      );
      await source.writeAsString('source');

      expect(await AppCacheService.estimateDartCacheBytes(), 23);
      await AppCacheService.clearAllCaches();

      expect(await cache.exists(), isFalse);
      expect(await AppCacheService.estimateDartCacheBytes(), 0);
      expect(await source.readAsString(), 'source');
    },
  );

  test('scheduled cache enforcement coalesces repeated requests', () async {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    final tempDirectory = await Directory.systemTemp.createTemp(
      'scheduled_cache_enforcement_',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getTemporaryDirectory') {
            return tempDirectory.path;
          }
          return null;
        });
    addTearDown(() async {
      await AppCacheService.setMaxCacheBytes(
        AppCacheService.defaultMaxCacheBytes,
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      if (await tempDirectory.exists()) {
        await tempDirectory.delete(recursive: true);
      }
    });
    await AppCacheService.setMaxCacheBytes(5);
    final cacheDirectory = Directory(
      '${tempDirectory.path}${Platform.pathSeparator}video_frames',
    );
    await cacheDirectory.create(recursive: true);
    for (var index = 0; index < 3; index++) {
      await File(
        '${cacheDirectory.path}${Platform.pathSeparator}$index.jpg',
      ).writeAsBytes(List<int>.filled(4, index));
    }

    for (var index = 0; index < 10; index++) {
      AppCacheService.scheduleEnforce(
        idleDelay: const Duration(milliseconds: 10),
        maxDelay: const Duration(milliseconds: 40),
      );
    }
    final activeLease = AppCacheService.protectPaths(<String>[
      '${cacheDirectory.path}${Platform.pathSeparator}0.jpg',
    ]);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(await AppCacheService.estimateDartCacheBytes(), 12);
    activeLease.release();
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(
      await AppCacheService.estimateDartCacheBytes(),
      lessThanOrEqualTo(4),
    );
  });

  test('enforces cache limit when one file alone is oversized', () async {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    final tempDirectory = await Directory.systemTemp.createTemp(
      'single_oversized_cache_',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getTemporaryDirectory') {
            return tempDirectory.path;
          }
          return null;
        });
    addTearDown(() async {
      await AppCacheService.setMaxCacheBytes(
        AppCacheService.defaultMaxCacheBytes,
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      if (await tempDirectory.exists()) {
        await tempDirectory.delete(recursive: true);
      }
    });

    await AppCacheService.setMaxCacheBytes(5);
    final cacheDirectory = Directory(
      '${tempDirectory.path}${Platform.pathSeparator}video_frames',
    );
    await cacheDirectory.create(recursive: true);
    final oversized = File(
      '${cacheDirectory.path}${Platform.pathSeparator}oversized.jpg',
    );
    await oversized.writeAsBytes(List<int>.filled(12, 1));

    await AppCacheService.enforceLimit();

    expect(await oversized.exists(), isFalse);
    expect(await AppCacheService.estimateDartCacheBytes(), 0);
  });

  test(
    'persistent covers are excluded from limits and removed by manual clear',
    () async {
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      final tempDirectory = await Directory.systemTemp.createTemp(
        'persistent_cover_temp_',
      );
      final supportDirectory = await Directory.systemTemp.createTemp(
        'persistent_cover_support_',
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'getTemporaryDirectory') {
              return tempDirectory.path;
            }
            if (call.method == 'getApplicationSupportDirectory') {
              return supportDirectory.path;
            }
            return null;
          });
      addTearDown(() async {
        await AppCacheService.setMaxCacheBytes(
          AppCacheService.defaultMaxCacheBytes,
        );
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        if (await tempDirectory.exists()) {
          await tempDirectory.delete(recursive: true);
        }
        if (await supportDirectory.exists()) {
          await supportDirectory.delete(recursive: true);
        }
      });
      await AppCacheService.setMaxCacheBytes(5);
      final coverDirectory = Directory(
        '${supportDirectory.path}${Platform.pathSeparator}'
        '$legacyRemoteCoverCacheDirectoryName',
      );
      await coverDirectory.create(recursive: true);
      final cover = File(
        '${coverDirectory.path}${Platform.pathSeparator}cover.image',
      );
      await cover.writeAsBytes(List<int>.filled(12, 1));
      final storeDirectory = Directory(
        '${supportDirectory.path}${Platform.pathSeparator}'
        '$coverArtworkStoreDirectoryName${Platform.pathSeparator}generated',
      );
      await storeDirectory.create(recursive: true);
      final persistedCover = File(
        '${storeDirectory.path}${Platform.pathSeparator}cover.image',
      );
      await persistedCover.writeAsBytes(List<int>.filled(13, 1));

      await AppCacheService.enforceLimit();

      expect(await cover.exists(), isTrue);
      expect(await persistedCover.exists(), isTrue);
      expect(await AppCacheService.estimateDartCacheBytes(), 25);
      expect(await AppCacheService.estimatePersistentCoverCacheBytes(), 13);

      await AppCacheService.clearAllCaches();

      expect(await cover.exists(), isFalse);
      expect(await persistedCover.exists(), isFalse);
    },
  );
}
