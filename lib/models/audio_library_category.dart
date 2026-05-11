import 'audio_detail.dart';
import 'music_track.dart';

enum AudioLibraryCategoryType { all, tags, voiceActors, circles }

class AudioLibraryCategoryEntry {
  const AudioLibraryCategoryEntry({
    required this.target,
    required this.title,
    required this.path,
    required this.isFolder,
    required this.detail,
    required this.tracks,
  });

  final AudioDetailTarget target;
  final String title;
  final String path;
  final bool isFolder;
  final AudioDetail detail;
  final List<MusicTrack> tracks;

  MusicTrack? get firstTrack => tracks.isEmpty ? null : tracks.first;

  String get searchableText => [
    title,
    path,
    detail.rjCode,
    detail.workTitle,
    detail.circleName,
    ...detail.voiceActors,
    ...detail.tags,
  ].where((value) => value.trim().isNotEmpty).join('\n').toLowerCase();
}

class AudioLibraryCategorySnapshot {
  const AudioLibraryCategorySnapshot({
    required this.entries,
    required this.tagTerms,
    required this.voiceActorTerms,
    required this.circleTerms,
    required this.structureRevision,
    required this.detailRevision,
  });

  final List<AudioLibraryCategoryEntry> entries;
  final List<String> tagTerms;
  final List<String> voiceActorTerms;
  final List<String> circleTerms;
  final int structureRevision;
  final int detailRevision;

  AudioDetail? detailFor(AudioDetailTarget target) {
    for (final entry in entries) {
      if (targetKey(entry.target) == targetKey(target)) {
        return entry.detail;
      }
    }
    return null;
  }

  AudioLibraryCategoryEntry? entryFor(AudioDetailTarget target) {
    for (final entry in entries) {
      if (targetKey(entry.target) == targetKey(target)) return entry;
    }
    return null;
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
        return a.toLowerCase().compareTo(b.toLowerCase());
      });
    return List<String>.unmodifiable(terms);
  }
}
