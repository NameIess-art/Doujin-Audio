import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_tag_interest.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/features/asmr/application/asmr_recommendation_engine.dart';

void main() {
  const engine = AsmrRecommendationEngine();

  for (final dimension in ['tag', 'voice', 'circle']) {
    AsmrWork match(int id, String name, {double rating = 0}) => work(
      id: id,
      title: '$dimension $name',
      tags: dimension == 'tag' ? [name] : [],
      voiceActors: dimension == 'voice' ? [name] : [],
      circleName: dimension == 'circle' ? name : '',
      rating: rating,
    );

    List<AsmrWork> rankWithWeights(
      List<AsmrWork> candidates,
      Map<String, double> weights,
    ) => engine.rank(
      candidates: candidates,
      localTracks: [],
      favoriteWorks: [],
      historyWorks: [],
      tagWeights: dimension == 'tag' ? weights : {},
      voiceActorWeights: dimension == 'voice' ? weights : {},
      circleWeights: dimension == 'circle' ? weights : {},
    );

    test(
      '$dimension ranking respects listening time, manual and excluded tastes',
      () {
        final preferences = AsmrTagPreferences();
        preferences.recordListeningBatch('test:1', [
          (tags: ['Frequent'], duration: const Duration(minutes: 120)),
          (tags: ['Occasional'], duration: const Duration(minutes: 30)),
          (tags: ['Blocked'], duration: const Duration(minutes: 200)),
        ]);
        preferences.setInterested(preferences.resolve('Manual'), true);
        preferences.setInterested(preferences.resolve('Blocked'), true);
        preferences.excluded.add(preferences.resolve('Blocked'));
        final ranked = rankWithWeights([
          match(1, 'Manual'),
          match(2, 'Occasional'),
          match(3, 'Frequent'),
          match(4, 'Quality only', rating: 5),
          match(5, 'Blocked'),
        ], preferences.recommendationWeights);
        expect(ranked.map((work) => work.id), [1, 3, 2, 4, 5]);
      },
    );

    test(
      '$dimension explicit empty weights replace local and favorite tastes',
      () {
        final candidates = [
          match(1, 'Quality only', rating: 1),
          match(2, 'Implicit'),
        ];
        final favorites = [match(10, 'Implicit')];
        final localTracks = [
          track(groupTitle: 'Implicit', tags: ['Implicit']).copyWith(
            remoteMetadata: {
              'voiceActors': ['Implicit'],
            },
          ),
        ];
        final explicitEmpty = engine.rank(
          candidates: candidates,
          localTracks: localTracks,
          favoriteWorks: favorites,
          historyWorks: [],
          tagWeights: {},
          voiceActorWeights: {},
          circleWeights: {},
        );
        final implicit = engine.rank(
          candidates: candidates,
          localTracks: localTracks,
          favoriteWorks: favorites,
          historyWorks: [],
          tagWeights: dimension == 'tag' ? null : {},
          voiceActorWeights: dimension == 'voice' ? null : {},
          circleWeights: dimension == 'circle' ? null : {},
        );
        expect(explicitEmpty.map((work) => work.id), [1, 2]);
        expect(implicit.map((work) => work.id), [2, 1]);
      },
    );

    test(
      '$dimension explicit weights normalize names and reject invalid values',
      () {
        final candidates = [
          match(1, 'Invalid'),
          match(2, 'High'),
          match(3, 'Low'),
          match(4, 'NaN'),
          match(5, 'Negative'),
          match(6, 'Zero'),
        ];
        final ranked = rankWithWeights(candidates, {
          ' HIGH ': 1,
          'high': 0.1,
          ' low ': 0.25,
          'invalid': double.infinity,
          'nan': double.nan,
          'negative': -1,
          'zero': 0,
          ' ': 100,
        });
        expect(ranked.take(2).map((work) => work.id), [2, 3]);
        expect(
          rankWithWeights(candidates, {
            'invalid': double.infinity,
            'nan': double.nan,
          }).map((work) => work.id),
          rankWithWeights(candidates, {}).map((work) => work.id),
        );
      },
    );
  }

  test('circle interests affect asynchronous recommendations', () async {
    final candidates = [
      for (var i = 0; i < 50; i++)
        work(
          id: i + 1,
          title: 'Work $i',
          circleName: i < 20 ? 'Favorite' : 'Other $i',
        ),
    ];
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
  });

  test('manual and listened voice interests affect recommendations', () async {
    final candidates = [
      for (var i = 0; i < 50; i++)
        work(
          id: i + 1,
          title: 'Voice $i',
          voiceActors: [i < 20 ? 'Favorite' : 'Other $i'],
        ),
    ];
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
  });

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
    releaseDate: null,
    createDate: null,
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
