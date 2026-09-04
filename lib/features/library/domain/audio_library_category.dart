import '../../../core/media/audio_detail.dart';
import '../../../core/media/music_track.dart';
import '../../../core/immutable_collections.dart';

enum AudioLibraryCategoryType { all, tags, voiceActors, circles }

class AudioLibraryCategoryEntry {
  AudioLibraryCategoryEntry({
    required this.target,
    required this.title,
    required this.path,
    required this.isFolder,
    required this.detail,
    required List<MusicTrack> tracks,
  }) : tracks = immutableList(tracks);

  final AudioDetailTarget target;
  final String title;
  final String path;
  final bool isFolder;
  final AudioDetail detail;
  final List<MusicTrack> tracks;

  late final List<String> tagTerms = AudioLibraryCategorySnapshot.splitTerms(
    detail.tags,
  );
  late final List<String> voiceActorTerms =
      AudioLibraryCategorySnapshot.splitTerms(detail.voiceActors);
  late final List<String> circleTerms = AudioLibraryCategorySnapshot.splitTerms(
    <String>[detail.circleName],
  );

  late final Set<String> normalizedTagTerms = _normalizeTerms(tagTerms);
  late final Set<String> normalizedVoiceActorTerms = _normalizeTerms(
    voiceActorTerms,
  );
  late final Set<String> normalizedCircleTerms = _normalizeTerms(circleTerms);

  MusicTrack? get firstTrack => tracks.isEmpty ? null : tracks.first;

  late final String searchableText = [
    title,
    path,
    detail.rjCode,
    detail.workTitle,
    detail.circleName,
    ...detail.voiceActors,
    ...detail.tags,
  ].where((value) => value.trim().isNotEmpty).join('\n').toLowerCase();

  List<String> termsForCategory(AudioLibraryCategoryType type) {
    return switch (type) {
      AudioLibraryCategoryType.tags => tagTerms,
      AudioLibraryCategoryType.voiceActors => voiceActorTerms,
      AudioLibraryCategoryType.circles => circleTerms,
      AudioLibraryCategoryType.all => const <String>[],
    };
  }

  Set<String> normalizedTermsForCategory(AudioLibraryCategoryType type) {
    return switch (type) {
      AudioLibraryCategoryType.tags => normalizedTagTerms,
      AudioLibraryCategoryType.voiceActors => normalizedVoiceActorTerms,
      AudioLibraryCategoryType.circles => normalizedCircleTerms,
      AudioLibraryCategoryType.all => const <String>{},
    };
  }

  static Set<String> _normalizeTerms(Iterable<String> terms) {
    return Set<String>.unmodifiable(terms.map((term) => term.toLowerCase()));
  }
}

class AudioLibraryCategorySnapshot {
  AudioLibraryCategorySnapshot({
    required List<AudioLibraryCategoryEntry> entries,
    required List<String> tagTerms,
    required List<String> voiceActorTerms,
    required List<String> circleTerms,
    required this.structureRevision,
    required this.detailRevision,
  }) : entries = immutableList(entries),
       _entryByTarget = _indexEntries(entries),
       tagTerms = immutableList(tagTerms),
       voiceActorTerms = immutableList(voiceActorTerms),
       circleTerms = immutableList(circleTerms);

  final List<AudioLibraryCategoryEntry> entries;
  final List<String> tagTerms;
  final List<String> voiceActorTerms;
  final List<String> circleTerms;
  final int structureRevision;
  final int detailRevision;
  final Map<AudioDetailTarget, AudioLibraryCategoryEntry> _entryByTarget;

  AudioDetail? detailFor(AudioDetailTarget target) {
    return _entryByTarget[target]?.detail;
  }

  AudioLibraryCategoryEntry? entryFor(AudioDetailTarget target) {
    return _entryByTarget[target];
  }

  static Map<AudioDetailTarget, AudioLibraryCategoryEntry> _indexEntries(
    Iterable<AudioLibraryCategoryEntry> entries,
  ) {
    final result = <AudioDetailTarget, AudioLibraryCategoryEntry>{};
    for (final entry in entries) {
      result.putIfAbsent(entry.target, () => entry);
    }
    return immutableMap(result);
  }

  static String targetKey(AudioDetailTarget target) {
    return '${target.targetType.dbValue}|${target.targetPath}';
  }

  static List<String> splitTerms(Iterable<String> values) {
    final seen = <String>{};
    final result = <String>[];
    for (final value in values) {
      for (final part in value.split(RegExp(r'[，,]'))) {
        final term = part.trim();
        if (term.isEmpty || !seen.add(term)) continue;
        result.add(term);
      }
    }
    return List<String>.unmodifiable(result);
  }

  static List<String> sortTermsByFrequency(Map<String, int> frequencies) {
    final terms = frequencies.keys.toList(growable: false)
      ..sort((a, b) {
        final frequencyResult = (frequencies[b] ?? 0).compareTo(
          frequencies[a] ?? 0,
        );
        if (frequencyResult != 0) return frequencyResult;
        final caseInsensitiveResult =
            a.toLowerCase().compareTo(b.toLowerCase());
        if (caseInsensitiveResult != 0) return caseInsensitiveResult;
        return a.compareTo(b);
      });
    return List<String>.unmodifiable(terms);
  }
}
