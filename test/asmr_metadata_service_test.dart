import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/app_language.dart';
import 'package:doujin_audio/core/media/dlsite_metadata.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';
import 'package:doujin_audio/features/asmr/application/asmr_api_service.dart';
import 'package:doujin_audio/features/asmr/application/asmr_metadata_service.dart';
import 'package:doujin_audio/features/library/application/dlsite_metadata_service.dart';
import 'package:doujin_audio/features/library/application/library_facade.dart';

import 'support/test_persistence_repository.dart';

void main() {
  test('fetchByRjCode returns exact ASMR.ONE work metadata', () async {
    final service = AsmrMetadataService(
      apiService: _FakeAsmrApiService(
        works: [
          _work(sourceId: 'RJ000001', title: 'Other'),
          _work(
            sourceId: 'RJ123456',
            title: 'Target',
            releaseDate: DateTime(2024, 5, 6),
            duration: const Duration(hours: 1, minutes: 2, seconds: 3),
            dlCount: 1234,
            rating: 4.5,
          ),
        ],
      ),
    );

    final metadata = await service.fetchByRjCode('folder RJ123456');

    expect(metadata.rjCode, 'RJ123456');
    expect(metadata.workTitle, 'Target');
    expect(metadata.releaseDate, DateTime(2024, 5, 6));
    expect(metadata.duration, const Duration(hours: 1, minutes: 2, seconds: 3));
    expect(metadata.salesCount, 1234);
    expect(metadata.rating, 4.5);
  });

  test('searchByTitleCandidates scores ASMR.ONE title matches', () async {
    final service = AsmrMetadataService(
      apiService: _FakeAsmrApiService(
        works: [
          _work(sourceId: 'RJ000001', title: 'Other'),
          _work(sourceId: 'RJ123456', title: 'Sleep ASMR'),
        ],
      ),
    );

    final results = await service.searchByTitleCandidates(['Sleep ASMR']);

    expect(results, hasLength(1));
    expect(results.single.rjCode, 'RJ123456');
  });

  test('findAsmrWorkByRjCode returns exact match by RJ code', () async {
    final target = _work(sourceId: 'RJ123456', title: 'Target Work');
    final service = AsmrMetadataService(
      apiService: _FakeAsmrApiService(
        works: [
          _work(sourceId: 'RJ000001', title: 'Other Work'),
          target,
        ],
      ),
    );

    final work = await service.findAsmrWorkByRjCode('rj123456');
    expect(work, isNotNull);
    expect(work!.rjCode, 'RJ123456');
    expect(work.title, 'Target Work');

    final missing = await service.findAsmrWorkByRjCode('RJ999999');
    expect(missing, isNull);

    final invalid = await service.findAsmrWorkByRjCode('no_rj_here');
    expect(invalid, isNull);
  });

  for (final byTitle in [false, true]) {
    group(byTitle ? 'title metadata lookup' : 'RJ metadata lookup', () {
      final completeWork = _work(
        sourceId: 'RJ123456',
        title: 'Sleep ASMR',
        releaseDate: DateTime(2024, 5, 6),
        duration: const Duration(hours: 1),
        dlCount: 1234,
        rating: 4.5,
      );
      final fallback = DlsiteMetadata(
        rjCode: 'RJ123456',
        workTitle: 'DLsite Sleep ASMR',
        circleName: 'DLsite Circle',
        voiceActors: const ['DLsite Voice'],
        tags: const ['DLsite Tag'],
        releaseDate: DateTime(2023, 1, 2),
        duration: const Duration(hours: 2),
        salesCount: 4321,
        rating: 5,
        coverUrl: 'https://example.com/dlsite.jpg',
      );
      late List<String> calls;
      late _FakeAsmrApiService api;
      late _FakeDlsiteMetadataService dlsite;
      late LibraryFacade library;

      setUp(() {
        calls = [];
        api = _FakeAsmrApiService(works: [completeWork], calls: calls);
        dlsite = _FakeDlsiteMetadataService(calls: calls, metadata: fallback);
        library = LibraryFacade.create(
          databaseRepository: TestPersistenceRepository(),
          asmrMetadataService: AsmrMetadataService(apiService: api),
          metadataService: dlsite,
        );
        addTearDown(library.dispose);
      });

      Future<DlsiteMetadata> lookup() async {
        if (byTitle) {
          return (await library.searchPreferredMetadataByTitles([
            'Sleep ASMR',
          ], language: AppLanguage.ja)).single;
        }
        return library.fetchPreferredMetadata(
          'RJ123456',
          language: AppLanguage.ja,
        );
      }

      void expectCalls({bool fallbackRequested = true}) {
        expect(calls, [
          'asmr:${byTitle ? 'Sleep ASMR' : 'RJ123456'}:ja',
          if (fallbackRequested)
            'dlsite:${byTitle ? 'Sleep ASMR' : 'RJ123456'}:ja',
        ]);
      }

      test('complete ASMR.ONE metadata skips DLsite', () async {
        final result = await lookup();

        expect(result.workTitle, 'Sleep ASMR');
        expect(result.coverUrl, completeWork.coverUrl);
        expectCalls(fallbackRequested: false);
      });

      test('ASMR.ONE failure falls back directly to DLsite', () async {
        api.error = StateError('ASMR.ONE unavailable');

        expect(await lookup(), same(fallback));
        expectCalls();
      });

      test('no ASMR.ONE match falls back to DLsite', () async {
        api.works = [_work(sourceId: 'RJ000001', title: 'Other')];

        expect(await lookup(), same(fallback));
        expectCalls();
      });

      test(
        'DLsite fills missing fields and preserves ASMR.ONE values',
        () async {
          api.works = [_work(sourceId: 'RJ123456', title: 'Sleep ASMR')];

          final result = await lookup();

          expect(result.workTitle, 'Sleep ASMR');
          expect(result.circleName, 'Circle');
          expect(result.voiceActors, ['Voice']);
          expect(result.tags, ['ASMR']);
          expect(result.coverUrl, api.works.single.coverUrl);
          expect(result.releaseDate, fallback.releaseDate);
          expect(result.duration, fallback.duration);
          expect(result.salesCount, fallback.salesCount);
          expect(result.rating, fallback.rating);
          expectCalls();
        },
      );

      test('missing cover also requests DLsite supplementation', () async {
        api.works = [
          _work(
            sourceId: 'RJ123456',
            title: completeWork.title,
            releaseDate: completeWork.releaseDate,
            duration: completeWork.duration,
            dlCount: completeWork.dlCount,
            rating: completeWork.rating,
            coverUrl: '',
          ),
        ];

        final result = await lookup();

        expect(result.coverUrl, fallback.coverUrl);
        expect(result.workTitle, completeWork.title);
        expect(result.releaseDate, completeWork.releaseDate);
        expectCalls();
      });

      test('DLsite failure retains available ASMR.ONE metadata', () async {
        api.works = [_work(sourceId: 'RJ123456', title: 'Sleep ASMR')];
        dlsite.error = StateError('DLsite unavailable');

        final result = await lookup();

        expect(result.workTitle, 'Sleep ASMR');
        expect(result.duration, isNull);
        expectCalls();
      });

      test('both sources failing reports the DLsite failure', () async {
        api.error = StateError('ASMR.ONE unavailable');
        final error = StateError('DLsite unavailable');
        dlsite.error = error;

        await expectLater(lookup(), throwsA(same(error)));
        expectCalls();
      });
    });
  }
}

class _FakeAsmrApiService extends AsmrApiService {
  _FakeAsmrApiService({required this.works, this.calls});

  List<AsmrWork> works;
  final List<String>? calls;
  Object? error;

  @override
  Future<AsmrWorkPage> searchWorks({
    required String keyword,
    required String order,
    required String sort,
    int page = 1,
    int pageSize = 40,
    String? token,
    AsmrContentLanguage language = AsmrContentLanguage.zh,
    AsmrRequestCancellationToken? cancellationToken,
  }) async {
    calls?.add('asmr:$keyword:${language.name}');
    final failure = error;
    if (failure != null) throw failure;
    return AsmrWorkPage(
      works: works,
      totalCount: works.length,
      currentPage: page,
      pageSize: pageSize,
    );
  }
}

class _FakeDlsiteMetadataService extends DlsiteMetadataService {
  _FakeDlsiteMetadataService({required this.calls, required this.metadata});

  final List<String> calls;
  final DlsiteMetadata metadata;
  Object? error;

  @override
  Future<DlsiteMetadata> fetchByRjCode(
    String rjCode, {
    AppLanguage language = AppLanguage.zh,
  }) async {
    calls.add('dlsite:$rjCode:${language.name}');
    final failure = error;
    if (failure != null) throw failure;
    return metadata;
  }

  @override
  Future<List<DlsiteMetadata>> searchByTitleCandidates(
    Iterable<String> titles, {
    int limit = 10,
    AppLanguage language = AppLanguage.zh,
  }) async => [await fetchByRjCode(titles.single, language: language)];
}

AsmrWork _work({
  required String sourceId,
  required String title,
  DateTime? releaseDate,
  Duration duration = Duration.zero,
  int dlCount = 0,
  double rating = 0,
  String coverUrl = 'https://example.com/cover.jpg',
}) {
  return AsmrWork(
    id: sourceId.hashCode,
    title: title,
    circleName: 'Circle',
    sourceId: sourceId,
    sourceType: 'asmr',
    sourceUrl: '',
    coverUrl: coverUrl,
    thumbnailUrl: '',
    mainCoverUrl: '',
    releaseDate: releaseDate,
    createDate: null,
    duration: duration,
    dlCount: dlCount,
    reviewCount: 0,
    rating: rating,
    voiceActors: const <String>['Voice'],
    tags: const <String>['ASMR'],
  );
}
