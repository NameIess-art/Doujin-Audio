import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:charset/charset.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:doujin_audio/core/platform/file_cache_platform_gateway.dart';
import 'package:doujin_audio/features/asmr/application/asmr_library_controller.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';
import 'package:doujin_audio/features/library/application/work_text_service.dart';

List<CoverImageReference> _images(List<String> paths) => paths
    .map((path) => CoverImageReference(displayPath: path, sourcePath: path))
    .toList(growable: false);

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
  group('document preparation', () {
    test(
      'one MiB TXT preserves exact whitespace and Unicode at newline boundaries',
      () async {
        final service = WorkTextService();
        final text = '${'  台本😀\t\r\n' * 75000}终章';
        final bytes = Uint8List.fromList(utf8.encode(text));
        expect(bytes.length, greaterThan(1024 * 1024));
        final prepared = await service.prepareDocument(
          bytes,
          type: WorkDocType.text,
        );
        expect(prepared.encoding, WorkTextEncoding.utf8);
        expect(prepared.textBlocks.join(), text);
        expect(prepared.textBlocks.length, greaterThan(10));
        expect(
          prepared.textBlocks
              .take(prepared.textBlocks.length - 1)
              .every((block) => block.endsWith('\n')),
          isTrue,
        );
        expect(prepared.markdownNodes, isEmpty);
      },
    );

    test('a long single line remains one Unicode-safe block', () async {
      final text = '😀' * 40000;
      final prepared = await WorkTextService().prepareDocument(
        Uint8List.fromList(utf8.encode(text)),
        type: WorkDocType.text,
      );
      expect(prepared.textBlocks, [text]);
    });

    test(
      'complete Markdown resolves distant references and does not split fenced code lists or tables',
      () async {
        final source =
            '[远端引用][target]\n\n```text\n${'内容😀\n' * 6000}```\n\n'
            '- 第一项\n- 第二项\n\n| 标题 | 内容 |\n| --- | --- |\n| A | B |\n\n[target]: https://example.com/target\n';
        final prepared = await WorkTextService().prepareDocument(
          Uint8List.fromList(utf8.encode(source)),
          type: WorkDocType.markdown,
        );
        final nodes = prepared.markdownNodes.cast<md.Element>();
        expect(nodes.map((node) => node.tag), ['p', 'pre', 'ul', 'table']);
        final link = nodes.first.children!.single as md.Element;
        expect(link.attributes['href'], 'https://example.com/target');
        expect(nodes.elementAt(1).textContent, '内容😀\n' * 6000);
        expect(nodes.elementAt(2).children, hasLength(2));
        expect(prepared.textBlocks, isEmpty);
      },
    );

    test(
      'one MiB Markdown prepares complete top level AST in background',
      () async {
        final source = '# 标题\n\n${'段落内容文字。\n\n' * 50000}尾段';
        final bytes = Uint8List.fromList(utf8.encode(source));
        expect(bytes.length, greaterThan(1024 * 1024));
        final prepared = await WorkTextService().prepareDocument(
          bytes,
          type: WorkDocType.markdown,
        );
        expect(prepared.markdownNodes, hasLength(50002));
        expect(prepared.markdownNodes.first.textContent, '标题');
        expect(prepared.markdownNodes.last.textContent, '尾段');
      },
    );

    test('preparation supports legacy encoding override and BOM', () async {
      const text = '台本：おはようございます。';
      for (final entry in [
        (Uint8List.fromList(shiftJis.encode(text)), WorkTextEncoding.shiftJis),
        (Uint8List.fromList(gbk.encode('中文台本')), WorkTextEncoding.gbk),
        (
          Uint8List.fromList([
            0xFF,
            0xFE,
            ...text.codeUnits.expand((unit) => [unit & 255, unit >> 8]),
          ]),
          WorkTextEncoding.utf16Le,
        ),
        (
          Uint8List.fromList([
            0xFE,
            0xFF,
            ...text.codeUnits.expand((unit) => [unit >> 8, unit & 255]),
          ]),
          WorkTextEncoding.utf16Be,
        ),
      ]) {
        final prepared = await WorkTextService().prepareDocument(
          entry.$1,
          type: WorkDocType.text,
          encodingOverride: entry.$2,
        );
        expect(prepared.encoding, entry.$2);
        expect(
          prepared.textBlocks.join(),
          decodeWorkText(entry.$1, overrideEncoding: entry.$2).text,
        );
      }
    });
  });

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
      'successful text refresh reuses equal snapshots but detects changes',
      () async {
        var files = <Map<String, String>>[];
        final gateway = _FakeFileCacheGateway(discover: (_) async => files);
        final service = WorkTextService(platformGateway: gateway);
        addTearDown(service.dispose);
        final empty = await service.refreshWorkTextFiles('/work');
        expect(await service.refreshWorkTextFiles('/work'), same(empty));
        files = [
          {
            'name': 'script.txt',
            'relativePath': 'script.txt',
            'path': '/work/script.txt',
          },
        ];
        final added = await service.refreshWorkTextFiles('/work');
        expect(added, isNot(same(empty)));
        expect(await service.refreshWorkTextFiles('/work'), same(added));
        files = [
          {
            'name': 'renamed.txt',
            'relativePath': 'renamed.txt',
            'path': '/work/script.txt',
          },
        ];
        final renamed = await service.refreshWorkTextFiles('/work');
        expect(renamed, isNot(same(added)));
        expect(renamed.single.name, 'renamed.txt');
        expect(gateway.discoverCalls, 5);
      },
    );

    test(
      'image refresh preserves equal identity until content or generation changes',
      () async {
        var paths = ['/work/cover.jpg'];
        var scans = 0;
        final service = WorkTextService(
          discoverImages: (_) async {
            scans++;
            return _images(paths);
          },
        );
        addTearDown(service.dispose);
        final first = await service.refreshWorkImageFiles('/work');
        expect(await service.refreshWorkImageFiles('/work'), same(first));
        paths = ['/work/replacement.jpg'];
        final replaced = await service.refreshWorkImageFiles('/work');
        expect(replaced, isNot(same(first)));
        expect(replaced.single.sourcePath, '/work/replacement.jpg');
        await service.clearDirectoryCache();
        expect(
          await service.refreshWorkImageFiles('/work'),
          isNot(same(replaced)),
        );
        expect(scans, 4);
      },
    );

    test(
      'shares pending and completed scans for equivalent Windows paths',
      () async {
        final result = Completer<List<Map<String, String>>>();
        final gateway = _FakeFileCacheGateway(discover: (_) => result.future);
        final service = WorkTextService(platformGateway: gateway);
        final first = service.findWorkTextFiles(r'E:\作品\RJ 123');
        final second = service.findWorkTextFiles('e:/作品/RJ 123/');
        expect(gateway.discoverCalls, 1);
        expect(service.resolvedWorkTextFiles('e:/作品/RJ 123/'), isNull);
        result.complete([
          {
            'name': '台本.txt',
            'relativePath': '台本.txt',
            'path': r'E:\作品\RJ 123\台本.txt',
          },
        ]);
        final files = await first;
        expect(service.resolvedWorkTextFiles('e:/作品/RJ 123/'), same(files));
        expect(await second, same(files));
        expect(await service.findWorkTextFiles(r'E:\作品\RJ 123'), same(files));
        expect(gateway.discoverCalls, 1);
        await service.clearDirectoryCache();
        expect(service.resolvedWorkTextFiles(r'E:\作品\RJ 123'), isNull);
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

    test('findWorkTextFiles returns empty list for blank folder', () async {
      final gateway = _FakeFileCacheGateway();
      final service = WorkTextService(platformGateway: gateway);
      final files = await service.findWorkTextFiles('   ');
      expect(files, isEmpty);
    });

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

    test(
      'concurrent image refresh shares equivalent Windows paths and later refresh scans again',
      () async {
        final scan = Completer<List<CoverImageReference>>();
        var scans = 0;
        final service = WorkTextService(
          discoverImages: (_) {
            scans++;
            return scan.future;
          },
        );
        final first = service.refreshWorkImageFiles(r'E:\作品');
        expect(service.resolvedWorkImageFiles('e:/作品/'), isNull);
        final second = service.refreshWorkImageFiles('e:/作品/');
        expect(scans, 1);
        scan.complete(_images(['/support/cover.jpg']));
        final files = await first;
        expect(files, _images(['/support/cover.jpg']));
        expect(await second, same(files));
        expect(service.resolvedWorkImageFiles('e:/作品/'), same(files));
        await service.refreshWorkImageFiles(r'E:\作品');
        expect(scans, 2);
        await service.dispose();
        expect(service.resolvedWorkImageFiles(r'E:\作品'), isNull);
      },
    );

    test(
      'explicit failed refresh retains the previous successful snapshot',
      () async {
        var fail = false;
        final service = WorkTextService(
          discoverImages: (_) async {
            if (fail) throw const FileSystemException('Access denied');
            return _images(['/work/cover.jpg']);
          },
        );
        final files = await service.refreshWorkImageFiles('/work');
        fail = true;
        expect(await service.refreshWorkImageFiles('/work'), files);
        await service.dispose();
      },
    );

    test(
      'new service scans again and runtime gallery retains original source paths',
      () async {
        var scans = 0;
        WorkTextService create() => WorkTextService(
          discoverImages: (_) async {
            scans++;
            return [
              const CoverImageReference(
                displayPath: '/support/hash.jpg',
                sourcePath: r'E:\作品\画册\原图.jpg',
              ),
            ];
          },
        );
        final first = create();
        final files = await first.refreshWorkImageFiles(r'E:\作品');
        expect(files.single.sourcePath, r'E:\作品\画册\原图.jpg');
        expect(files.single.displayPath, '/support/hash.jpg');
        expect(first.resolvedWorkImageFiles('e:/作品/'), same(files));
        expect(
          first.sourcePathForWorkImage('e:/作品/', '/support/hash.jpg'),
          r'E:\作品\画册\原图.jpg',
        );
        await first.dispose();
        final restarted = create();
        expect(
          restarted.sourcePathForWorkImage(r'E:\作品', '/support/hash.jpg'),
          '/support/hash.jpg',
        );
        await restarted.refreshWorkImageFiles(r'E:\作品');
        expect(scans, 2);
        await restarted.dispose();
      },
    );

    test(
      'clear retires old discoveries while allowing a new explicit scan',
      () async {
        final old = Completer<List<CoverImageReference>>();
        var scans = 0;
        final service = WorkTextService(
          discoverImages: (_) {
            final request = scans++;
            if (request == 0) return old.future;
            if (request == 1) {
              return Future.value(_images(['/work/new.jpg']));
            }
            return Future.error(const FileSystemException('Access denied'));
          },
        );
        final pending = service.refreshWorkImageFiles('/work');
        await service.clearDirectoryCache();
        expect(
          await service.refreshWorkImageFiles('/work'),
          _images(['/work/new.jpg']),
        );
        old.complete(_images(['/work/old.jpg']));
        await pending;
        expect(
          await service.refreshWorkImageFiles('/work'),
          _images(['/work/new.jpg']),
        );
        await service.dispose();
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
