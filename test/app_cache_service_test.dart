import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:doujin_audio/core/cache/app_cache_service.dart';
import 'package:doujin_audio/core/media/cover_image_format.dart';
import 'package:doujin_audio/core/media/path_matcher.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory workspace;
  late Directory temporary;
  late Directory external;
  late Directory support;

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('application_cache_');
    temporary = await Directory(path.join(workspace.path, 'temp')).create();
    external = await Directory(path.join(workspace.path, 'external')).create();
    support = await Directory(path.join(workspace.path, 'support')).create();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getTemporaryDirectory') return temporary.path;
      if (call.method == 'getApplicationSupportDirectory') return support.path;
      return null;
    });
    AppCacheService.resetForTest(
      temporaryDirectories: () async => [temporary, external, temporary],
    );
  });

  tearDown(() async {
    await AppCacheService.enforceLimit();
    AppCacheService.resetForTest();
    messenger.setMockMethodCallHandler(channel, null);
    await workspace.delete(recursive: true);
  });

  Future<File> file(Directory parent, String relative, int bytes) async {
    final result = File(path.join(parent.path, relative));
    await result.parent.create(recursive: true);
    await result.writeAsBytes(List<int>.filled(bytes, 1));
    return result;
  }

  test(
    'concurrent usage estimates share one scan without retaining results',
    () async {
      final cached = await file(temporary, 'exports/cache.bin', 7);
      final entered = Completer<void>();
      final resume = Completer<void>();
      var scans = 0;
      AppCacheService.resetForTest(
        temporaryDirectories: () async {
          scans++;
          if (scans == 1) {
            entered.complete();
            await resume.future;
          }
          return [temporary];
        },
      );
      final first = AppCacheService.estimateCacheBytes();
      await entered.future;
      final concurrent = List.generate(
        10,
        (_) => AppCacheService.estimateCacheBytes(),
      );
      resume.complete();
      expect(await first, 7);
      expect(await Future.wait(concurrent), everyElement(7));
      expect(scans, 1);
      await cached.writeAsBytes(List.filled(11, 1));
      expect(await AppCacheService.estimateCacheBytes(), 11);
      expect(scans, 2);
    },
  );

  test('usage requested after clear cannot join the pre-clear scan', () async {
    await file(temporary, 'exports/cache.bin', 12);
    final scanEntered = Completer<void>();
    final resumeScan = Completer<void>();
    final deleteEntered = Completer<void>();
    final resumeDelete = Completer<void>();
    var rootRequests = 0;
    AppCacheService.resetForTest(
      temporaryDirectories: () async {
        if (++rootRequests == 1) {
          scanEntered.complete();
          await resumeScan.future;
        }
        return [temporary];
      },
      beforeDelete: (_) async {
        deleteEntered.complete();
        await resumeDelete.future;
      },
    );
    final beforeClear = AppCacheService.estimateCacheBytes();
    await scanEntered.future;
    final clear = AppCacheService.clearTemporaryCaches();
    await deleteEntered.future;
    final afterClear = AppCacheService.estimateCacheBytes();
    resumeScan.complete();
    expect(await beforeClear, 12);
    resumeDelete.complete();
    expect(await clear, 12);
    expect(await afterClear, 0);
    expect(rootRequests, 3);
  });

  test(
    'counts shared managed roots once and keeps unregistered data',
    () async {
      await file(temporary, 'page_translations/cache.json', 7);
      await file(external, 'asmr_subtitles/remote.srt', 11);
      final source = await file(temporary, 'source.txt', 13);
      final authored = await file(support, 'imported_subtitles/user.srt', 17);
      expect(await AppCacheService.estimateCacheBytes(), 18);
      expect(await AppCacheService.clearTemporaryCaches(), 18);
      expect(await source.exists(), isTrue);
      expect(await authored.exists(), isTrue);
    },
  );

  test(
    'persistent artwork is counted but never deleted by temporary maintenance',
    () async {
      final legacy = await file(
        support,
        '$legacyRemoteCoverCacheDirectoryName/cover.image',
        12,
      );
      final artwork = await file(
        support,
        '$coverArtworkStoreDirectoryName/generated/cover.image',
        13,
      );
      await AppCacheService.setMaxCacheBytes(5);
      await AppCacheService.clearTemporaryCaches();
      expect(await legacy.exists(), isTrue);
      expect(await artwork.exists(), isTrue);
      expect(await AppCacheService.estimateCacheBytes(), 25);
    },
  );

  test('one oversized unprotected file is evicted', () async {
    final large = await file(temporary, 'video_frames/large.jpg', 12);
    await AppCacheService.setMaxCacheBytes(5);
    expect(await large.exists(), isFalse);
    expect(await AppCacheService.estimateCacheBytes(), 0);
  });

  test('evicts oldest first and leaves ten percent capacity', () async {
    final oldest = await file(temporary, 'exports/old.zip', 6);
    final newer = await file(temporary, 'exports/new.zip', 4);
    final newest = await file(temporary, 'exports/newest.zip', 2);
    await oldest.setLastModified(DateTime(2020));
    await newer.setLastModified(DateTime(2021));
    await newest.setLastModified(DateTime(2022));
    await AppCacheService.setMaxCacheBytes(10);
    expect(await oldest.exists(), isFalse);
    expect(await newer.exists(), isTrue);
    expect(await newest.exists(), isTrue);
    expect(await AppCacheService.estimateCacheBytes(), 6);
  });

  test('lease acquired after scan is checked again before deleting', () async {
    final active = await file(temporary, 'asmr_playback_cache/active.flac', 12);
    CachePathLease? lease;
    AppCacheService.resetForTest(
      temporaryDirectories: () async => [temporary],
      beforeDelete: (candidate) async {
        if (PathMatcher.equalsNormalized(candidate, active.path)) {
          lease ??= AppCacheService.protectPaths([candidate]);
        }
      },
    );
    await AppCacheService.setMaxCacheBytes(5);
    expect(await active.exists(), isTrue);
    lease!.release();
    AppCacheService.resetForTest(temporaryDirectories: () async => [temporary]);
    expect(await AppCacheService.clearTemporaryCaches(), 12);
  });

  test(
    'protected bytes count toward the limit without entering eviction',
    () async {
      final active = await file(
        temporary,
        'asmr_playback_cache/active.flac',
        8,
      );
      final first = await file(temporary, 'exports/first.bin', 4);
      final second = await file(temporary, 'exports/second.bin', 4);
      final deletedCandidates = <String>[];
      AppCacheService.resetForTest(
        temporaryDirectories: () async => [temporary],
        beforeDelete: (candidate) async => deletedCandidates.add(candidate),
      );
      final lease = AppCacheService.protectPaths([active.path]);
      await AppCacheService.setMaxCacheBytes(10);
      expect(await active.exists(), isTrue);
      expect(await first.exists(), isFalse);
      expect(await second.exists(), isFalse);
      expect(
        deletedCandidates.map(PathMatcher.equivalenceKey),
        unorderedEquals(
          [first, second].map((file) => PathMatcher.equivalenceKey(file.path)),
        ),
      );
      expect(await AppCacheService.estimateCacheBytes(), 8);
      lease.release();
    },
  );

  test(
    'lease released during eviction schedules skipped files for retry',
    () async {
      final active = await file(
        temporary,
        'asmr_playback_cache/active.flac',
        8,
      );
      final orphan = await file(temporary, 'exports/orphan.bin', 4);
      final activeDeleteEntered = Completer<void>();
      late CachePathLease lease;
      AppCacheService.resetForTest(
        temporaryDirectories: () async => [temporary],
        beforeDelete: (candidate) async {
          if (PathMatcher.equalsNormalized(candidate, orphan.path)) {
            lease.release();
          } else if (PathMatcher.equalsNormalized(candidate, active.path)) {
            activeDeleteEntered.complete();
          }
        },
      );
      lease = AppCacheService.protectPaths([active.path]);
      await AppCacheService.setMaxCacheBytes(5);
      expect(await orphan.exists(), isFalse);
      await activeDeleteEntered.future.timeout(const Duration(seconds: 5));
      await AppCacheService.enforceLimit();
      expect(await active.exists(), isFalse);
    },
  );

  test(
    'overlapping and shared leases survive clear until every owner releases',
    () async {
      final active = await file(temporary, 'asmr_downloads/active.part', 3);
      final orphan = await file(temporary, 'asmr_downloads/orphan.part', 5);
      final directoryLease = AppCacheService.protectPaths([active.parent.path]);
      final first = AppCacheService.protectPaths([active.path]);
      final second = AppCacheService.protectPaths([
        Platform.isWindows ? active.path.toUpperCase() : active.path,
      ]);
      await AppCacheService.clearTemporaryCaches();
      expect(await active.exists(), isTrue);
      directoryLease.release();
      first.release();
      first.release();
      expect(await AppCacheService.clearTemporaryCaches(), 5);
      expect(await orphan.exists(), isFalse);
      expect(await active.exists(), isTrue);
      second.release();
      expect(await AppCacheService.clearTemporaryCaches(), 3);
    },
  );

  test('clear requests coalesce and serialize with enforcement', () async {
    final entry = await file(temporary, 'updates/update.part', 12);
    final entered = Completer<void>();
    final resume = Completer<void>();
    var deletions = 0;
    AppCacheService.resetForTest(
      temporaryDirectories: () async => [temporary],
      beforeDelete: (_) async {
        deletions++;
        entered.complete();
        await resume.future;
      },
    );
    final first = AppCacheService.clearTemporaryCaches();
    final second = AppCacheService.clearTemporaryCaches();
    expect(identical(first, second), isTrue);
    await entered.future;
    final enforce = AppCacheService.enforceLimit();
    resume.complete();
    expect(await first, 12);
    await enforce;
    expect(deletions, 1);
    expect(await entry.exists(), isFalse);
  });

  test(
    'scheduled enforcement runs during a lease and preserves only protected files',
    () async {
      await AppCacheService.setMaxCacheBytes(5, enforceImmediately: false);
      final active = await file(temporary, 'asmr_downloads/active.part', 4);
      final orphan = await file(temporary, 'asmr_downloads/orphan.part', 4);
      final lease = AppCacheService.protectPaths([active.path]);
      final deleted = Completer<void>();
      AppCacheService.resetForTest(
        temporaryDirectories: () async => [temporary],
        beforeDelete: (candidate) async {
          if (PathMatcher.equalsNormalized(candidate, orphan.path) &&
              !deleted.isCompleted) {
            deleted.complete();
          }
        },
      );
      lease.release();
      final activeLease = AppCacheService.protectPaths([active.path]);
      await AppCacheService.setMaxCacheBytes(5, enforceImmediately: false);
      for (var i = 0; i < 10; i++) {
        AppCacheService.scheduleEnforce(
          idleDelay: const Duration(milliseconds: 10),
        );
      }
      await deleted.future.timeout(const Duration(seconds: 5));
      await AppCacheService.enforceLimit();
      expect(await active.exists(), isTrue);
      expect(await orphan.exists(), isFalse);
      activeLease.release();
    },
  );

  test('orphan import cleanup preserves retained files', () async {
    final imports = await Directory(
      path.join(support.path, 'imports'),
    ).create();
    final retained = await file(imports, 'live.flac', 3);
    final orphan = await file(imports, 'old.flac', 4);
    expect(
      await AppCacheService.cleanupOrphanedPersistentImports([
        retained.path,
      ], importDirectory: imports),
      4,
    );
    expect(await retained.exists(), isTrue);
    expect(await orphan.exists(), isFalse);
  });

  test('directory links are not scanned or followed by cleanup', () async {
    final outside = await Directory(
      path.join(workspace.path, 'outside'),
    ).create();
    final original = await file(outside, 'original.bin', 9);
    final root = await Directory(path.join(temporary.path, 'exports')).create();
    final link = Link(path.join(root.path, 'linked'));
    try {
      await link.create(outside.path);
    } on FileSystemException {
      // Windows requires Developer Mode or elevated rights to create links.
      return;
    }
    expect(await AppCacheService.estimateCacheBytes(), 0);
    await AppCacheService.clearTemporaryCaches();
    expect(await original.exists(), isTrue);
  });
}
