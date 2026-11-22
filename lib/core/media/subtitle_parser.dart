import 'dart:convert';
import 'dart:isolate';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

import '../immutable_collections.dart';

class SubtitleCue {
  const SubtitleCue({
    required this.start,
    required this.end,
    required this.text,
    this.originalText,
    this.assSourceLine,
  });

  final Duration start;
  final Duration end;
  final String text;
  final String? originalText;
  final int? assSourceLine;

  bool contains(Duration position) {
    return position >= start && position < end;
  }
}

class SubtitleTrack {
  SubtitleTrack({
    required this.sourcePath,
    required List<SubtitleCue> cues,
    this.offset = Duration.zero,
    this.sourceRevision,
  }) : cues = immutableList(cues) {
    _timeIndex = _SubtitleTimeIndex(this.cues);
  }

  SubtitleTrack._withOffset(SubtitleTrack source, this.offset)
    : sourcePath = source.sourcePath,
      cues = source.cues,
      sourceRevision = source.sourceRevision,
      _timeIndex = source._timeIndex;

  final String sourcePath;
  final List<SubtitleCue> cues;
  final Duration offset;
  final String? sourceRevision;
  late final _SubtitleTimeIndex _timeIndex;

  SubtitleTrack withOffset(Duration newOffset) {
    if (newOffset == offset) return this;
    return SubtitleTrack._withOffset(this, newOffset);
  }

  bool hasSameCueTimings(List<SubtitleCue> edited) {
    if (cues.length != edited.length) return false;
    for (var index = 0; index < cues.length; index++) {
      if (cues[index].start != edited[index].start ||
          cues[index].end != edited[index].end) {
        return false;
      }
    }
    return true;
  }

  SubtitleCue? cueAt(Duration position, {bool persistent = false}) {
    if (cues.isEmpty) return null;
    final effectivePosition = position - offset;
    if (effectivePosition < Duration.zero) return null;
    final timeOrderedCues = _timeIndex.cues;
    var low = 0;
    var high = timeOrderedCues.length - 1;
    var result = -1;
    while (low <= high) {
      final mid = low + ((high - low) >> 1);
      if (timeOrderedCues[mid].start <= effectivePosition) {
        result = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }

    if (result < 0) return null;
    if (persistent) return timeOrderedCues[result];

    // An expired short cue cannot exclude an earlier, longer overlapping cue.
    for (var index = result; index >= 0; index--) {
      if (_timeIndex.latestEnds[index] <= effectivePosition) break;
      final cue = timeOrderedCues[index];
      if (cue.contains(effectivePosition)) return cue;
    }
    return null;
  }
}

// Offsets do not affect cue ordering. Share even a not-yet-built index so
// editing offsets cannot sort the same source again.
final class _SubtitleTimeIndex {
  _SubtitleTimeIndex(this._sourceCues);

  final List<SubtitleCue> _sourceCues;
  // Keep source order for ASS editing while time lookup uses a stable index.
  late final List<SubtitleCue> cues = (() {
    final indexed = _sourceCues.indexed.toList()
      ..sort((a, b) {
        final byStart = a.$2.start.compareTo(b.$2.start);
        return byStart != 0 ? byStart : a.$1.compareTo(b.$1);
      });
    return indexed.map((entry) => entry.$2).toList(growable: false);
  })();
  late final List<Duration> latestEnds = (() {
    var latest = Duration.zero;
    return cues
        .map((cue) {
          if (cue.end > latest) latest = cue.end;
          return latest;
        })
        .toList(growable: false);
  })();

  void prepare() {
    // Force both lazy fields inside the parsing worker, before UI consumers.
    latestEnds;
  }
}

const Set<String> supportedSubtitleExtensions = {
  '.vtt',
  '.webvtt',
  '.lrc',
  '.srt',
  '.ass',
  '.ssa',
  '.txt',
};

const subtitleTranslationBoundary = '<!--doujin-audio:translation-->';

String subtitleSourceRevision(String raw) => sha256
    .convert(utf8.encode(raw.startsWith('\uFEFF') ? raw.substring(1) : raw))
    .toString();

const Set<String> _subtitleMatchMediaExtensions = {
  '.mp3',
  '.aac',
  '.m4a',
  '.ogg',
  '.oga',
  '.opus',
  '.wav',
  '.flac',
  '.mp4',
  '.mkv',
  '.webm',
  '.mov',
  '.m4v',
  '.avi',
  '.3gp',
};

final RegExp _translatedSubtitleFilePattern = RegExp(
  r'\.translated\.[a-z-]+(?:\.\d+)?\.srt$',
  caseSensitive: false,
);
final RegExp _lrcTimestampPattern = RegExp(
  r'\[(\d+):(\d{1,2})(?:[.:](\d{1,3}))?\]',
);
final RegExp _lrcOffsetPattern = RegExp(
  r'^\[offset:([+-]?\d+)\]$',
  caseSensitive: false,
);
final RegExp _srtBlockSeparatorPattern = RegExp(r'\n\s*\n');
final RegExp _assTagPattern = RegExp(r'\{.*?\}');
final RegExp _whitespacePattern = RegExp(r'\s+');
final RegExp _genericTimestampPattern = RegExp(
  r'^(?:(\d+):)?(\d{1,2}):(\d{2})(?:\.(\d{1,3}))?$',
);
final RegExp _assTimestampPattern = RegExp(
  r'^(\d+):(\d{1,2}):(\d{2})[.](\d{1,2})$',
);
final RegExp _htmlTagPattern = RegExp(r'<[^>]+>');

Future<SubtitleTrack?> parseSubtitleTrackFromRaw({
  required String sourcePath,
  required String raw,
  required String extension,
}) async {
  final normalizedExtension = _normalizedSubtitleExtension(extension);
  return Isolate.run(
    () => parseSubtitleTrackSync(
      sourcePath: sourcePath,
      raw: raw,
      extension: normalizedExtension,
    ),
  );
}

SubtitleTrack? parseSubtitleTrackSync({
  required String sourcePath,
  required String raw,
  required String extension,
}) {
  final normalizedExtension = _normalizedSubtitleExtension(extension);
  final cues = switch (normalizedExtension) {
    '.lrc' => _parseLrc(raw),
    '.vtt' || '.webvtt' => _parseWebVtt(raw),
    '.srt' => _parseSrt(raw),
    '.ass' || '.ssa' => _parseAss(raw),
    _ => null,
  };

  final resolvedCues =
      cues != null &&
          (cues.isNotEmpty ||
              normalizedExtension == '.ass' ||
              normalizedExtension == '.ssa')
      ? cues
      : _parseSubtitleTrackByContent(raw);
  if (resolvedCues == null) return null;
  return SubtitleTrack(
    sourcePath: sourcePath,
    cues: resolvedCues,
    sourceRevision: subtitleSourceRevision(raw),
  ).._timeIndex.prepare();
}

List<SubtitleCue>? _parseSubtitleTrackByContent(String raw) {
  final parsers = <List<SubtitleCue> Function()>[
    () => _parseWebVtt(raw),
    () => _parseSrt(raw),
  ];

  for (final parse in parsers) {
    final cues = parse();
    if (cues.isNotEmpty) {
      return cues;
    }
  }

  final assCues = _parseAss(raw);
  if (assCues != null) return assCues;
  final lrcCues = _parseLrc(raw);
  return lrcCues.isEmpty ? null : lrcCues;
}

Future<File?> findSubtitleFileForAudio(String audioPath) async {
  final candidates = await findSubtitleFilesForAudio(audioPath);
  return candidates.isEmpty ? null : candidates.first;
}

bool isTranslatedSubtitleFile(String fileName) =>
    _translatedSubtitleFilePattern.hasMatch(fileName);

Future<List<File>> findSubtitleFilesForAudio(
  String audioPath, {
  bool includeTranslations = false,
}) async {
  final audioFile = File(audioPath);
  if (!await audioFile.exists()) return const [];
  final directory = audioFile.parent;
  final stem = subtitleMatchStem(audioPath);
  final stemDot = '$stem.';
  final stemUnderscore = '${stem}_';
  final stemSpace = '$stem ';
  final translationPrefix = '${path.basename(audioPath)}.translated.'
      .toLowerCase();
  final candidates = <({File file, int rank, String lowerPath})>[];

  try {
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;
      final extension = path.extension(entity.path).toLowerCase();
      if (!supportedSubtitleExtensions.contains(extension)) continue;
      final name = path.basename(entity.path);
      if (isTranslatedSubtitleFile(name) &&
          (!includeTranslations ||
              !name.toLowerCase().startsWith(translationPrefix))) {
        continue;
      }
      final fileStem = subtitleMatchStem(entity.path);
      final rank = fileStem == stem
          ? 0
          : fileStem.startsWith(stemDot)
          ? 1
          : fileStem.startsWith(stemUnderscore)
          ? 2
          : fileStem.startsWith(stemSpace)
          ? 3
          : 10;
      if (rank >= 10) continue;
      candidates.add((
        file: entity,
        rank: rank,
        lowerPath: entity.path.toLowerCase(),
      ));
    }
  } catch (_) {
    return const [];
  }

  candidates.sort((a, b) {
    final rankResult = a.rank.compareTo(b.rank);
    return rankResult != 0 ? rankResult : a.lowerPath.compareTo(b.lowerPath);
  });
  return candidates.map((entry) => entry.file).toList(growable: false);
}

String subtitleMatchStem(String value) {
  var current = path.basename(value.toLowerCase());
  while (current.isNotEmpty) {
    final extension = path.extension(current);
    if (!supportedSubtitleExtensions.contains(extension) &&
        !_subtitleMatchMediaExtensions.contains(extension)) {
      break;
    }
    current = path.withoutExtension(current);
  }
  return current;
}

String _normalizedSubtitleExtension(String extension) =>
    extension.startsWith('.')
    ? extension.toLowerCase()
    : '.${extension.toLowerCase()}';

List<SubtitleCue> _parseLrc(String raw) {
  final lineMap = <int, List<String>>{};
  var offsetMs = 0;

  final normalizedRaw = raw.startsWith('\uFEFF') ? raw.substring(1) : raw;
  for (final rawLine in normalizedRaw.replaceAll('\r\n', '\n').split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;

    final offsetMatch = _lrcOffsetPattern.firstMatch(line);
    if (offsetMatch != null) {
      offsetMs = int.tryParse(offsetMatch.group(1) ?? '') ?? 0;
      continue;
    }

    final matches = _lrcTimestampPattern.allMatches(line).toList();
    if (matches.isEmpty) continue;

    final text = _normalizeCueText(
      line.replaceAll(_lrcTimestampPattern, '').trim(),
    );
    for (final match in matches) {
      final minutes = int.tryParse(match.group(1) ?? '') ?? 0;
      final seconds = int.tryParse(match.group(2) ?? '') ?? 0;
      final fractionRaw = match.group(3) ?? '0';
      final milliseconds = _fractionToMilliseconds(fractionRaw);
      final startMs =
          Duration(
            minutes: minutes,
            seconds: seconds,
            milliseconds: milliseconds,
          ).inMilliseconds +
          offsetMs;
      final safeStartMs = startMs < 0 ? 0 : startMs;
      final lines = lineMap.putIfAbsent(safeStartMs, () => <String>[]);
      if (text.isNotEmpty) lines.add(text);
    }
  }

  final entries = lineMap.entries.toList()
    ..sort((a, b) => a.key.compareTo(b.key));
  if (entries.isEmpty) return const <SubtitleCue>[];

  final cues = <SubtitleCue>[];
  for (var i = 0; i < entries.length; i++) {
    final startMs = entries[i].key;
    final nextStartMs = i + 1 < entries.length ? entries[i + 1].key : null;
    final mergedText = _normalizeCueText(entries[i].value.join('\n'));
    if (mergedText.isEmpty) continue;
    final endMs = nextStartMs == null
        ? startMs + 8000
        : (nextStartMs > startMs ? nextStartMs : startMs + 8000);
    cues.add(
      SubtitleCue(
        start: Duration(milliseconds: startMs),
        end: Duration(milliseconds: endMs),
        text: mergedText,
      ),
    );
  }
  return cues;
}

List<SubtitleCue> _parseWebVtt(String raw) {
  final lines = raw
      .replaceFirst('\uFEFF', '')
      .replaceAll('\r\n', '\n')
      .split('\n');
  final cues = <SubtitleCue>[];
  var i = 0;

  while (i < lines.length) {
    final line = lines[i].trim();
    if (line.isEmpty ||
        line == 'WEBVTT' ||
        line.startsWith('WEBVTT ') ||
        line.startsWith('WEBVTT\t')) {
      i++;
      continue;
    }
    if (line.startsWith('NOTE')) {
      while (i < lines.length && lines[i].trim().isNotEmpty) {
        i++;
      }
      continue;
    }

    var timingLine = line;
    if (!line.contains('-->') && i + 1 < lines.length) {
      timingLine = lines[++i].trim();
    }
    if (!timingLine.contains('-->')) {
      i++;
      continue;
    }

    final timing = _parseArrowTiming(timingLine);
    if (timing == null) {
      i++;
      continue;
    }

    i++;
    final textLines = <String>[];
    while (i < lines.length && lines[i].trim().isNotEmpty) {
      textLines.add(lines[i]);
      i++;
    }
    final cue = _timedCue(timing, textLines.join('\n'));
    if (cue != null) cues.add(cue);
  }

  return cues;
}

List<SubtitleCue> _parseSrt(String raw) {
  final blocks = raw
      .replaceFirst('\uFEFF', '')
      .replaceAll('\r\n', '\n')
      .split(_srtBlockSeparatorPattern);
  final cues = <SubtitleCue>[];

  for (final block in blocks) {
    final lines = block
        .split('\n')
        .map((line) => line.trimRight())
        .where((line) => line.trim().isNotEmpty)
        .toList();
    if (lines.isEmpty) continue;

    var timingIndex = 0;
    if (!lines.first.contains('-->') && lines.length > 1) {
      timingIndex = 1;
    }
    if (timingIndex >= lines.length) continue;

    final timing = _parseArrowTiming(lines[timingIndex]);
    if (timing == null) continue;

    final cue = _timedCue(timing, lines.skip(timingIndex + 1).join('\n'));
    if (cue != null) cues.add(cue);
  }

  return cues;
}

SubtitleCue? _timedCue((Duration, Duration) timing, String rawText) {
  final text = _normalizeCueText(rawText);
  if (text.isEmpty) return null;
  final boundary = rawText.indexOf(subtitleTranslationBoundary);
  final original = boundary < 0
      ? null
      : _normalizeCueText(rawText.substring(0, boundary));
  return SubtitleCue(
    start: timing.$1,
    end: timing.$2,
    text: text,
    originalText: original?.isNotEmpty == true ? original : null,
  );
}

List<SubtitleCue>? _parseAss(String raw) {
  final lines = raw
      .replaceFirst('\uFEFF', '')
      .replaceAll('\r\n', '\n')
      .split('\n');
  final cues = <SubtitleCue>[];
  var inEvents = false;
  var hasFormat = false;
  List<String> formatColumns = const <String>[];
  var startIndex = -1;
  var endIndex = -1;
  var textIndex = -1;

  for (final (lineIndex, rawLine) in lines.indexed) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('[')) {
      inEvents = line.toLowerCase() == '[events]';
      continue;
    }
    if (!inEvents) continue;

    final lower = line.toLowerCase();
    if (lower.startsWith('format:')) {
      formatColumns = line
          .substring(line.indexOf(':') + 1)
          .split(',')
          .map((part) => part.trim().toLowerCase())
          .toList();
      startIndex = formatColumns.indexOf('start');
      endIndex = formatColumns.indexOf('end');
      textIndex = formatColumns.indexOf('text');
      hasFormat =
          hasFormat || (startIndex != -1 && endIndex != -1 && textIndex != -1);
      continue;
    }
    if (!lower.startsWith('dialogue:')) continue;
    if (formatColumns.isEmpty ||
        startIndex == -1 ||
        endIndex == -1 ||
        textIndex == -1) {
      continue;
    }

    final values = _splitAssDialogue(
      line.substring(line.indexOf(':') + 1),
      formatColumns.length,
    );
    if (values.length != formatColumns.length) continue;

    final start = _parseAssTimestamp(values[startIndex].trim());
    final end = _parseAssTimestamp(values[endIndex].trim());
    if (start == null || end == null || end <= start) continue;

    final text = _normalizeCueText(
      values[textIndex]
          .replaceAll(r'\N', '\n')
          .replaceAll(r'\n', '\n')
          .replaceAll(_assTagPattern, ''),
    );
    if (text.isEmpty) continue;

    cues.add(
      SubtitleCue(start: start, end: end, text: text, assSourceLine: lineIndex),
    );
  }

  return hasFormat ? cues : null;
}

List<String> _splitAssDialogue(String input, int expectedParts) {
  final values = <String>[];
  var start = 0;

  for (var i = 0; i < expectedParts - 1; i++) {
    final commaIndex = input.indexOf(',', start);
    if (commaIndex == -1) return values;
    values.add(input.substring(start, commaIndex));
    start = commaIndex + 1;
  }

  values.add(input.substring(start));
  return values;
}

(Duration, Duration)? _parseArrowTiming(String line) {
  final parts = line.split('-->');
  if (parts.length != 2) return null;

  final start = _parseGenericTimestamp(parts[0].trim());
  final end = _parseGenericTimestamp(
    parts[1].trim().split(_whitespacePattern).first,
  );
  if (start == null || end == null || end <= start) return null;
  return (start, end);
}

Duration? _parseGenericTimestamp(String input) {
  final cleaned = input.trim().replaceAll(',', '.');
  final match = _genericTimestampPattern.firstMatch(cleaned);
  if (match == null) return null;

  final hours = int.tryParse(match.group(1) ?? '0') ?? 0;
  final minutes = int.tryParse(match.group(2) ?? '0') ?? 0;
  final seconds = int.tryParse(match.group(3) ?? '0') ?? 0;
  final milliseconds = _fractionToMilliseconds(match.group(4) ?? '0');
  return Duration(
    hours: hours,
    minutes: minutes,
    seconds: seconds,
    milliseconds: milliseconds,
  );
}

Duration? _parseAssTimestamp(String input) {
  final match = _assTimestampPattern.firstMatch(input);
  if (match == null) return null;

  final hours = int.tryParse(match.group(1) ?? '0') ?? 0;
  final minutes = int.tryParse(match.group(2) ?? '0') ?? 0;
  final seconds = int.tryParse(match.group(3) ?? '0') ?? 0;
  final centiseconds = int.tryParse(match.group(4) ?? '0') ?? 0;
  return Duration(
    hours: hours,
    minutes: minutes,
    seconds: seconds,
    milliseconds: centiseconds * 10,
  );
}

int _fractionToMilliseconds(String raw) {
  if (raw.isEmpty) return 0;
  if (raw.length == 1) return int.parse(raw) * 100;
  if (raw.length == 2) return int.parse(raw) * 10;
  return int.parse(raw.substring(0, 3));
}

String _normalizeCueText(String text) {
  return text
      .replaceAll('&nbsp;', ' ')
      .replaceAll(_htmlTagPattern, '')
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .join('\n')
      .trim();
}
