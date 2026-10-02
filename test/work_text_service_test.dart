import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:charset/charset.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/platform/file_cache_platform_gateway.dart';
import 'package:doujin_audio/features/asmr/application/asmr_library_controller.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';
import 'package:doujin_audio/features/library/application/work_text_service.dart';
import 'package:doujin_audio/features/library/domain/local_directory_cache_repository.dart';

class _DirectoryCache implements LocalDirectoryCacheRepository {
  final snapshots = <(String, String), Map<String, Object?>>{};
  int writes = 0;

  @override
  Future<Map<String, Object?>?> loadDirectorySnapshot({
    required String kind,
    required String key,
  }) async => snapshots[(kind, key)];

  @override
  Future<void> saveDirectorySnapshot({
    required String kind,
    required String key,
    required Map<String, Object?> payload,
  }) async {
    writes++;
    snapshots[(kind, key)] = payload;
  }

  @override
  Future<void> clearDirectorySnapshots() async => snapshots.clear();
}

List<CoverImageReference> _images(List<String> paths) => paths
    .map((path) => CoverImageReference(displayPath: path, sourcePath: path))
    .toList(growable: false);

class _DelayedDirectoryCache extends _DirectoryCache {
  final writeStarted = Completer<void>();
  final allowWrite = Completer<void>();

  @override
  Future<void> saveDirectorySnapshot({
    required String kind,
    required String key,
    required Map<String, Object?> payload,
  }) async {
    writeStarted.complete();
    await allowWrite.future;
    await super.saveDirectorySnapshot(kind: kind, key: key, payload: payload);
  }
}

class _DelayedClearDirectoryCache extends _DirectoryCache {
  final clearStarted = Completer<void>();
  final allowClear = Completer<void>();
  int reads = 0;
  int clears = 0;

  @override
  Future<Map<String, Object?>?> loadDirectorySnapshot({
    required String kind,
    required String key,
  }) {
    reads++;
    return super.loadDirectorySnapshot(kind: kind, key: key);
  }

  @override
  Future<void> clearDirectorySnapshots() async {
    clears++;
    clearStarted.complete();
    await allowClear.future;
    await super.clearDirectorySnapshots();
  }
}

class _FakeFileCacheGateway extends Fake implements FileCachePlatformGateway {
  _FakeFileCacheGateway({
    this.discoverResult = const [],
    this.readResult,
    this.discover,
  });

  final List<Map<String, String>> discoverResult;
  final Uint8List? readResult;
  final Future<List<Map<String, String>>> Function(String)? discover;
  int discoverCalls = 0;

  @override
  Future<List<Map<String, String>>> discoverWorkTexts(String folderPath) async {
    discoverCalls++;
    return discover == null ? discoverResult : await discover!(folderPath);
  }

  @override
  Future<Uint8List?> readDocumentBytes(String filePath) async {
    return readResult;
  }
}

void main() {
  group('decodeWorkText', () {
    test('decodes UTF-8 text correctly without BOM', () {
      const original = '第一話：おはようございます。汉化剧本测试。';
      final bytes = Uint8List.fromList(utf8.encode(original));
      final result = decodeWorkText(bytes);

      expect(result.encoding, WorkTextEncoding.utf8);
      expect(result.text, original);
    });

    test('decodes UTF-8 text with BOM correctly', () {
      const original = 'UTF-8 with BOM 台本テスト';
      final bytes = Uint8List.fromList([
        0xEF,
        0xBB,
        0xBF,
        ...utf8.encode(original),
      ]);
      final result = decodeWorkText(bytes);

      expect(result.encoding, WorkTextEncoding.utf8);
      expect(result.text, original);
    });

    test('decodes UTF-16 text with either byte order mark', () {
      const original = '台本：おはようございます。';
      final units = original.codeUnits;
      final littleEndian = Uint8List.fromList([
        0xFF,
        0xFE,
        for (final unit in units) ...[unit & 0xFF, unit >> 8],
      ]);
      final bigEndian = Uint8List.fromList([
        0xFE,
        0xFF,
        for (final unit in units) ...[unit >> 8, unit & 0xFF],
      ]);

      expect(decodeWorkText(littleEndian).text, original);
      expect(decodeWorkText(littleEndian).encoding, WorkTextEncoding.utf16Le);
      expect(decodeWorkText(bigEndian).text, original);
      expect(decodeWorkText(bigEndian).encoding, WorkTextEncoding.utf16Be);
    });

    test('auto-detects and decodes Shift-JIS text correctly', () {
      const original = 'トラック01：おはようございます、お兄ちゃん。特典台本です。';
      final bytes = Uint8List.fromList(shiftJis.encode(original));
      final result = decodeWorkText(bytes);

      expect(result.encoding, WorkTextEncoding.shiftJis);
      expect(result.text, original);
    });

    test('auto-detects and decodes GBK text correctly', () {
      const original = '【汉化剧本】第01轨：早上好，主人。这里是特典说明文本。';
      final bytes = Uint8List.fromList(gbk.encode(original));
      final result = decodeWorkText(bytes);

      expect(result.encoding, WorkTextEncoding.gbk);
      expect(result.text, original);
    });

    test('supports manual override encoding', () {
      const original = '纯中文字符测试剧本';
      final bytes = Uint8List.fromList(gbk.encode(original));
      final result = decodeWorkText(
        bytes,
        overrideEncoding: WorkTextEncoding.gbk,
      );

      expect(result.encoding, WorkTextEncoding.gbk);
      expect(result.text, original);
    });

    test('handles empty bytes gracefully', () {
      final result = decodeWorkText(Uint8List(0));
      expect(result.text, '');
      expect(result.encoding, WorkTextEncoding.utf8);
    });
  });

  group('WorkTextService', () {
    test(
      'shares pending and completed scans for equivalent Windows paths',
      () async {
        final result = Completer<List<Map<String, String>>>();
        final gateway = _FakeFileCacheGateway(discover: (_) => result.future);
        final service = WorkTextService(platformGateway: gateway);
        final first = service.findWorkTextFiles(r'E:\作品\RJ 123');
        final second = service.findWorkTextFiles('e:/作品/RJ 123/');
        expect(gateway.discoverCalls, 1);
        result.complete([
          {
            'name': '台本.txt',
            'relativePath': '台本.txt',
            'path': r'E:\作品\RJ 123\台本.txt',
          },
        ]);
        final files = await first;
        expect(await second, same(files));
        expect(await service.findWorkTextFiles(r'E:\作品\RJ 123'), same(files));
        expect(gateway.discoverCalls, 1);
      },
    );

    test(
      'revision changes replace pending scans without restoring stale data',
      () async {
        var revision = 0;
        final stale = Completer<List<Map<String, String>>>();
        final current = Completer<List<Map<String, String>>>();
        var scan = 0;
        final gateway = _FakeFileCacheGateway(
          discover: (_) => scan++ == 0 ? stale.future : current.future,
        );
        final service = WorkTextService(
          platformGateway: gateway,
          directoryRevision: () => revision,
        );
        final first = service.findWorkTextFiles('content://library/work');
        revision++;
        final second = service.findWorkTextFiles('content://library/work');
        current.complete([
          {
            'name': '新台本.md',
            'relativePath': '新台本.md',
            'path': 'content://library/new',
          },
        ]);
        final files = await second;
        stale.complete([]);
        await first;
        expect(
          await service.findWorkTextFiles('content://library/work'),
          same(files),
        );
        expect(gateway.discoverCalls, 2);
      },
    );

    test('failed scans retry and successful empty scans are reused', () async {
      var scan = 0;
      final gateway = _FakeFileCacheGateway(
        discover: (_) async {
          if (scan++ == 0) throw const FileSystemException('Access denied');
          if (scan == 2) return [];
          return [
            {
              'name': '台本.txt',
              'relativePath': '台本.txt',
              'path': '/work/台本.txt',
            },
          ];
        },
      );
      final service = WorkTextService(platformGateway: gateway);
      await expectLater(
        service.findWorkTextFiles('/work'),
        throwsA(isA<FileSystemException>()),
      );
      expect(await service.findWorkTextFiles('/work'), isEmpty);
      expect(await service.findWorkTextFiles('/work'), isEmpty);
      expect(gateway.discoverCalls, 2);
      expect(await service.refreshWorkTextFiles('/work'), hasLength(1));
      expect(gateway.discoverCalls, 3);
    });

    test('restores persisted text before a failed background scan', () async {
      final cache = _DirectoryCache();
      final gateway = _FakeFileCacheGateway(
        discoverResult: [
          {'name': '台本.txt', 'relativePath': '台本.txt', 'path': r'E:\作品\台本.txt'},
        ],
      );
      final first = WorkTextService(
        platformGateway: gateway,
        directoryCache: cache,
      );
      final files = await first.findWorkTextFiles(r'E:\作品');
      final failingGateway = _FakeFileCacheGateway(
        discover: (_) async {
          throw const FileSystemException('Access denied');
        },
      );
      final restored = WorkTextService(
        platformGateway: failingGateway,
        directoryCache: cache,
      );
      expect(await restored.findWorkTextFiles('e:/作品/'), files);
      expect(await restored.refreshWorkTextFiles('e:/作品/'), files);
      expect(cache.writes, 1);
      expect(restored.cachedWorkTextFiles(r'E:\作品'), files);
    });

    test(
      'persisted empty discovery restores without waiting for scan',
      () async {
        final cache = _DirectoryCache();
        await WorkTextService(
          platformGateway: _FakeFileCacheGateway(),
          directoryCache: cache,
        ).findWorkTextFiles('/empty');
        final scan = Completer<List<Map<String, String>>>();
        final gateway = _FakeFileCacheGateway(discover: (_) => scan.future);
        final restored = WorkTextService(
          platformGateway: gateway,
          directoryCache: cache,
        );
        expect(await restored.findWorkTextFiles('/empty'), isEmpty);
        expect(gateway.discoverCalls, 1);
        scan.complete([]);
        await restored.refreshWorkTextFiles('/empty');
      },
    );

    test(
      'image discovery shares equivalent paths and preserves failed refresh',
      () async {
        final cache = _DirectoryCache();
        var fail = false;
        var calls = 0;
        final service = WorkTextService(
          directoryCache: cache,
          discoverImages: (_) async {
            calls++;
            if (fail) throw const FileSystemException('Directory unavailable');
            return _images([r'E:\作品\cover.jpg']);
          },
        );
        final files = await service.findWorkImageFiles(r'E:\作品');
        expect(await service.findWorkImageFiles('e:/作品/'), files);
        expect(calls, 1);
        fail = true;
        expect(await service.refreshWorkImageFiles(r'E:\作品'), files);
        expect(cache.writes, 1);
        final restored = WorkTextService(
          directoryCache: cache,
          discoverImages: (_) async =>
              throw const FileSystemException('offline'),
        );
        expect(await restored.findWorkImageFiles(r'E:\作品'), files);
        expect(restored.cachedWorkImageFiles('e:/作品/'), files);
      },
    );

    test('memory eviction retains persistent directory snapshots', () async {
      final cache = _DirectoryCache();
      final pending = Completer<List<CoverImageReference>>();
      var restored = false;
      final service = WorkTextService(
        directoryCache: cache,
        discoverImages: (folder) async =>
            restored ? pending.future : _images(['$folder/cover.jpg']),
      );
      for (var index = 0; index < 33; index++) {
        await service.findWorkImageFiles('/work/$index');
      }
      expect(service.cachedWorkImageFiles('/work/0'), isNull);
      restored = true;
      expect(await service.findWorkImageFiles('/work/0'), [
        '/work/0/cover.jpg',
      ]);
      expect(cache.snapshots, hasLength(33));
      pending.complete(_images(['/work/0/cover.jpg']));
      await service.refreshWorkImageFiles('/work/0');
    });

    test(
      'clear prevents in-flight discoveries from repopulating snapshots',
      () async {
        final cache = _DirectoryCache();
        final scan = Completer<List<CoverImageReference>>();
        final service = WorkTextService(
          directoryCache: cache,
          discoverImages: (_) => scan.future,
        );
        final pending = service.findWorkImageFiles('/work');
        await Future<void>.delayed(Duration.zero);
        await service.clearDirectoryCache();
        scan.complete(_images(['/work/cover.jpg']));
        await pending;
        expect(service.cachedWorkImageFiles('/work'), isNull);
        expect(cache.snapshots, isEmpty);
        expect(cache.writes, 0);
      },
    );

    test(
      'new reads wait for a shared clear before restoring disk snapshots',
      () async {
        final cache = _DelayedClearDirectoryCache();
        cache.snapshots[('work_images', 'file:/work')] = {
          'version': 1,
          'files': [
            {'path': '/old.jpg', 'sourcePath': '/old.jpg'},
          ],
        };
        var discoveries = 0;
        final service = WorkTextService(
          directoryCache: cache,
          discoverImages: (_) async {
            discoveries++;
            return _images(['/work/new.jpg']);
          },
        );
        final clear = service.clearDirectoryCache();
        await cache.clearStarted.future;
        expect(identical(service.clearDirectoryCache(), clear), isTrue);
        final first = service.findWorkImageFiles('/work');
        final second = service.findWorkImageFiles('/work');
        await Future<void>.delayed(Duration.zero);
        expect(cache.reads, 0);
        expect(discoveries, 0);
        cache.allowClear.complete();
        await clear;
        expect(await first, ['/work/new.jpg']);
        expect(await second, ['/work/new.jpg']);
        expect(cache.clears, 1);
        expect(discoveries, 1);
        expect(service.cachedWorkImageFiles('/work'), ['/work/new.jpg']);
        expect(cache.snapshots.values.single['files'], [
          {'path': '/work/new.jpg', 'sourcePath': '/work/new.jpg'},
        ]);
        await service.dispose();
      },
    );

    test('findWorkTextFiles returns mapped WorkTextFile list', () async {
      final gateway = _FakeFileCacheGateway(
        discoverResult: [
          {
            'name': '01_台本.txt',
            'relativePath': '台本/01_台本.txt',
            'path': '/works/RJ123/台本/01_台本.txt',
          },
          {
            'name': 'readme.txt',
            'relativePath': 'readme.txt',
            'path': '/works/RJ123/readme.txt',
          },
        ],
      );

      final service = WorkTextService(platformGateway: gateway);
      final files = await service.findWorkTextFiles('/works/RJ123');

      expect(files, hasLength(2));
      expect(files[0].name, '01_台本.txt');
      expect(files[0].relativePath, '台本/01_台本.txt');
      expect(files[0].path, '/works/RJ123/台本/01_台本.txt');
      expect(files[1].name, 'readme.txt');
    });

    test(
      'background refresh notifies changed lists and disposal drains persistence',
      () async {
        final cache = _DirectoryCache();
        var files = <String>['/work/first.jpg'];
        final service = WorkTextService(
          directoryCache: cache,
          discoverImages: (_) async => _images(files),
        );
        final changes = <String>[];
        final subscription = service.directoryChanges.listen(changes.add);
        await service.findWorkImageFiles('/work');
        await service.refreshWorkImageFiles('/work');
        files = ['/work/second.jpg'];
        await service.refreshWorkImageFiles('/work');
        await service.dispose();
        expect(changes, ['file:/work', 'file:/work']);
        expect(cache.snapshots.values.single['files'], [
          {'path': '/work/second.jpg', 'sourcePath': '/work/second.jpg'},
        ]);
        await subscription.cancel();
      },
    );

    test('findWorkTextFiles returns empty list for blank folder', () async {
      final gateway = _FakeFileCacheGateway();
      final service = WorkTextService(platformGateway: gateway);
      final files = await service.findWorkTextFiles('   ');
      expect(files, isEmpty);
    });

    test(
      'persisted gallery retains source names alongside durable display paths',
      () async {
        final cache = _DirectoryCache();
        final service = WorkTextService(
          directoryCache: cache,
          discoverImages: (_) async => [
            const CoverImageReference(
              displayPath: '/support/cover_artwork/hash.jpg',
              sourcePath: r'E:\作品\画册\原图.jpg',
            ),
          ],
        );
        final files = await service.findWorkImageFiles(r'E:\作品');
        expect(
          service.sourcePathForWorkImage(r'E:\作品', files.single),
          r'E:\作品\画册\原图.jpg',
        );
        final restored = WorkTextService(
          directoryCache: cache,
          discoverImages: (_) async =>
              throw const FileSystemException('offline'),
        );
        final persisted = await restored.findWorkImageFiles('e:/作品/');
        expect(persisted, files);
        expect(
          restored.sourcePathForWorkImage('e:/作品/', persisted.single),
          r'E:\作品\画册\原图.jpg',
        );
        await service.dispose();
        await restored.dispose();
      },
    );

    test('readDecodedText reads bytes and decodes properly', () async {
      const original = '音声作品台本テスト';
      final gateway = _FakeFileCacheGateway(
        readResult: Uint8List.fromList(shiftJis.encode(original)),
      );

      final service = WorkTextService(platformGateway: gateway);
      final result = await service.readDecodedText(
        const WorkTextFile(
          name: 'script.txt',
          relativePath: 'script.txt',
          path: '/path/script.txt',
        ),
      );

      expect(result.text, original);
      expect(result.encoding, WorkTextEncoding.shiftJis);
    });

    test(
      'clear waits for already-started writes before deleting snapshots',
      () async {
        final cache = _DelayedDirectoryCache();
        final service = WorkTextService(
          directoryCache: cache,
          discoverImages: (_) async => _images(['/work/cover.jpg']),
        );
        final pending = service.findWorkImageFiles('/work');
        await cache.writeStarted.future;
        final clear = service.clearDirectoryCache();
        cache.allowWrite.complete();
        await Future.wait([pending, clear]);
        expect(cache.snapshots, isEmpty);
        expect(service.cachedWorkImageFiles('/work'), isNull);
        await service.dispose();
      },
    );

    test(
      'lifecycle flush waits for discovery and persistence without disposing',
      () async {
        final cache = _DelayedDirectoryCache();
        final scan = Completer<List<CoverImageReference>>();
        final service = WorkTextService(
          directoryCache: cache,
          discoverImages: (_) => scan.future,
        );
        final discovery = service.findWorkImageFiles('/work');
        await Future<void>.delayed(Duration.zero);
        var flushed = false;
        final flush = service.flushDirectoryCache().then((_) => flushed = true);
        scan.complete(_images(['/work/cover.jpg']));
        await cache.writeStarted.future;
        expect(flushed, isFalse);
        cache.allowWrite.complete();
        await Future.wait([discovery, flush]);
        expect(cache.snapshots.values.single['files'], [
          {'path': '/work/cover.jpg', 'sourcePath': '/work/cover.jpg'},
        ]);
        expect(await service.findWorkImageFiles('/work'), ['/work/cover.jpg']);
        await service.dispose();
      },
    );

    test(
      'readDecodedText returns empty string when readDocumentBytes fails',
      () async {
        final gateway = _FakeFileCacheGateway();
        final service = WorkTextService(platformGateway: gateway);
        final result = await service.readDecodedText(
          const WorkTextFile(
            name: 'missing.txt',
            relativePath: 'missing.txt',
            path: '/path/missing.txt',
          ),
        );

        expect(result.text, '');
        expect(result.encoding, WorkTextEncoding.utf8);
      },
    );
    test('readDocumentBytes returns raw bytes from gateway', () async {
      final raw = Uint8List.fromList([0x25, 0x50, 0x44, 0x46]); // %PDF
      final gateway = _FakeFileCacheGateway(readResult: raw);
      final service = WorkTextService(platformGateway: gateway);
      final result = await service.readDocumentBytes(
        const WorkTextFile(
          name: 'doc.pdf',
          relativePath: 'doc.pdf',
          path: '/path/doc.pdf',
        ),
      );

      expect(result, raw);
    });

    test(
      'remote text retries another URL and preserves its original bytes',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final requestedPaths = <String>[];
        server.listen((request) async {
          requestedPaths.add(request.uri.path);
          if (request.uri.path == '/unavailable') {
            request.response.statusCode = HttpStatus.notFound;
          } else {
            request.response.add(shiftJis.encode('台本：おはようございます。'));
          }
          await request.response.close();
        });

        final service = WorkTextService();
        final file = WorkTextFile(
          name: 'script.txt',
          relativePath: 'script.txt',
          path: 'http://127.0.0.1:${server.port}/unavailable',
          fallbackUrls: ['http://127.0.0.1:${server.port}/script'],
        );
        final result = await service.readDecodedText(file);

        expect(requestedPaths, ['/unavailable', '/script']);
        expect(result.text, '台本：おはようございます。');
        expect(result.encoding, WorkTextEncoding.shiftJis);
      },
    );
  });

  group('WorkDocType and WorkTextFile', () {
    test('identifies document types correctly', () {
      expect(WorkDocType.fromPath('manual.pdf'), WorkDocType.pdf);
      expect(WorkDocType.fromPath('MANUAL.PDF'), WorkDocType.pdf);
      expect(WorkDocType.fromPath('README.md'), WorkDocType.markdown);
      expect(WorkDocType.fromPath('notes.MD'), WorkDocType.markdown);
      expect(WorkDocType.fromPath('script.txt'), WorkDocType.text);
      expect(WorkDocType.fromPath('SCRIPT.TXT'), WorkDocType.text);
      expect(WorkDocType.fromPath('other'), WorkDocType.text);
    });

    test('WorkTextFile reports isPdf and isMarkdown accurately', () {
      const pdfFile = WorkTextFile(
        name: 'manual.pdf',
        relativePath: 'docs/manual.pdf',
        path: '/works/RJ123/docs/manual.pdf',
      );
      expect(pdfFile.docType, WorkDocType.pdf);
      expect(pdfFile.isPdf, isTrue);
      expect(pdfFile.isMarkdown, isFalse);

      const remotePdf = WorkTextFile(
        name: 'booklet.pdf',
        relativePath: 'booklet.pdf',
        path: 'https://api.asmr.one/api/media/download/hash',
      );
      expect(remotePdf.isPdf, isTrue);

      const remoteMarkdown = WorkTextFile(
        name: 'readme.md',
        relativePath: 'readme.md',
        path: 'https://api.asmr.one/api/media/stream/hash',
      );
      expect(remoteMarkdown.isMarkdown, isTrue);

      const mdFile = WorkTextFile(
        name: 'README.md',
        relativePath: 'README.md',
        path: '/works/RJ123/README.md',
      );
      expect(mdFile.docType, WorkDocType.markdown);
      expect(mdFile.isPdf, isFalse);
      expect(mdFile.isMarkdown, isTrue);

      const txtFile = WorkTextFile(
        name: 'script.txt',
        relativePath: 'script.txt',
        path: '/works/RJ123/script.txt',
      );
      expect(txtFile.docType, WorkDocType.text);
      expect(txtFile.isPdf, isFalse);
      expect(txtFile.isMarkdown, isFalse);
    });

    test('displayName strips extension properly for .txt, .md, and .pdf', () {
      const fileWithExt = WorkTextFile(
        name: '01_トラック台本.txt',
        relativePath: '01_トラック台本.txt',
        path: '/path/01_トラック台本.txt',
      );
      expect(fileWithExt.displayName, '01_トラック台本');

      const mdFile = WorkTextFile(
        name: '特典说明.md',
        relativePath: '特典说明.md',
        path: '/path/特典说明.md',
      );
      expect(mdFile.displayName, '特典说明');

      const pdfFile = WorkTextFile(
        name: 'ブックレット.pdf',
        relativePath: 'ブックレット.pdf',
        path: '/path/ブックレット.pdf',
      );
      expect(pdfFile.displayName, 'ブックレット');

      const fileWithoutExt = WorkTextFile(
        name: 'README',
        relativePath: 'README',
        path: '/path/README',
      );
      expect(fileWithoutExt.displayName, 'README');

      const multiDotFile = WorkTextFile(
        name: 'part.1.final.script.txt',
        relativePath: 'part.1.final.script.txt',
        path: '/path/part.1.final.script.txt',
      );
      expect(multiDotFile.displayName, 'part.1.final.script');
    });
  });

  group('ASMR WorkText support', () {
    test(
      'AsmrTrackFile.isText identifies .txt, .md, .pdf and excludes audio/subtitles',
      () {
        final txtNode = AsmrTrackFile(
          hash: 'h1',
          title: '台本.txt',
          type: 'text',
          streamUrl: 'https://api.asmr-200.com/stream/h1',
          downloadUrl: null,
          lowQualityUrl: null,
          duration: Duration.zero,
          size: 100,
          children: const [],
          workId: 123,
          workTitle: 'Work 123',
          sourceId: 'RJ123',
          relativePath: '台本.txt',
        );
        expect(txtNode.isText, isTrue);
        expect(txtNode.isAudio, isFalse);
        expect(txtNode.isSubtitle, isFalse);

        final pdfNode = AsmrTrackFile(
          hash: 'h2',
          title: 'booklet.pdf',
          type: 'other',
          streamUrl: 'https://api.asmr-200.com/stream/h2',
          downloadUrl: null,
          lowQualityUrl: null,
          duration: Duration.zero,
          size: 500,
          children: const [],
          workId: 123,
          workTitle: 'Work 123',
          sourceId: 'RJ123',
          relativePath: 'booklet.pdf',
        );
        expect(pdfNode.isText, isTrue);

        final audioNode = AsmrTrackFile(
          hash: 'h3',
          title: '01.mp3',
          type: 'audio',
          streamUrl: 'https://api.asmr-200.com/stream/h3',
          downloadUrl: null,
          lowQualityUrl: null,
          duration: const Duration(minutes: 5),
          size: 1000,
          children: const [],
          workId: 123,
          workTitle: 'Work 123',
          sourceId: 'RJ123',
          relativePath: '01.mp3',
        );
        expect(audioNode.isText, isFalse);
        expect(audioNode.isAudio, isTrue);

        final subtitleNode = AsmrTrackFile(
          hash: 'h4',
          title: '01.vtt',
          type: 'text',
          streamUrl: 'https://api.asmr-200.com/stream/h4',
          downloadUrl: null,
          lowQualityUrl: null,
          duration: Duration.zero,
          size: 200,
          children: const [],
          workId: 123,
          workTitle: 'Work 123',
          sourceId: 'RJ123',
          relativePath: '01.vtt',
        );
        expect(subtitleNode.isText, isFalse);
        expect(subtitleNode.isSubtitle, isTrue);
      },
    );

    test(
      'collectAsmrWorkTextFiles collects all text nodes from track tree',
      () {
        final tree = <AsmrTrackFile>[
          AsmrTrackFile(
            hash: 'dir1',
            title: 'Docs',
            type: 'folder',
            streamUrl: null,
            downloadUrl: null,
            lowQualityUrl: null,
            duration: Duration.zero,
            size: 0,
            children: [
              AsmrTrackFile(
                hash: 'h_txt',
                title: '台本_第1話.txt',
                type: 'text',
                streamUrl: 'https://api.asmr-200.com/stream/h_txt',
                downloadUrl: null,
                lowQualityUrl: null,
                duration: Duration.zero,
                size: 500,
                children: const [],
                workId: 123,
                workTitle: 'Work 123',
                sourceId: 'RJ123',
                relativePath: 'Docs/台本_第1話.txt',
              ),
            ],
            workId: 123,
            workTitle: 'Work 123',
            sourceId: 'RJ123',
            relativePath: 'Docs',
          ),
          AsmrTrackFile(
            hash: 'h_audio',
            title: '01_Track.wav',
            type: 'audio',
            streamUrl: 'https://api.asmr-200.com/stream/h_audio',
            downloadUrl: null,
            lowQualityUrl: null,
            duration: const Duration(minutes: 10),
            size: 50000,
            children: const [],
            workId: 123,
            workTitle: 'Work 123',
            sourceId: 'RJ123',
            relativePath: '01_Track.wav',
          ),
        ];

        final files = collectAsmrWorkTextFiles(tree);
        expect(files.length, 1);
        expect(files.first.name, '台本_第1話.txt');
        expect(files.first.relativePath, 'Docs/台本_第1話.txt');
        expect(files.first.path, 'https://api.asmr-200.com/stream/h_txt');
        expect(
          files.first.fallbackUrls,
          contains('https://api.asmr-300.com/api/media/download/h_txt'),
        );
        expect(
          files.first.fallbackUrls,
          contains('https://api.asmr-300.com/api/media/stream/h_txt'),
        );
        expect(files.first.docType, WorkDocType.text);
      },
    );
  });
}
