import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/features/asmr/application/asmr_recommendation_engine.dart';

void main() {
  const engine = AsmrRecommendationEngine();

  test('daily discovery deduplicates, keeps quality and defaults to twenty', () {
    final better = work(id: 1, title: 'Better duplicate', rating: 5);
    final ranked = engine.rankDaily(
      candidates: [
        work(id: 1, title: 'Duplicate'),
        better,
        for (var id = 2; id <= 30; id++) work(id: id, title: 'Work $id'),
      ],
      daySeed: 20261024,
    );
    expect(ranked, hasLength(20));
    expect(ranked.map((item) => item.workKey).toSet(), hasLength(20));
    final reserve = engine.rankDaily(
      candidates: [
        for (var id = 1; id <= 100; id++) work(id: id, title: 'Work $id'),
      ],
      daySeed: 20261024,
      limit: 80,
    );
    expect(reserve, hasLength(80));
    expect(reserve.map((item) => item.workKey).toSet(), hasLength(80));
    final duplicateOnly = engine.rankDaily(
      candidates: [
        work(id: 1, title: 'Duplicate'),
        better,
      ],
      daySeed: 1,
    );
    expect(duplicateOnly.single, same(better));
    expect(
      engine.rankDaily(candidates: [better], daySeed: 1, limit: 0),
      isEmpty,
    );
    expect(engine.rankDaily(candidates: [], daySeed: 1), isEmpty);
  });

  test('daily discovery is stable regardless of candidate ordering', () {
    final candidates = [
      for (var id = 1; id <= 100; id++)
        work(id: id, title: 'Work $id', tags: ['Tag ${id % 10}']),
    ];
    List<String> keys(List<AsmrWork> works, int seed) => engine
        .rankDaily(candidates: works, daySeed: seed)
        .map((item) => item.workKey)
        .toList();
    expect(
      keys(candidates, 20261024),
      keys(candidates.reversed.toList(), 20261024),
    );
    expect(
      keys(candidates, 20261024).toSet(),
      isNot(keys(candidates, 20261025).toSet()),
    );
  });

  test(
    'daily discovery avoids yesterday and fills when candidates are few',
    () {
      final candidates = [
        for (var id = 1; id <= 30; id++) work(id: id, title: 'Work $id'),
      ];
      final previous = candidates.take(10).map((item) => item.workKey).toSet();
      final ranked = engine.rankDaily(
        candidates: candidates,
        daySeed: 20261024,
        previousWorkKeys: previous,
      );
      expect(ranked.every((item) => !previous.contains(item.workKey)), isTrue);
      final small = engine.rankDaily(
        candidates: candidates.take(12).toList(),
        daySeed: 20261024,
        previousWorkKeys: previous,
      );
      expect(small, hasLength(12));
      expect(
        small.take(2).every((item) => !previous.contains(item.workKey)),
        isTrue,
      );
    },
  );

  for (final dimension in ['tag', 'voice', 'circle']) {
    test(
      'daily discovery spreads across $dimension instead of one large group',
      () {
        final candidates = [
          for (var id = 1; id <= 45; id++)
            work(
              id: id,
              title: 'Work $id',
              tags: dimension == 'tag' ? ['Tag ${id <= 40 ? 0 : id}'] : [],
              voiceActors: dimension == 'voice'
                  ? ['Voice ${id <= 40 ? 0 : id}']
                  : [],
              circleName: dimension == 'circle'
                  ? 'Circle ${id <= 40 ? 0 : id}'
                  : '',
            ),
        ];
        final ranked = engine.rankDaily(
          candidates: candidates,
          daySeed: 20261024,
        );
        expect(ranked.where((item) => item.id > 40), hasLength(5));
      },
    );
  }

  test('uses source weights as local library, favorites, then history', () {
    final ranked = engine.rank(
      candidates: <AsmrWork>[
        work(id: 1, title: 'History match', tags: <String>['history-tag']),
        work(id: 2, title: 'Favorite match', tags: <String>['favorite-tag']),
        work(id: 3, title: 'Local match', tags: <String>['local-tag']),
      ],
      localTracks: <MusicTrack>[
        track(tags: <String>['local-tag']),
      ],
      favoriteWorks: <AsmrWork>[
        work(id: 10, title: 'Favorite', tags: <String>['favorite-tag']),
      ],
      historyWorks: <AsmrWork>[
        work(id: 11, title: 'History', tags: <String>['history-tag']),
      ],
    );

    expect(ranked.map((item) => item.id), <int>[3, 2, 1]);
  });

  test('weights tag matches above circle matches and quality-only works', () {
    final ranked = engine.rank(
      candidates: <AsmrWork>[
        work(
          id: 1,
          title: 'Quality only',
          rating: 5,
          dlCount: 100000,
          reviewCount: 10000,
        ),
        work(id: 2, title: 'Circle match', circleName: 'Dream Circle'),
        work(id: 3, title: 'Tag match', tags: <String>['sleep']),
      ],
      localTracks: <MusicTrack>[
        track(groupTitle: 'Dream Circle', tags: <String>['sleep']),
      ],
      favoriteWorks: const <AsmrWork>[],
      historyWorks: const <AsmrWork>[],
    );

    expect(ranked.map((item) => item.id), <int>[3, 2, 1]);
  });

  test('uses quality to order works with the same taste matches', () {
    final ranked = engine.rank(
      candidates: <AsmrWork>[
        work(id: 1, title: 'Lower quality', tags: <String>['sleep'], rating: 3),
        work(
          id: 2,
          title: 'Higher quality',
          tags: <String>['sleep'],
          rating: 4.9,
          dlCount: 20000,
          reviewCount: 900,
        ),
      ],
      localTracks: <MusicTrack>[
        track(tags: <String>['sleep']),
      ],
      favoriteWorks: const <AsmrWork>[],
      historyWorks: const <AsmrWork>[],
    );

    expect(ranked.first.id, 2);
  });

  test('keeps rare matching tags ahead of broad quality-only works', () {
    final ranked = engine.rank(
      candidates: <AsmrWork>[
        for (var i = 1; i <= 120; i++)
          work(
            id: i,
            title: 'Popular $i',
            tags: <String>['popular'],
            rating: 5,
            dlCount: 100000,
            reviewCount: 10000,
          ),
        work(id: 999, title: 'Rare match', tags: <String>['deep-relax']),
      ],
      localTracks: <MusicTrack>[
        track(tags: <String>['deep-relax']),
        for (var i = 0; i < 99; i++) track(tags: <String>['common-$i']),
      ],
      favoriteWorks: const <AsmrWork>[],
      historyWorks: const <AsmrWork>[],
      limit: 10,
    );

    expect(ranked.map((item) => item.id), contains(999));
    expect(ranked.first.id, 999);
  });

  test('uses voice actor matches as taste signals', () {
    final ranked = engine.rank(
      candidates: <AsmrWork>[
        work(id: 1, title: 'Quality only', rating: 5, dlCount: 100000),
        work(id: 2, title: 'Voice actor match', voiceActors: <String>['Mika']),
      ],
      localTracks: const <MusicTrack>[],
      favoriteWorks: <AsmrWork>[
        work(id: 10, title: 'Favorite', voiceActors: <String>['Mika']),
      ],
      historyWorks: const <AsmrWork>[],
    );

    expect(ranked.map((item) => item.id), <int>[2, 1]);
  });

  test('removes favorite history and local-owned works from results', () {
    final favorite = work(id: 1, title: 'Favorite', tags: <String>['sleep']);
    final history = work(id: 3, title: 'History', tags: <String>['sleep']);
    final unseen = work(id: 2, title: 'Unseen', tags: <String>['sleep']);
    final localOwned = work(
      id: 4,
      title: 'Local owned',
      sourceId: 'RJ000004',
      tags: <String>['sleep'],
    );

    final ranked = engine.rank(
      candidates: <AsmrWork>[favorite, unseen, history, localOwned],
      localTracks: <MusicTrack>[
        track(groupSubtitle: 'RJ000004', tags: <String>['sleep']),
      ],
      favoriteWorks: <AsmrWork>[favorite],
      historyWorks: <AsmrWork>[history],
    );

    expect(ranked.map((item) => item.id), <int>[2]);
  });

  test('changes limited recommendation content when refresh seed changes', () {
    final first = engine.rank(
      candidates: <AsmrWork>[
        for (var i = 1; i <= 90; i++) work(id: i, title: 'Candidate $i'),
      ],
      localTracks: const <MusicTrack>[],
      favoriteWorks: const <AsmrWork>[],
      historyWorks: const <AsmrWork>[],
      refreshSeed: 1,
      limit: 10,
    );
    final second = engine.rank(
      candidates: <AsmrWork>[
        for (var i = 1; i <= 90; i++) work(id: i, title: 'Candidate $i'),
      ],
      localTracks: const <MusicTrack>[],
      favoriteWorks: const <AsmrWork>[],
      historyWorks: const <AsmrWork>[],
      refreshSeed: 2,
      limit: 10,
    );

    expect(first.map((item) => item.id), isNot(second.map((item) => item.id)));
  });

  test('keeps every recommendation while changing order by refresh seed', () {
    final first = engine.rank(
      candidates: <AsmrWork>[
        for (var i = 1; i <= 90; i++) work(id: i, title: 'Candidate $i'),
      ],
      localTracks: const <MusicTrack>[],
      favoriteWorks: const <AsmrWork>[],
      historyWorks: const <AsmrWork>[],
      refreshSeed: 1,
    );
    final second = engine.rank(
      candidates: <AsmrWork>[
        for (var i = 1; i <= 90; i++) work(id: i, title: 'Candidate $i'),
      ],
      localTracks: const <MusicTrack>[],
      favoriteWorks: const <AsmrWork>[],
      historyWorks: const <AsmrWork>[],
      refreshSeed: 2,
    );

    expect(first, hasLength(90));
    expect(second, hasLength(90));
    expect(
      first.map((item) => item.id).toSet(),
      second.map((item) => item.id).toSet(),
    );
    expect(first.map((item) => item.id), isNot(second.map((item) => item.id)));
  });

  test(
    'refresh mixes the highest scored exploration works every fourth slot',
    () {
      final candidates = [
        for (var id = 1; id <= 60; id++)
          work(
            id: id,
            title: 'Candidate $id',
            rating: id <= 40 ? 3 : 4 + (id - 41) / 100,
          ),
      ];
      final ranked = engine.rank(
        candidates: candidates,
        localTracks: const <MusicTrack>[],
        favoriteWorks: const <AsmrWork>[],
        historyWorks: const <AsmrWork>[],
        refreshSeed: 2,
        explorationWorkIds: {
          for (var id = 41; id <= 60; id++) work(id: id, title: '').workKey,
        },
      );

      expect(
        [for (var index = 3; index < 40; index += 4) ranked[index].id],
        [for (var id = 60; id >= 51; id--) id],
      );
      expect(ranked.map((item) => item.id).toSet(), hasLength(60));
      expect(ranked, hasLength(60));
    },
  );

  test(
    'exploration quota falls back to the original ranking when unavailable',
    () {
      final candidates = [
        for (var id = 1; id <= 20; id++) work(id: id, title: 'Candidate $id'),
      ];
      List<int> ids(Set<int> explorationWorkIds) => engine
          .rank(
            candidates: candidates,
            localTracks: const <MusicTrack>[],
            favoriteWorks: [work(id: 20, title: 'Seen')],
            historyWorks: const <AsmrWork>[],
            refreshSeed: 2,
            explorationWorkIds: explorationWorkIds
                .map((id) => work(id: id, title: '').workKey)
                .toSet(),
            limit: 10,
          )
          .map((item) => item.id)
          .toList();

      expect(ids({20}), ids(const <int>{}));
      expect(ids({19})[3], 19);
      expect(ids({19}), hasLength(10));
    },
  );

  test('falls back to quality when profile is empty', () {
    final ranked = engine.rank(
      candidates: <AsmrWork>[
        work(id: 1, title: 'Unrated'),
        work(
          id: 2,
          title: 'Quality',
          rating: 4.8,
          dlCount: 5000,
          reviewCount: 200,
        ),
      ],
      localTracks: const <MusicTrack>[],
      favoriteWorks: const <AsmrWork>[],
      historyWorks: const <AsmrWork>[],
    );

    expect(ranked.first.id, 2);
  });

  test('rankAsync preserves synchronous ranking for large inputs', () async {
    final candidates = <AsmrWork>[
      for (var index = 1; index <= 120; index++)
        work(
          id: index,
          title: 'Candidate $index',
          tags: <String>['tag-${index % 12}'],
          rating: 3 + (index % 20) / 10,
        ),
    ];
    final localTracks = <MusicTrack>[
      for (var index = 0; index < 1000; index++)
        track(tags: <String>['tag-${index % 12}']),
    ];
    final synchronous = engine.rank(
      candidates: candidates,
      localTracks: localTracks,
      favoriteWorks: const <AsmrWork>[],
      historyWorks: const <AsmrWork>[],
      refreshSeed: 7,
      limit: 40,
      explorationWorkIds: {
        for (var id = 1; id <= 60; id++) work(id: id, title: '').workKey,
      },
    );
    final asynchronous = await engine.rankAsync(
      candidates: candidates,
      localTracks: localTracks,
      favoriteWorks: const <AsmrWork>[],
      historyWorks: const <AsmrWork>[],
      refreshSeed: 7,
      limit: 40,
      explorationWorkIds: {
        for (var id = 1; id <= 60; id++) work(id: id, title: '').workKey,
      },
    );

    expect(
      asynchronous.map((work) => work.id),
      synchronous.map((work) => work.id),
    );
  });

  test('small recommendation inputs are also ranked asynchronously', () async {
    final candidates = <AsmrWork>[work(id: 1, title: 'Candidate')];
    final ranked = engine.rankAsync(
      candidates: candidates,
      localTracks: const <MusicTrack>[],
      favoriteWorks: const <AsmrWork>[],
      historyWorks: const <AsmrWork>[],
    );
    expect((await ranked).map((work) => work.id), [1]);
  });
}

AsmrWork work({
  required int id,
  required String title,
  String circleName = 'Circle',
  String sourceId = '',
  DateTime? releaseDate,
  DateTime? createDate,
  int dlCount = 0,
  int reviewCount = 0,
  double rating = 0,
  List<String> voiceActors = const <String>[],
  List<String> tags = const <String>[],
}) {
  return AsmrWork(
    id: id,
    title: title,
    circleName: circleName,
    sourceId: sourceId.isEmpty
        ? 'RJ${id.toString().padLeft(6, '0')}'
        : sourceId,
    sourceType: 'DLSITE',
    sourceUrl: 'https://example.test/$id',
    coverUrl: '',
    thumbnailUrl: '',
    mainCoverUrl: '',
    releaseDate: releaseDate,
    createDate: createDate,
    duration: Duration.zero,
    dlCount: dlCount,
    reviewCount: reviewCount,
    rating: rating,
    voiceActors: voiceActors,
    tags: tags,
  );
}

MusicTrack track({
  String groupTitle = 'Circle',
  String groupSubtitle = 'RJ999999',
  List<String> tags = const <String>[],
}) {
  return MusicTrack(
    path: '/library/$groupSubtitle/track.mp3',
    displayName: 'track.mp3',
    groupKey: groupSubtitle,
    groupTitle: groupTitle,
    groupSubtitle: groupSubtitle,
    isSingle: false,
    tags: tags,
  );
}
