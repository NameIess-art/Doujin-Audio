import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/media/cover_image_format.dart';
import 'package:doujin_audio/features/settings/application/app_cache_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
