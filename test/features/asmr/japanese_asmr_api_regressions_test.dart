import 'dart:convert';
import 'dart:io';

import 'package:doujin_audio/features/asmr/application/japanese_asmr_api_service.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';
import 'package:flutter_test/flutter_test.dart';

AsmrWork _work(int id) => AsmrWork(
  id: id,
  title: 'Work $id',
  circleName: 'Circle',
  sourceId: 'RJ${id.toString().padLeft(6, '0')}',
  sourceType: 'jp-asmr',
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
  voiceActors: const <String>[],
  tags: const <String>[],
  resources: [
    AsmrWorkResource(
      source: AsmrCatalogSource.japaneseAsmr,
      id: id,
      code: 'RJ${id.toString().padLeft(6, '0')}',
      pageUrl: 'https://japaneseasmr.com/$id/',
    ),
  ],
);

void main() {
  group('#74 JapaneseAsmrApiService malformed JSON throws FormatException', () {
    Future<void> expectFormatExceptionForSearch(Object payload) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(payload));
        await request.response.close();
      });
      final api = JapaneseAsmrApiService(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}/'),
      );
      addTearDown(api.close);
      await expectLater(
        api.searchWorks(keyword: 'test'),
        throwsA(isA<FormatException>()),
      );
    }

    Future<void> expectFormatExceptionForTracks(Object payload) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(payload));
        await request.response.close();
      });
      final api = JapaneseAsmrApiService(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}/'),
      );
      addTearDown(api.close);
      await expectLater(
        api.fetchTrackTree(_work(74)),
        throwsA(isA<FormatException>()),
      );
    }

    test('searchWorks rejects non-object roots and malformed items', () async {
      await expectFormatExceptionForSearch(<dynamic>[]);
      await expectFormatExceptionForSearch('not-an-object');
      await expectFormatExceptionForSearch({
        'items': ['bad-item'],
        'total': 1,
      });
      await expectFormatExceptionForSearch({
        'items': [
          {'workId': 'not-a-number', 'rj': 'RJ000001'},
        ],
        'total': 1,
      });
    });

    test(
      'fetchTrackTree rejects non-object roots, bad nodes, and bad children',
      () async {
        await expectFormatExceptionForTracks(<dynamic>[]);
        await expectFormatExceptionForTracks({
          'trackTree': ['bad-node'],
        });
        await expectFormatExceptionForTracks({
          'trackTree': [
            {'type': 'folder', 'title': 'dir', 'children': 'not-a-list'},
          ],
        });
        await expectFormatExceptionForTracks({
          'trackTree': [
            {
              'type': 'folder',
              'title': 'dir',
              'children': [123],
            },
          ],
        });
      },
    );
  });
}
