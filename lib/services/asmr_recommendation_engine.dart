import 'dart:math';

import '../models/audio_detail.dart';
import '../models/asmr_models.dart';
import '../models/music_track.dart';

class AsmrRecommendationEngine {
  const AsmrRecommendationEngine();

  List<AsmrWork> rank({
    required List<AsmrWork> candidates,
    required List<MusicTrack> localTracks,
    required List<AsmrWork> favoriteWorks,
    required List<AsmrWork> historyWorks,
    int refreshSeed = 0,
    int? limit,
  }) {
    final profile = _RecommendationProfile.build(
      localTracks: localTracks,
      favoriteWorks: favoriteWorks,
      historyWorks: historyWorks,
    );
    final stats = _CandidateStats.build(candidates);
    final scored = <_ScoredWork>[
      for (final work in candidates)
        if (!profile.hasSeen(work))
          _ScoredWork(work: work, score: _score(work, profile, stats)),
    ];
    scored.sort((a, b) {
      final scoreOrder = b.score.compareTo(a.score);
      if (scoreOrder != 0) return scoreOrder;
      return a.work.id.compareTo(b.work.id);
    });
    return _rankForRefresh(scored, refreshSeed: refreshSeed, limit: limit);
  }

  double _score(
    AsmrWork work,
    _RecommendationProfile profile,
    _CandidateStats stats,
  ) {
    final tagScore = _termScore(
      profile.tagWeights,
      work.tags,
      stats.tagCounts,
      stats.totalWorks,
    );
    final circleScore = _termScore(
      profile.circleWeights,
      <String>[work.circleName],
      stats.circleCounts,
      stats.totalWorks,
    );
    final voiceActorScore = _termScore(
      profile.voiceActorWeights,
      work.voiceActors,
      stats.voiceActorCounts,
      stats.totalWorks,
    );
    final quality = _qualityScore(work);
    final freshness = _freshnessScore(work);
    if (!profile.hasTasteSignals) {
      return quality * 0.82 + freshness * 0.18;
    }
    final preference =
        tagScore * 0.5 + voiceActorScore * 0.25 + circleScore * 0.14;
    final nicheBonus = _nicheScore(work) * min(1.0, preference) * 0.06;
    return preference + quality * 0.08 + freshness * 0.03 + nicheBonus;
  }

  double _termScore(
    Map<String, double> weights,
    Iterable<String> terms,
    Map<String, int> candidateCounts,
    int totalWorks,
  ) {
    var score = 0.0;
    final seenTerms = <String>{};
    for (final term in terms.map(_normalizeTerm)) {
      if (term.isEmpty) continue;
      if (!seenTerms.add(term)) continue;
      final weight = weights[term];
      if (weight == null || weight <= 0) continue;
      score +=
          sqrt(weight) *
          _rarityMultiplier(candidateCounts[term] ?? 0, totalWorks);
    }
    return score;
  }

  double _qualityScore(AsmrWork work) {
    final rating = work.rating <= 0 ? 0.0 : (work.rating.clamp(0, 5) / 5) * 0.6;
    final sales = log(work.dlCount + 1) / log(100000 + 1) * 0.25;
    final reviews = log(work.reviewCount + 1) / log(10000 + 1) * 0.15;
    return rating + sales.clamp(0, 0.25) + reviews.clamp(0, 0.15);
  }

  double _nicheScore(AsmrWork work) {
    final sales = log(work.dlCount + 1) / log(100000 + 1);
    final reviews = log(work.reviewCount + 1) / log(10000 + 1);
    final popularity = (sales * 0.75 + reviews * 0.25).clamp(0.0, 1.0);
    final confidence = work.rating <= 0 ? 0.35 : work.rating.clamp(0, 5) / 5;
    return (1 - popularity) * confidence;
  }

  double _freshnessScore(AsmrWork work) {
    final date = work.releaseDate ?? work.createDate;
    if (date == null) return 0;
    final ageDays = DateTime.now().difference(date).inDays;
    if (ageDays <= 0) return 1;
    return exp(-ageDays / 730).clamp(0.0, 1.0);
  }

  double _rarityMultiplier(int count, int totalWorks) {
    if (count <= 0 || totalWorks <= 1) return 1;
    return (log(totalWorks + 1) / log(count + 1)).clamp(1.0, 2.4);
  }

  List<AsmrWork> _rankForRefresh(
    List<_ScoredWork> scored, {
    required int refreshSeed,
    required int? limit,
  }) {
    if (scored.isEmpty) {
      return const <AsmrWork>[];
    }

    final ranked = refreshSeed <= 0
        ? scored
        : _diversifyForRefresh(scored, refreshSeed);
    final visible = limit == null || ranked.length <= limit
        ? ranked
        : ranked.take(limit);
    return visible.map((item) => item.work).toList(growable: false);
  }

  List<_ScoredWork> _diversifyForRefresh(
    List<_ScoredWork> scored,
    int refreshSeed,
  ) {
    var minScore = double.infinity;
    var maxScore = double.negativeInfinity;
    for (final item in scored) {
      minScore = min(minScore, item.score);
      maxScore = max(maxScore, item.score);
    }

    final scoreRange = maxScore - minScore;
    final keyed = <_RefreshScoredWork>[
      for (final item in scored)
        _RefreshScoredWork(
          item: item,
          key: scoreRange <= 0
              ? _seededUnit(refreshSeed, item.work.id)
              : ((item.score - minScore) / scoreRange) * 0.74 +
                    _seededUnit(refreshSeed, item.work.id) * 0.26,
        ),
    ];
    keyed.sort((a, b) {
      final keyOrder = b.key.compareTo(a.key);
      if (keyOrder != 0) return keyOrder;
      return a.item.work.id.compareTo(b.item.work.id);
    });
    return keyed.map((item) => item.item).toList(growable: false);
  }

  double _seededUnit(int seed, int workId) {
    final random = Random(seed ^ (workId * 0x1fffffff));
    return random.nextDouble();
  }
}

class _RecommendationProfile {
  _RecommendationProfile({
    required this.tagWeights,
    required this.circleWeights,
    required this.voiceActorWeights,
    required this.seenWorkIds,
    required this.seenRjCodes,
  });

  final Map<String, double> tagWeights;
  final Map<String, double> circleWeights;
  final Map<String, double> voiceActorWeights;
  final Set<int> seenWorkIds;
  final Set<String> seenRjCodes;

  bool get hasTasteSignals =>
      tagWeights.isNotEmpty ||
      circleWeights.isNotEmpty ||
      voiceActorWeights.isNotEmpty;

  bool hasSeen(AsmrWork work) {
    return seenWorkIds.contains(work.id) ||
        seenRjCodes.contains(_normalizeTerm(work.rjCode));
  }

  static _RecommendationProfile build({
    required List<MusicTrack> localTracks,
    required List<AsmrWork> favoriteWorks,
    required List<AsmrWork> historyWorks,
  }) {
    final builder = _RecommendationProfileBuilder();
    final favoriteWeight = favoriteWorks.isEmpty
        ? 0.0
        : 0.4 / favoriteWorks.length;
    for (final work in favoriteWorks) {
      builder.addWork(work, favoriteWeight, seen: true);
    }
    final historyWeight = historyWorks.isEmpty
        ? 0.0
        : 0.1 / historyWorks.length;
    for (final work in historyWorks) {
      builder.addWork(work, historyWeight, seen: true);
    }
    final localWeight = localTracks.isEmpty ? 0.0 : 0.5 / localTracks.length;
    for (final track in localTracks) {
      builder.addTrack(track, localWeight);
    }
    return builder.build();
  }
}

class _RecommendationProfileBuilder {
  final Map<String, double> tagWeights = <String, double>{};
  final Map<String, double> circleWeights = <String, double>{};
  final Map<String, double> voiceActorWeights = <String, double>{};
  final Set<int> seenWorkIds = <int>{};
  final Set<String> seenRjCodes = <String>{};

  void addWork(AsmrWork work, double weight, {required bool seen}) {
    if (seen) {
      seenWorkIds.add(work.id);
      final rj = _normalizeTerm(work.rjCode);
      if (rj.isNotEmpty) seenRjCodes.add(rj);
    }
    _addAll(tagWeights, work.tags, weight);
    _add(circleWeights, work.circleName, weight);
    _addAll(voiceActorWeights, work.voiceActors, weight);
  }

  void addTrack(MusicTrack track, double weight) {
    _addAll(tagWeights, track.tags, weight);
    _add(circleWeights, track.groupTitle, weight);
    _addSeenTrack(track);
    final metadata = track.remoteMetadata;
    if (metadata == null) return;
    _addWorkMetadata(metadata, weight);
  }

  void _addWorkMetadata(Map<String, Object?> metadata, double weight) {
    final id = (metadata['id'] as num?)?.toInt();
    if (id != null) seenWorkIds.add(id);
    _add(circleWeights, metadata['circleName']?.toString(), weight);
    _addAll(tagWeights, _stringList(metadata['tags']), weight);
    _addAll(voiceActorWeights, _stringList(metadata['voiceActors']), weight);
    _addAll(voiceActorWeights, _stringList(metadata['vas']), weight);
    final sourceId = _normalizeTerm(metadata['sourceId']?.toString() ?? '');
    if (sourceId.isNotEmpty) seenRjCodes.add(sourceId);
  }

  void _addSeenTrack(MusicTrack track) {
    for (final value in <String>[
      track.groupSubtitle,
      AudioDetail.findRjCodeInText(track.path) ?? '',
      AudioDetail.findRjCodeInText(track.groupTitle) ?? '',
      AudioDetail.findRjCodeInText(track.displayName) ?? '',
    ]) {
      final rj = _normalizeTerm(value);
      if (rj.isNotEmpty) seenRjCodes.add(rj);
    }
  }

  _RecommendationProfile build() {
    return _RecommendationProfile(
      tagWeights: Map<String, double>.unmodifiable(tagWeights),
      circleWeights: Map<String, double>.unmodifiable(circleWeights),
      voiceActorWeights: Map<String, double>.unmodifiable(voiceActorWeights),
      seenWorkIds: Set<int>.unmodifiable(seenWorkIds),
      seenRjCodes: Set<String>.unmodifiable(seenRjCodes),
    );
  }
}

class _CandidateStats {
  const _CandidateStats({
    required this.totalWorks,
    required this.tagCounts,
    required this.circleCounts,
    required this.voiceActorCounts,
  });

  final int totalWorks;
  final Map<String, int> tagCounts;
  final Map<String, int> circleCounts;
  final Map<String, int> voiceActorCounts;

  static _CandidateStats build(List<AsmrWork> works) {
    final tagCounts = <String, int>{};
    final circleCounts = <String, int>{};
    final voiceActorCounts = <String, int>{};
    for (final work in works) {
      _addUniqueCounts(tagCounts, work.tags);
      _addUniqueCounts(circleCounts, <String>[work.circleName]);
      _addUniqueCounts(voiceActorCounts, work.voiceActors);
    }
    return _CandidateStats(
      totalWorks: works.length,
      tagCounts: Map<String, int>.unmodifiable(tagCounts),
      circleCounts: Map<String, int>.unmodifiable(circleCounts),
      voiceActorCounts: Map<String, int>.unmodifiable(voiceActorCounts),
    );
  }
}

class _ScoredWork {
  const _ScoredWork({required this.work, required this.score});

  final AsmrWork work;
  final double score;
}

class _RefreshScoredWork {
  const _RefreshScoredWork({required this.item, required this.key});

  final _ScoredWork item;
  final double key;
}

void _add(Map<String, double> target, String? raw, double weight) {
  final term = _normalizeTerm(raw ?? '');
  if (term.isEmpty || weight <= 0) return;
  target[term] = (target[term] ?? 0) + weight;
}

void _addAll(Map<String, double> target, Iterable<String> raw, double weight) {
  for (final value in raw) {
    _add(target, value, weight);
  }
}

void _addUniqueCounts(Map<String, int> target, Iterable<String> raw) {
  final terms = <String>{};
  for (final value in raw) {
    final term = _normalizeTerm(value);
    if (term.isNotEmpty) terms.add(term);
  }
  for (final term in terms) {
    target[term] = (target[term] ?? 0) + 1;
  }
}

String _normalizeTerm(String value) => value.trim().toLowerCase();

List<String> _stringList(Object? value) {
  return (value as List<dynamic>? ?? const <dynamic>[])
      .map((item) {
        if (item is String) return item;
        if (item is Map<Object?, Object?>) {
          return item['name']?.toString() ?? '';
        }
        return '';
      })
      .where((item) => item.trim().isNotEmpty)
      .toList(growable: false);
}
