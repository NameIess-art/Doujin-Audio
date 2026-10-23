import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/app_language.dart';
import 'package:doujin_audio/core/media/dlsite_metadata.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';
import 'package:doujin_audio/features/asmr/application/asmr_api_service.dart';
import 'package:doujin_audio/features/asmr/application/asmr_metadata_service.dart';
import 'package:doujin_audio/features/asmr/application/japanese_asmr_api_service.dart';
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
      _FakeJapaneseAsmrApiService? japanese;
      late LibraryFacade library;

      setUp(() {
        calls = [];
        api = _FakeAsmrApiService(works: [completeWork], calls: calls);
        dlsite = _FakeDlsiteMetadataService(calls: calls, metadata: fallback);
        japanese = null;
      });

      Future<DlsiteMetadata> lookup() async {
        library = LibraryFacade.create(
          databaseRepository: TestPersistenceRepository(),
          asmrMetadataService: AsmrMetadataService(apiService: api),
          metadataService: dlsite,
          japaneseMetadataService: japanese == null
              ? null
              : AsmrMetadataService.japanese(apiService: japanese!),
        );
        addTearDown(library.dispose);
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

      void expectCalls({
        bool asmrRequested = true,
        bool japaneseRequested = false,
      }) {
        expect(calls, [
          'dlsite:${byTitle ? 'Sleep ASMR' : 'RJ123456'}:ja',
          if (asmrRequested) 'asmr:${byTitle ? 'Sleep ASMR' : 'RJ123456'}:ja',
          if (japaneseRequested)
            'japanese:${byTitle ? 'Sleep ASMR' : 'RJ123456'}',
        ]);
      }

      test('complete DLsite metadata skips ASMR.ONE', () async {
        final result = await lookup();

        expect(result, same(fallback));
        expectCalls(asmrRequested: false);
      });

      test('DLsite failure falls back directly to ASMR.ONE', () async {
        dlsite.error = StateError('DLsite unavailable');

        expect((await lookup()).workTitle, completeWork.title);
        expectCalls();
      });

      test('no DLsite match falls back to ASMR.ONE', () async {
        dlsite.error = const DlsiteMetadataException(
          'No DLsite match',
          kind: DlsiteMetadataFailureKind.notFound,
        );

        expect((await lookup()).workTitle, completeWork.title);
        expectCalls();
      });

      test(
        'ASMR.ONE fills missing fields and preserves DLsite values',
        () async {
          dlsite.metadata = fallback.copyWith(
            releaseDate: null,
            duration: null,
            salesCount: null,
            rating: null,
          );

          final result = await lookup();

          expect(result.workTitle, fallback.workTitle);
          expect(result.circleName, fallback.circleName);
          expect(result.voiceActors, fallback.voiceActors);
          expect(result.tags, fallback.tags);
          expect(result.coverUrl, fallback.coverUrl);
          expect(result.releaseDate, completeWork.releaseDate);
          expect(result.duration, completeWork.duration);
          expect(result.salesCount, completeWork.dlCount);
          expect(result.rating, completeWork.rating);
          expectCalls();
        },
      );

      test('missing cover also requests ASMR.ONE supplementation', () async {
        dlsite.metadata = fallback.copyWith(coverUrl: '');

        final result = await lookup();

        expect(result.coverUrl, completeWork.coverUrl);
        expect(result.workTitle, fallback.workTitle);
        expect(result.releaseDate, fallback.releaseDate);
        expectCalls();
      });

      test('ASMR.ONE failure retains available DLsite metadata', () async {
        dlsite.metadata = fallback.copyWith(duration: null);
        api.error = StateError('ASMR.ONE unavailable');

        final result = await lookup();

        expect(result.workTitle, fallback.workTitle);
        expect(result.duration, isNull);
        expectCalls();
      });

      test('both sources failing reports the ASMR.ONE failure', () async {
        dlsite.error = StateError('DLsite unavailable');
        final error = StateError('ASMR.ONE unavailable');
        api.error = error;

        await expectLater(lookup(), throwsA(same(error)));
        expectCalls();
      });

      group('Japanese ASMR fallback', () {
        setUp(() {
          japanese = _FakeJapaneseAsmrApiService(
            calls: calls,
            works: [
              _work(
                sourceId: 'RJ123456',
                title: 'Japanese Sleep ASMR',
                releaseDate: DateTime(2022),
                duration: const Duration(hours: 3),
                dlCount: 9876,
                rating: 3.5,
                coverUrl: 'https://example.com/japanese.jpg',
              ),
            ],
          );
          addTearDown(japanese!.close);
        });

        test('complete DLsite metadata skips both later sources', () async {
          expect(await lookup(), same(fallback));
          expectCalls(asmrRequested: false);
        });

        test('complete ASMR.ONE fallback skips Japanese ASMR', () async {
          dlsite.error = StateError('DLsite unavailable');

          expect((await lookup()).workTitle, completeWork.title);
          expectCalls();
        });

        test('ASMR.ONE completing DLsite fields skips Japanese ASMR', () async {
          dlsite.metadata = fallback.copyWith(duration: null);

          final result = await lookup();

          expect(result.workTitle, fallback.workTitle);
          expect(result.duration, completeWork.duration);
          expectCalls();
        });

        test('first two failures fall back to Japanese ASMR', () async {
          api.error = StateError('ASMR.ONE unavailable');
          dlsite.error = StateError('DLsite unavailable');

          final result = await lookup();

          expect(result.rjCode, 'RJ123456');
          expect(result.workTitle, 'Japanese Sleep ASMR');
          expect(result.coverUrl, japanese!.works.single.coverUrl);
          expectCalls(japaneseRequested: true);
        });

        test(
          'regional restriction remains visible after fallback merges',
          () async {
            dlsite.metadata = DlsiteMetadata(
              rjCode: 'RJ123456',
              workTitle: fallback.workTitle,
              circleName: fallback.circleName,
              voiceActors: const [],
              tags: const [],
              dlsiteRegionRestricted: true,
            );
            api.error = StateError('ASMR.ONE unavailable');

            final result = await lookup();

            expect(result.dlsiteRegionRestricted, isTrue);
            expect(result.workTitle, fallback.workTitle);
            expect(result.voiceActors, ['Voice']);
            expect(result.releaseDate, japanese!.works.single.releaseDate);
            expect(
              result.copyWith(workTitle: 'Edited').dlsiteRegionRestricted,
              isTrue,
            );
            expectCalls(japaneseRequested: true);
          },
        );

        test(
          'each source fills gaps without replacing earlier values',
          () async {
            api.works = [
              _work(sourceId: 'RJ123456', title: 'Sleep ASMR', coverUrl: ''),
            ];
            dlsite.metadata = fallback.copyWith(
              duration: null,
              salesCount: null,
              rating: null,
              coverUrl: '',
            );

            final result = await lookup();

            expect(result.workTitle, fallback.workTitle);
            expect(result.circleName, fallback.circleName);
            expect(result.voiceActors, fallback.voiceActors);
            expect(result.tags, fallback.tags);
            expect(result.releaseDate, fallback.releaseDate);
            expect(result.duration, japanese!.works.single.duration);
            expect(result.salesCount, japanese!.works.single.dlCount);
            expect(result.rating, japanese!.works.single.rating);
            expect(result.coverUrl, japanese!.works.single.coverUrl);
            expectCalls(japaneseRequested: true);
          },
        );

        test('Japanese ASMR failure retains already merged values', () async {
          api.works = [_work(sourceId: 'RJ123456', title: 'Sleep ASMR')];
          dlsite.metadata = fallback.copyWith(duration: null);
          japanese!.error = StateError('Japanese ASMR unavailable');

          final result = await lookup();

          expect(result.workTitle, fallback.workTitle);
          expect(result.releaseDate, fallback.releaseDate);
          expect(result.salesCount, fallback.salesCount);
          expect(result.duration, isNull);
          expectCalls(japaneseRequested: true);
        });

        test('all sources failing reports the Japanese ASMR failure', () async {
          api.error = StateError('ASMR.ONE unavailable');
          dlsite.error = StateError('DLsite unavailable');
          final error = StateError('Japanese ASMR unavailable');
          japanese!.error = error;

          await expectLater(lookup(), throwsA(same(error)));
          expectCalls(japaneseRequested: true);
        });

        test('all sources missing reports a not-found result', () async {
          api.works = [];
          dlsite.error = const DlsiteMetadataException(
            'No DLsite match',
            kind: DlsiteMetadataFailureKind.notFound,
          );
          japanese!.works = [];

          await expectLater(
            lookup(),
            throwsA(
              isA<DlsiteMetadataException>().having(
                (error) => error.isNotFound,
                'isNotFound',
                isTrue,
              ),
            ),
          );
          expectCalls(japaneseRequested: true);
        });

        if (byTitle) {
          test(
            'single candidates with different RJ codes never merge',
            () async {
              dlsite.metadata = fallback.copyWith(
                duration: null,
                releaseDate: null,
                salesCount: null,
                rating: null,
              );
              api.works = [_work(sourceId: 'RJ234567', title: 'Sleep ASMR')];
              japanese!.works = [
                _work(
                  sourceId: 'RJ345678',
                  title: 'Japanese Sleep ASMR',
                  duration: const Duration(hours: 3),
                  dlCount: 9876,
                  rating: 3.5,
                ),
              ];

              final result = await lookup();

              expect(result.rjCode, 'RJ123456');
              expect(result.workTitle, fallback.workTitle);
              expect(result.releaseDate, isNull);
              expect(result.duration, isNull);
              expect(result.salesCount, isNull);
              expect(result.rating, isNull);
              expectCalls(japaneseRequested: true);
            },
          );
        }
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
  DlsiteMetadata metadata;
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

class _FakeJapaneseAsmrApiService extends JapaneseAsmrApiService {
  _FakeJapaneseAsmrApiService({required this.works, required this.calls});

  List<AsmrWork> works;
  final List<String> calls;
  Object? error;

  @override
  Future<AsmrWorkPage> searchWorks({
    required String keyword,
    int page = 1,
    int pageSize = 40,
    AsmrRequestCancellationToken? cancellationToken,
  }) async {
    calls.add('japanese:$keyword');
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
