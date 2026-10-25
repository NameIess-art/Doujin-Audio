import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/features/asmr/application/asmr_recommendation_engine.dart';

void main() {
  const engine = AsmrRecommendationEngine();

  test(
    'circle interests affect daily and asynchronous recommendations',
    () async {
      final candidates = [
        for (var i = 0; i < 50; i++)
          work(
            id: i + 1,
            title: 'Work $i',
            circleName: i < 20 ? 'Favorite' : 'Other $i',
          ),
      ];
      final daily = engine.rankDaily(
        candidates: candidates,
        daySeed: 20261025,
        circleWeights: {' favorite ': 1},
      );
      expect(
        daily.where((work) => work.circleName == 'Favorite'),
        hasLength(20),
      );
      final ranked = await engine.rankAsync(
        candidates: candidates,
        localTracks: [],
        favoriteWorks: [],
        historyWorks: [],
        circleWeights: {'favorite': 1},
      );
      expect(ranked.first.circleName, 'Favorite');
      final other = engine.rank(
        candidates: candidates,
        localTracks: [],
        favoriteWorks: [],
        historyWorks: [],
        circleWeights: {'other 49': 1},
      );
      expect(other.first.circleName, 'Other 49');
    },
  );

  test(
    'manual and listened voice interests affect both recommendation styles',
    () async {
      final candidates = [
        for (var i = 0; i < 50; i++)
          work(
            id: i + 1,
            title: 'Voice $i',
            voiceActors: [i < 20 ? 'Favorite' : 'Other $i'],
          ),
      ];
      final daily = engine.rankDaily(
        candidates: candidates,
        daySeed: 20261024,
        voiceActorWeights: {' favorite ': 1},
      );
      expect(
        daily.where((w) => w.voiceActors.contains('Favorite')),
        hasLength(20),
      );
      final ranked = await engine.rankAsync(
        candidates: candidates,
        localTracks: [],
        favoriteWorks: [],
        historyWorks: [],
        voiceActorWeights: {'favorite': 1},
      );
      expect(ranked.first.voiceActors, ['Favorite']);
      final other = engine.rank(
        candidates: candidates,
        localTracks: [],
        favoriteWorks: [],
        historyWorks: [],
        voiceActorWeights: {'other 49': 1},
      );
      expect(other.first.voiceActors, ['Other 49']);
    },
  );

  test('daily recommendations only include interested voices or circles', () {
    final candidates = [
      work(id: 1, title: 'Voice', voiceActors: ['Mika']),
      work(id: 2, title: 'Circle', circleName: 'Dream'),
      work(id: 3, title: 'Both', voiceActors: ['Mika'], circleName: 'Dream'),
      work(id: 4, title: 'Tag only', tags: ['Sleep'], rating: 5),
      work(id: 5, title: 'Other creator', voiceActors: ['Other']),
    ];
    final ranking = engine.rankDaily(
      candidates: candidates,
      daySeed: 20261024,
      voiceActorWeights: {' mika ': 1},
      circleWeights: {' DREAM ': 1},
    );
    expect(ranking.map((work) => work.id), unorderedEquals([1, 2, 3]));
    expect(
      engine
          .rankDaily(
            candidates: candidates.reversed.toList(),
            daySeed: 20261024,
            voiceActorWeights: {' mika ': 1},
            circleWeights: {' DREAM ': 1},
          )
          .map((w) => w.workKey),
      ranking.map((w) => w.workKey),
    );
  });

  test(
    'daily recommendations put new releases first and fill with old works',
    () {
      final ranked = engine.rankDaily(
        candidates: [
          for (var id = 1; id <= 25; id++)
            work(
              id: id,
              title: 'Old $id',
              voiceActors: ['Mika'],
              releaseDate: DateTime(2020, 1, id),
              rating: 5,
            ),
          work(
            id: 26,
            title: 'Recent',
            voiceActors: ['Mika'],
            releaseDate: DateTime(2026, 10),
          ),
          work(
            id: 27,
            title: 'Newest',
            voiceActors: ['Mika'],
            releaseDate: DateTime(2026, 10, 25),
          ),
        ],
        daySeed: 20261025,
        voiceActorWeights: {'Mika': 1},
      );
      expect(ranked, hasLength(20));
      expect(ranked.take(2).map((work) => work.id), [27, 26]);
      expect(ranked.skip(2).every((work) => work.id <= 25), isTrue);
    },
  );

  test('daily new release priority survives yesterday repetition', () {
    final newest = work(
      id: 1,
      title: 'Newest',
      circleName: 'Dream',
      releaseDate: DateTime(2026, 10, 25),
    );
    final ranked = engine.rankDaily(
      candidates: [
        newest,
        work(
          id: 2,
          title: 'Earlier new work',
          circleName: 'Dream',
          releaseDate: DateTime(2026, 10, 24),
          rating: 5,
        ),
        work(id: 3, title: 'Old work', circleName: 'Dream', rating: 5),
      ],
      daySeed: 20261025,
      circleWeights: {'Dream': 1},
      previousWorkKeys: {newest.workKey},
    );
    expect(ranked.map((work) => work.id), [1, 2, 3]);
  });

  test('daily uses creation date only when release date is absent', () {
    final ranked = engine.rankDaily(
      candidates: [
        work(id: 1, title: 'No date', circleName: 'Dream', rating: 5),
        work(
          id: 2,
          title: 'Recent upload of old release',
          circleName: 'Dream',
          releaseDate: DateTime(2020),
          createDate: DateTime(2026, 10, 25),
          rating: 5,
        ),
        work(
          id: 3,
          title: 'Creation date fallback',
          circleName: 'Dream',
          createDate: DateTime(2026, 10, 24),
        ),
      ],
      daySeed: 20261025,
      circleWeights: {'Dream': 1},
    );
    expect(ranked.first.id, 3);
    expect(ranked.skip(1).map((work) => work.id), unorderedEquals([1, 2]));
  });

  test(
    'daily new release range excludes future and older than thirty days',
    () {
      final ranked = engine.rankDaily(
        candidates: [
          work(
            id: 1,
            title: 'Future',
            releaseDate: DateTime(2026, 10, 26),
            createDate: DateTime(2026, 10, 25),
            rating: 5,
          ),
          work(
            id: 2,
            title: 'Thirty one days old',
            releaseDate: DateTime(2026, 9, 24),
            rating: 5,
          ),
          work(
            id: 3,
            title: 'Thirty days old',
            releaseDate: DateTime(2026, 9, 25),
          ),
          work(
            id: 4,
            title: 'Released today at a later hour',
            releaseDate: DateTime(2026, 10, 25, 23, 59),
          ),
        ],
        daySeed: 20261025,
        circleWeights: {'Circle': 1},
      );
      expect(ranked.take(2).map((work) => work.id), [4, 3]);
      expect(ranked.skip(2).map((work) => work.id), unorderedEquals([1, 2]));
    },
  );

  test('daily does not fill missing creator matches with unrelated works', () {
    final candidates = [
      for (var id = 1; id <= 40; id++)
        work(
          id: id,
          title: 'Work $id',
          voiceActors: [id <= 4 ? 'Mika' : 'Other'],
          tags: ['Sleep'],
        ),
    ];
    final ranked = engine.rankDaily(
      candidates: candidates,
      daySeed: 5,
      voiceActorWeights: {'Mika': 1},
    );
    expect(ranked, hasLength(4));
    expect(ranked.every((work) => work.voiceActors.contains('Mika')), isTrue);
    expect(
      engine.rankDaily(
        candidates: candidates,
        daySeed: 5,
        circleWeights: {'Missing': 1},
      ),
      isEmpty,
    );
  });

  test('daily cold start ignores tags and nonpositive creator interests', () {
    final candidates = [
      for (var id = 1; id <= 40; id++)
        work(id: id, title: 'Work $id', tags: ['Sleep']),
    ];
    final ranked = engine.rankDaily(candidates: candidates, daySeed: 5);
    final withoutTags = engine.rankDaily(
      candidates: [
        for (final candidate in candidates)
          work(id: candidate.id, title: candidate.title),
      ],
      daySeed: 5,
      voiceActorWeights: {'Mika': 0, ' ': 1},
      circleWeights: {'Dream': -1, '': 1},
    );
    expect(ranked, hasLength(20));
    expect(
      ranked.map((work) => work.workKey),
      withoutTags.map((work) => work.workKey),
    );
  });

  test(
    'daily discovery deduplicates, keeps quality and defaults to twenty',
    () {
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
    },
  );

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

  for (final dimension in ['voice', 'circle']) {
    test(
      'daily discovery spreads across $dimension instead of one large group',
      () {
        final candidates = [
          for (var id = 1; id <= 45; id++)
            work(
              id: id,
              title: 'Work $id',
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
