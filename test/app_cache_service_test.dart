import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/services/app_cache_service.dart';

void main() {
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
}
