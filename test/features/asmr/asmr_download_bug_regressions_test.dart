import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:doujin_audio/core/media/playback_media_reference.dart';
import 'package:doujin_audio/core/persistence/json_document_store.dart';
import 'package:doujin_audio/core/platform/file_cache_platform_gateway.dart';
import 'package:doujin_audio/features/asmr/application/asmr_download_cleanup.dart';
import 'package:doujin_audio/features/asmr/application/asmr_download_internal_models.dart';
import 'package:doujin_audio/features/asmr/application/asmr_download_io.dart';
import 'package:doujin_audio/features/asmr/application/asmr_download_manager.dart';
import 'package:doujin_audio/features/asmr/application/asmr_download_planner.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_download.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

AsmrWork _testWork({
  required int id,
  required String title,
  String rjCode = '',
  String circleName = 'Circle',
  List<String> voiceActors = const <String>[],
}) => AsmrWork(
  id: id,
  title: title,
  circleName: circleName,
  sourceId: rjCode.isEmpty ? 'RJ${id.toString().padLeft(6, '0')}' : rjCode,
  sourceType: 'asmr-one',
  sourceUrl: '',
  coverUrl: '',
  thumbnailUrl: '',
  mainCoverUrl: '',
  releaseDate: null,
  createDate: null,
  duration: Duration.zero,
  dlCount: 0,
  reviewCount: 0,
  rating: 0,
  voiceActors: voiceActors,
  tags: const <String>[],
);

AsmrTrackFile _audioNode({
  required int workId,
  required String title,
  required String relativePath,
  required String url,
  String? streamUrl,
  int size = 0,
}) => AsmrTrackFile(
  hash: '${workId}_$relativePath',
  title: title,
  type: 'audio',
  streamUrl: streamUrl ?? url,
  downloadUrl: url,
  lowQualityUrl: null,
  duration: const Duration(seconds: 5),
  size: size,
  children: const <AsmrTrackFile>[],
  workId: workId,
  workTitle: 'Work $workId',
  sourceId: 'RJ${workId.toString().padLeft(6, '0')}',
  relativePath: relativePath,
);

void main() {
  group('#8 download path truncation and Windows long-path safety', () {
    const planner = AsmrDownloadPlanner();

    test(
      'buildAsmrDownloadWorkFolderName enforces code-unit caps without collisions or broken surrogates',
      () {
        final japanesePrefix = 'あ' * 130;
        final first = _testWork(id: 1, title: '$japanesePrefix前編');
        final second = _testWork(id: 2, title: '$japanesePrefix後編');

        final firstName = buildAsmrDownloadWorkFolderName(first, const [
          AsmrDownloadFolderNameField.workTitle,
        ]);
        final secondName = buildAsmrDownloadWorkFolderName(second, const [
          AsmrDownloadFolderNameField.workTitle,
        ]);

        expect(
          firstName.length,
          lessThanOrEqualTo(kMaxAsmrDownloadWorkFolderNameLength),
        );
        expect(firstName, isNot(equals(secondName)));
        expect(
          buildAsmrDownloadWorkFolderName(first, const [
            AsmrDownloadFolderNameField.workTitle,
          ]),
          equals(firstName),
        );

        final emojiTitle = '${'🎧' * 70}末';
        final emojiName = buildAsmrDownloadWorkFolderName(
          _testWork(id: 3, title: emojiTitle),
          const [AsmrDownloadFolderNameField.workTitle],
        );
        expect(
          emojiName.length,
          lessThanOrEqualTo(kMaxAsmrDownloadWorkFolderNameLength),
        );
        // Valid UTF-16: round-tripping through runes must preserve exact string.
        expect(String.fromCharCodes(emojiName.runes), equals(emojiName));
      },
    );

    test(
      'windowsLocalRelativePath caps segments, preserves extensions, avoids collisions, and keeps parent-child prefix consistency',
      () {
        final longFolderA = 'フォルダ_${'長' * 140}';
        final longFolderB = 'サブ_${'深' * 140}';
        final longTrack1 = '${'トラック' * 50}_01.flac';
        final longTrack2 = '${'トラック' * 50}_02.flac';

        final dirOnly = planner.windowsLocalRelativePath(
          '$longFolderA/$longFolderB',
        );
        final file1 = planner.windowsLocalRelativePath(
          '$longFolderA/$longFolderB/$longTrack1',
        );
        final file2 = planner.windowsLocalRelativePath(
          '$longFolderA/$longFolderB/$longTrack2',
        );

        expect(file1.startsWith('$dirOnly/'), isTrue);
        expect(file2.startsWith('$dirOnly/'), isTrue);
        expect(file1, isNot(equals(file2)));
        expect(file1, endsWith('.flac'));
        expect(file2, endsWith('.flac'));
        expect(
          file1.length,
          lessThanOrEqualTo(
            AsmrDownloadPlanner.kSoftWindowsRelativePathBudget +
                1 +
                AsmrDownloadPlanner.kMinWindowsSegmentLength,
          ),
        );
        for (final segment in file1.split('/')) {
          expect(
            segment.length + '.doujin.part.etag'.length,
            lessThanOrEqualTo(255),
          );
          expect(
            segment.length,
            lessThanOrEqualTo(AsmrDownloadPlanner.kMaxWindowsSegmentLength),
          );
        }
      },
    );

    test(
      'windowsExtendedLocalPath applies extended prefix only to long Windows drive and UNC paths',
      () {
        const shortDrive = r'C:\Downloads\Work\track.mp3';
        expect(
          windowsExtendedLocalPath(shortDrive, forceWindows: true),
          shortDrive,
        );

        final longDrive = 'C:\\Downloads\\${'a' * 120}\\${'b' * 120}\\track.mp3';
        final extendedDrive = windowsExtendedLocalPath(
          longDrive,
          forceWindows: true,
        );
        expect(extendedDrive, r'\\?\' + longDrive);
        expect(stripWindowsExtendedLocalPath(extendedDrive), longDrive);
        expect(
          windowsExtendedLocalPath(extendedDrive, forceWindows: true),
          extendedDrive,
        );

        final longUnc = '\\\\server\\share\\${'a' * 120}\\${'b' * 120}\\track.mp3';
        final extendedUnc = windowsExtendedLocalPath(
          longUnc,
          forceWindows: true,
        );
        expect(extendedUnc, r'\\?\UNC\' + longUnc.substring(2));
        expect(stripWindowsExtendedLocalPath(extendedUnc), longUnc);
      },
    );

    test(
      'localDownloadFile and commitLocalDownloadedFile succeed for >260 char paths on Windows',
      () async {
        final root = await Directory.systemTemp.createTemp('asmr_long_path_');
        addTearDown(() async {
          final extendedRoot = localDownloadDirectory(root.path);
          if (await extendedRoot.exists()) {
            await extendedRoot.delete(recursive: true);
          }
        });

        final deepLogicalDir = path.join(
          root.path,
          'dir_${'a' * 80}',
          'sub_${'b' * 80}',
          'leaf_${'c' * 80}',
        );
        final logicalTarget = path.join(deepLogicalDir, 'track_01.mp3');
        final logicalStaging = '$logicalTarget.doujin.part';
        expect(logicalTarget.length, greaterThan(260));

        await localDownloadDirectory(deepLogicalDir).create(recursive: true);
        await localDownloadFile(logicalTarget).writeAsString('old-data');
        await localDownloadFile(logicalStaging).writeAsString('new-data');

        final committed = await commitLocalDownloadedFile(
          staging: File(logicalStaging),
          target: File(logicalTarget),
        );
        expect(committed, isTrue);
        expect(await localDownloadFile(logicalTarget).readAsString(), 'new-data');
        expect(await localDownloadFile(logicalStaging).exists(), isFalse);
        expect(
          await localDownloadFile('$logicalTarget.doujin.bak').exists(),
          isFalse,
        );
      },
      skip: !Platform.isWindows,
    );
  });

  test(
    '#31 cancelling a queued task with deleteDownloaded removes previously downloaded outputs',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      final firstPartStarted = Completer<void>();
      final releaseFirstPart = Completer<void>();
      final blockerStarted = Completer<void>();
      final releaseBlocker = Completer<void>();

      server.listen((request) async {
        if (request.uri.path == '/work1/done.mp3') {
          request.response.statusCode = HttpStatus.ok;
          request.response.add(utf8.encode('already-downloaded-bytes'));
          await request.response.close();
          return;
        }
        if (request.uri.path == '/work1/pending.mp3') {
          if (!firstPartStarted.isCompleted) firstPartStarted.complete();
          request.response.statusCode = HttpStatus.ok;
          request.response.add(utf8.encode('partial-chunk'));
          await request.response.flush();
          await releaseFirstPart.future;
          await request.response.close();
          return;
        }
        if (request.uri.path == '/work2/blocker.mp3') {
          if (!blockerStarted.isCompleted) blockerStarted.complete();
          request.response.statusCode = HttpStatus.ok;
          request.response.add(utf8.encode('blocking'));
          await request.response.flush();
          await releaseBlocker.future;
          await request.response.close();
          return;
        }
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      });

      final tempRoot = await Directory.systemTemp.createTemp('asmr_bug31_');
      addTearDown(() async {
        if (await tempRoot.exists()) {
          await tempRoot.delete(recursive: true);
        }
      });

      final manager = AsmrDownloadManager(
        maxConcurrentDownloads: 1,
        persistTasks: false,
        temporaryDirectoryProvider: () async => tempRoot,
        automaticFileRetryDelay: const Duration(milliseconds: 10),
      );
      addTearDown(() async {
        if (!releaseFirstPart.isCompleted) releaseFirstPart.complete();
        if (!releaseBlocker.isCompleted) releaseBlocker.complete();
        await manager.shutdown();
      });

      final baseUrl = 'http://127.0.0.1:${server.port}';
      final work1 = _testWork(id: 3101, title: 'Work1');
      final work2 = _testWork(id: 3102, title: 'Work2');

      await manager.startDownload(
        work: work1,
        selectedRoots: [
          _audioNode(
            workId: 3101,
            title: 'done.mp3',
            relativePath: 'done.mp3',
            url: '$baseUrl/work1/done.mp3',
            size: 'already-downloaded-bytes'.length,
          ),
          _audioNode(
            workId: 3101,
            title: 'pending.mp3',
            relativePath: 'pending.mp3',
            url: '$baseUrl/work1/pending.mp3',
            size: 1024,
          ),
        ],
        destinationRoot: tempRoot.path,
        conflictPolicy: AsmrDownloadConflictPolicy.overwrite,
        saveMetadata: false,
        saveCover: false,
      );

      final doneCommitted = Completer<void>();
      final sub = manager.taskStream(work1.workKey).listen((snapshot) {
        if (snapshot?.completedFilePaths.contains('done.mp3') == true &&
            !doneCommitted.isCompleted) {
          doneCommitted.complete();
        }
      });
      addTearDown(sub.cancel);

      await Future.wait([firstPartStarted.future, doneCommitted.future]);
      // Pause work1 after done.mp3 has committed and pending.mp3 is mid-flight.
      await manager.pauseTask(work1.workKey);
      final doneFile = File(path.join(tempRoot.path, 'Work1', 'done.mp3'));
      expect(await doneFile.exists(), isTrue);

      // Occupy the single download slot with work2.
      await manager.startDownload(
        work: work2,
        selectedRoots: [
          _audioNode(
            workId: 3102,
            title: 'blocker.mp3',
            relativePath: 'blocker.mp3',
            url: '$baseUrl/work2/blocker.mp3',
            size: 1024,
          ),
        ],
        destinationRoot: tempRoot.path,
        conflictPolicy: AsmrDownloadConflictPolicy.overwrite,
        saveMetadata: false,
        saveCover: false,
      );
      await blockerStarted.future;

      // Re-enqueue work1 while the single slot is occupied by work2.
      await manager.resumeTask(work1.workKey);
      expect(manager.getTask(work1.workKey)?.status, AsmrDownloadTaskStatus.idle);

      // Cancelling the queued task with deleteDownloaded: true must delete done.mp3.
      await manager.cancelTask(work1.workKey);
      expect(manager.getTask(work1.workKey), isNull);
      expect(await doneFile.exists(), isFalse);
    },
  );

  test(
    '#57 transfer attaches media headers from resolvedUrl rather than item.url',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      String? seenReferer;
      server.listen((request) async {
        seenReferer = request.headers.value(HttpHeaders.refererHeader);
        request.response.statusCode = HttpStatus.ok;
        // Valid ID3 header so validateAsmrAudioFile accepts the downloaded file.
        request.response.add(<int>[0x49, 0x44, 0x33, 0x03, 0x00, 0x00, 0x00, 0x00]);
        await request.response.close();
      });

      final tempRoot = await Directory.systemTemp.createTemp('asmr_bug57_');
      addTearDown(() async {
        if (await tempRoot.exists()) {
          await tempRoot.delete(recursive: true);
        }
      });

      final manager = AsmrDownloadManager(
        maxConcurrentDownloads: 1,
        persistTasks: false,
        temporaryDirectoryProvider: () async => tempRoot,
      );
      addTearDown(manager.shutdown);

      final resolvedOriginalUrl = 'http://127.0.0.1:${server.port}/direct.mp3';
      final hlsStreamWithOriginal = PlaybackMediaReference(
        streamUrl: 'https://v.weeab0o.xyz/work/playlist.m3u8',
        endMs: 5000,
        fileName: 'track.mp3',
        downloadUrl: resolvedOriginalUrl,
      ).logicalUrl;
      expect(
        PlaybackMediaReference.parse(hlsStreamWithOriginal).downloadUrl,
        resolvedOriginalUrl,
      );
      expect(
        asmrMediaRequestHeadersForUrl('https://v.weeab0o.xyz/work/playlist.m3u8'),
        containsPair('Referer', 'https://japaneseasmr.com/'),
      );

      final work = _testWork(id: 5701, title: 'Work57');
      final completed = Completer<AsmrDownloadTaskSnapshot>();
      final sub = manager.completedTasks.listen((task) {
        if (!completed.isCompleted) completed.complete(task);
      });
      addTearDown(sub.cancel);

      await manager.startDownload(
        work: work,
        selectedRoots: [
          _audioNode(
            workId: 5701,
            title: 'track.mp3',
            relativePath: 'track.mp3',
            url: hlsStreamWithOriginal,
            streamUrl: hlsStreamWithOriginal,
            size: 8,
          ),
        ],
        destinationRoot: tempRoot.path,
        conflictPolicy: AsmrDownloadConflictPolicy.overwrite,
        saveMetadata: false,
        saveCover: false,
      );

      await completed.future.timeout(const Duration(seconds: 5));
      expect(seenReferer, isNull);
    },
  );

  test(
    'M26 resuming after a completed file is deleted does not double-count downloadedBytes',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      final payload = List<int>.filled(16, 0x41);
      final part2Started = Completer<void>();
      final releasePart2 = Completer<void>();
      var failPart2 = false;

      server.listen((request) async {
        if (request.uri.path == '/file1.mp3') {
          request.response.statusCode = HttpStatus.ok;
          request.response.contentLength = payload.length;
          request.response.add(payload);
          await request.response.close();
          return;
        }
        if (request.uri.path == '/file2.mp3') {
          if (failPart2) {
            request.response.statusCode = HttpStatus.internalServerError;
            await request.response.close();
            return;
          }
          if (!part2Started.isCompleted) part2Started.complete();
          request.response.statusCode = HttpStatus.ok;
          await request.response.flush();
          await releasePart2.future;
          try {
            await request.response.close();
          } catch (_) {}
          return;
        }
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      });

      final tempRoot = await Directory.systemTemp.createTemp('asmr_m26_');
      addTearDown(() async {
        if (await tempRoot.exists()) {
          await tempRoot.delete(recursive: true);
        }
      });

      final manager = AsmrDownloadManager(
        maxConcurrentDownloads: 1,
        persistTasks: false,
        temporaryDirectoryProvider: () async => tempRoot,
        automaticFileRetryDelay: Duration.zero,
      );
      addTearDown(() async {
        if (!releasePart2.isCompleted) releasePart2.complete();
        await manager.shutdown();
      });

      final baseUrl = 'http://127.0.0.1:${server.port}';
      final work = _testWork(id: 2601, title: 'Work26');

      await manager.startDownload(
        work: work,
        selectedRoots: [
          _audioNode(
            workId: 2601,
            title: 'file1.mp3',
            relativePath: 'file1.mp3',
            url: '$baseUrl/file1.mp3',
            size: payload.length,
          ),
          _audioNode(
            workId: 2601,
            title: 'file2.mp3',
            relativePath: 'file2.mp3',
            url: '$baseUrl/file2.mp3',
            size: 1024,
          ),
        ],
        destinationRoot: tempRoot.path,
        conflictPolicy: AsmrDownloadConflictPolicy.overwrite,
        saveMetadata: false,
        saveCover: false,
        automaticFileRetryCount: 0,
      );

      final file1Committed = Completer<void>();
      final sub = manager.taskStream(work.workKey).listen((snapshot) {
        if (snapshot?.completedFilePaths.contains('file1.mp3') == true &&
            !file1Committed.isCompleted) {
          file1Committed.complete();
        }
      });
      addTearDown(sub.cancel);

      await Future.wait([part2Started.future, file1Committed.future]);
      await manager.pauseTask(work.workKey);

      final file1 = File(path.join(tempRoot.path, 'Work26', 'file1.mp3'));
      expect(await file1.exists(), isTrue);
      await file1.delete();

      failPart2 = true;
      final failedDone = manager
          .taskStream(work.workKey)
          .firstWhere(
            (snapshot) => snapshot?.status == AsmrDownloadTaskStatus.failed,
          );
      await manager.resumeTask(work.workKey);
      final finalTask = await failedDone.timeout(const Duration(seconds: 5));

      expect(await file1.exists(), isTrue);
      expect(finalTask!.completedFilePaths, contains('file1.mp3'));
      expect(finalTask.downloadedBytes, payload.length);
      expect(finalTask.fileDownloadedBytes['file1.mp3'], payload.length);
    },
  );

  test(
    'M28 posixLocalRelativePath sanitizes FAT/FUSE-illegal and control chars while keeping Windows-only rules under Windows',
    () {
      const planner = AsmrDownloadPlanner();
      expect(
        planner.posixLocalRelativePath('Folder?:<1>/01*|"track\x00\x1F.mp3.'),
        'Folder___1_/01___track__.mp3',
      );
      expect(
        planner.posixLocalRelativePath('CON.txt'),
        'CON.txt',
      );
      expect(
        planner.windowsLocalRelativePath('CON.txt'),
        '_CON.txt',
      );
      expect(
        planner.posixLocalRelativePath('folder/.../track.mp3'),
        'folder/_/track.mp3',
      );
    },
  );

  test(
    'L12 deleteTask awaits an in-flight startDownload instead of returning as a no-op',
    () async {
      final tempRoot = await Directory.systemTemp.createTemp('asmr_l12_');
      addTearDown(() async {
        if (await tempRoot.exists()) {
          await tempRoot.delete(recursive: true);
        }
      });

      final persistenceEntered = Completer<void>();
      final releasePersistence = Completer<void>();
      var writeCalls = 0;
      final manager = AsmrDownloadManager(
        maxConcurrentDownloads: 1,
        temporaryDirectoryProvider: () async => tempRoot,
        persistenceReader: () async => null,
        persistenceWriter: (_) async {
          writeCalls++;
          if (writeCalls == 1) {
            if (!persistenceEntered.isCompleted) persistenceEntered.complete();
            await releasePersistence.future;
          }
        },
      );
      addTearDown(() async {
        if (!releasePersistence.isCompleted) releasePersistence.complete();
        await manager.shutdown();
      });
      await manager.initialize();

      // Hold _persistenceTail open so startDownload suspends while holding _startingTasks.
      final pendingFlush = manager.flushPersistence();
      await persistenceEntered.future.timeout(const Duration(seconds: 3));

      final work = _testWork(id: 1201, title: 'Work12');
      final startFuture = manager.startDownload(
        work: work,
        selectedRoots: [
          _audioNode(
            workId: 1201,
            title: 'track.mp3',
            relativePath: 'track.mp3',
            url: 'http://127.0.0.1:1/track.mp3',
            size: 16,
          ),
        ],
        destinationRoot: tempRoot.path,
        conflictPolicy: AsmrDownloadConflictPolicy.overwrite,
        saveMetadata: false,
        saveCover: false,
      );

      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(manager.getTask(work.workKey), isNotNull);
      // Trigger deleteTask while startDownload still holds _startingTasks.
      final deleteFuture = manager.deleteTask(work.workKey);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      releasePersistence.complete();

      await Future.wait([
        pendingFlush.timeout(const Duration(seconds: 5)),
        startFuture.timeout(const Duration(seconds: 5)),
        deleteFuture.timeout(const Duration(seconds: 5)),
      ]);
      expect(manager.getTask(work.workKey), isNull);
    },
  );

  test(
    'L13 AsmrDownloadOutputStore.targetFileExists probes .gif cover files',
    () async {
      final tempRoot = await Directory.systemTemp.createTemp('asmr_l13_');
      addTearDown(() async {
        if (await tempRoot.exists()) {
          await tempRoot.delete(recursive: true);
        }
      });

      final gifCover = File(path.join(tempRoot.path, 'cover', 'cover.gif'));
      await gifCover.parent.create(recursive: true);
      await gifCover.writeAsBytes(const <int>[0x47, 0x49, 0x46, 0x38]);

      final outputs = AsmrDownloadOutputStore(
        fileCacheGateway: FileCachePlatformGateway.instance,
        jsonDocumentStore: DefaultJsonDocumentStore(),
        stagingDirectoryProvider: () async => tempRoot,
      );
      const coverItem = PlannedDownloadFile.cover(
        url: 'https://example.test/cover-without-ext',
        relativePath: 'cover/cover.cover',
        coverFileStem: 'cover',
        maxBytes: 1024,
      );

      expect(await outputs.targetFileExists(tempRoot.path, coverItem), isTrue);
    },
  );
}
