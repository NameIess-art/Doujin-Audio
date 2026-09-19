import 'dart:convert';
import 'dart:typed_data';

import 'package:charset/charset.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/platform/file_cache_platform_gateway.dart';
import 'package:doujin_audio/features/asmr/application/asmr_library_controller.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';
import 'package:doujin_audio/features/library/application/work_text_service.dart';

class _FakeFileCacheGateway extends Fake implements FileCachePlatformGateway {
  _FakeFileCacheGateway({
    this.discoverResult = const [],
    this.readResult,
  });

  final List<Map<String, String>> discoverResult;
  final Uint8List? readResult;

  @override
  Future<List<Map<String, String>>> discoverWorkTexts(String folderPath) async {
    return discoverResult;
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
        0xEF, 0xBB, 0xBF,
        ...utf8.encode(original),
      ]);
      final result = decodeWorkText(bytes);

      expect(result.encoding, WorkTextEncoding.utf8);
      expect(result.text, original);
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

    test('readDecodedText returns empty string when readDocumentBytes fails', () async {
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
    });
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
    test('AsmrTrackFile.isText identifies .txt, .md, .pdf and excludes audio/subtitles', () {
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
    });

    test('collectAsmrWorkTextFiles collects all text nodes from track tree', () {
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
      expect(files.first.path, contains('/api/media/stream/h_txt'));
      expect(files.first.docType, WorkDocType.text);
    });
  });
}

