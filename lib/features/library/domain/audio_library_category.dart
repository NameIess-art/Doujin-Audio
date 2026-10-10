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
  factory AudioLibraryCategorySnapshot({
    required List<AudioLibraryCategoryEntry> entries,
    List<String>? tagTerms,
    List<String>? voiceActorTerms,
    List<String>? circleTerms,
    required int structureRevision,
    required int detailRevision,
  }) {
    final frequencies = {
      for (final type in AudioLibraryCategoryType.values)
        if (type != AudioLibraryCategoryType.all) type: <String, int>{},
    };
    final indices = <AudioDetailTarget, List<int>>{};
    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      indices.putIfAbsent(entry.target, () => <int>[]).add(i);
      for (final category in frequencies.entries) {
        for (final term in entry.termsForCategory(category.key)) {
          category.value.update(term, (count) => count + 1, ifAbsent: () => 1);
        }
      }
    }
    return AudioLibraryCategorySnapshot._(
      entries: entries,
      entryIndices: immutableMap(
        indices.map((target, rows) => MapEntry(target, immutableList(rows))),
      ),
      frequencies: immutableMap(
        frequencies.map((type, counts) => MapEntry(type, immutableMap(counts))),
      ),
      tagTerms:
          tagTerms ??
          sortTermsByFrequency(frequencies[AudioLibraryCategoryType.tags]!),
      voiceActorTerms:
          voiceActorTerms ??
          sortTermsByFrequency(
            frequencies[AudioLibraryCategoryType.voiceActors]!,
          ),
      circleTerms:
          circleTerms ??
          sortTermsByFrequency(frequencies[AudioLibraryCategoryType.circles]!),
      structureRevision: structureRevision,
      detailRevision: detailRevision,
    );
  }

  AudioLibraryCategorySnapshot._({
    required List<AudioLibraryCategoryEntry> entries,
    required Map<AudioDetailTarget, List<int>> entryIndices,
    required Map<AudioLibraryCategoryType, Map<String, int>> frequencies,
    required List<String> tagTerms,
    required List<String> voiceActorTerms,
    required List<String> circleTerms,
    required this.structureRevision,
    required this.detailRevision,
  }) : entries = immutableList(entries),
       _entryIndices = entryIndices,
       _frequencies = frequencies,
       tagTerms = immutableList(tagTerms),
       voiceActorTerms = immutableList(voiceActorTerms),
       circleTerms = immutableList(circleTerms);

  final List<AudioLibraryCategoryEntry> entries;
  final List<String> tagTerms;
  final List<String> voiceActorTerms;
  final List<String> circleTerms;
  final int structureRevision;
  final int detailRevision;
  final Map<AudioDetailTarget, List<int>> _entryIndices;
  final Map<AudioLibraryCategoryType, Map<String, int>> _frequencies;

  AudioDetail? detailFor(AudioDetailTarget target) {
    return entryFor(target)?.detail;
  }

  AudioLibraryCategoryEntry? entryFor(AudioDetailTarget target) {
    final index = _entryIndices[target]?.first;
    return index == null ? null : entries[index];
  }

  AudioLibraryCategorySnapshot withDetailChanges(
    Map<AudioDetailTarget, AudioDetail> changes, {
    required int detailRevision,
  }) {
    final updated = List<AudioLibraryCategoryEntry>.of(entries);
    final changedFrequencies = <AudioLibraryCategoryType, Map<String, int>>{};
    for (final change in changes.entries) {
      final indices = _entryIndices[change.key];
      if (indices == null) continue;
      for (final index in indices) {
        final previous = entries[index];
        final next = AudioLibraryCategoryEntry(
          target: previous.target,
          title: previous.title,
          path: previous.path,
          isFolder: previous.isFolder,
          detail: change.value,
          tracks: previous.tracks,
        );
        updated[index] = next;
        for (final type in _frequencies.keys) {
          final oldTerms = previous.termsForCategory(type).toSet();
          final newTerms = next.termsForCategory(type).toSet();
          final removed = oldTerms.difference(newTerms);
          final added = newTerms.difference(oldTerms);
          if (removed.isEmpty && added.isEmpty) continue;
          final counts = changedFrequencies.putIfAbsent(
            type,
            () => Map<String, int>.of(_frequencies[type]!),
          );
          for (final term in removed) {
            final count = counts[term]! - 1;
            if (count == 0) {
              counts.remove(term);
            } else {
              counts[term] = count;
            }
          }
          for (final term in added) {
            counts.update(term, (count) => count + 1, ifAbsent: () => 1);
          }
        }
      }
    }
    List<String> terms(AudioLibraryCategoryType type, List<String> previous) {
      final changed = changedFrequencies[type];
      return changed == null ? previous : sortTermsByFrequency(changed);
    }

    return AudioLibraryCategorySnapshot._(
      entries: updated,
      entryIndices: _entryIndices,
      frequencies: immutableMap({
        ..._frequencies,
        for (final changed in changedFrequencies.entries)
          changed.key: immutableMap(changed.value),
      }),
      tagTerms: terms(AudioLibraryCategoryType.tags, tagTerms),
      voiceActorTerms: terms(
        AudioLibraryCategoryType.voiceActors,
        voiceActorTerms,
      ),
      circleTerms: terms(AudioLibraryCategoryType.circles, circleTerms),
      structureRevision: structureRevision,
      detailRevision: detailRevision,
    );
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
        final caseInsensitiveResult = a.toLowerCase().compareTo(
          b.toLowerCase(),
        );
        if (caseInsensitiveResult != 0) return caseInsensitiveResult;
        return a.compareTo(b);
      });
    return List<String>.unmodifiable(terms);
  }
}
