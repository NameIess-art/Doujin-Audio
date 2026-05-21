import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/models/asmr_models.dart';
import 'package:nameless_audio/models/music_track.dart';
import 'package:nameless_audio/services/asmr_recommendation_engine.dart';

void main() {
  const engine = AsmrRecommendationEngine();

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
