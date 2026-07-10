import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/services/app_cache_service.dart';

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
}
