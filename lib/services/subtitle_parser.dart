import 'dart:convert';
import 'dart:isolate';
import 'dart:io';

import 'package:path/path.dart' as path;

class SubtitleCue {
  const SubtitleCue({
    required this.start,
    required this.end,
    required this.text,
  });

  final Duration start;
  final Duration end;
  final String text;

  bool contains(Duration position) {
    return position >= start && position < end;
  }
}

class SubtitleTrack {
  const SubtitleTrack({required this.sourcePath, required this.cues});

  final String sourcePath;
  final List<SubtitleCue> cues;

  SubtitleCue? cueAt(Duration position) {
    if (cues.isEmpty) return null;

    var low = 0;
    var high = cues.length - 1;

    while (low <= high) {
      final mid = low + ((high - low) >> 1);
      final cue = cues[mid];
      if (position < cue.start) {
        high = mid - 1;
      } else if (position >= cue.end) {
        low = mid + 1;
      } else {
        return cue;
      }
    }

    return null;
  }
}

const Set<String> _supportedSubtitleExtensions = {
  '.vtt',
  '.webvtt',
  '.lrc',
  '.srt',
  '.ass',
  '.ssa',
};

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

Future<SubtitleTrack?> loadSubtitleTrackForAudio(String audioPath) async {
  if (audioPath.startsWith('content://')) return null;

  final subtitleFile = await _findSubtitleFile(audioPath);
  if (subtitleFile == null) return null;

  final raw = await subtitleFile.readAsString();
  final extension = path.extension(subtitleFile.path).toLowerCase();
  return Isolate.run(
    () => _parseSubtitleTrack(
      sourcePath: subtitleFile.path,
      raw: raw,
      extension: extension,
    ),
  );
}

Future<SubtitleTrack?> loadSubtitleTrackFromUrl({
  required String url,
  String? sourcePath,
  String? extension,
}) async {
  final uri = Uri.tryParse(url);
  if (uri == null) return null;

  final resolvedSourcePath = (sourcePath == null || sourcePath.trim().isEmpty)
      ? uri.path
      : sourcePath.trim();
  final resolvedExtension = _normalizedSubtitleExtension(
    extension ?? path.extension(resolvedSourcePath),
  );
  final client = HttpClient();
  try {
    final request = await client.getUrl(uri);
    final response = await request.close();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return null;
    }
    final raw = await response.transform(utf8.decoder).join();
    if (raw.trim().isEmpty) return null;
    return parseSubtitleTrackFromRaw(
      sourcePath: resolvedSourcePath,
      raw: raw,
      extension: resolvedExtension,
    );
  } finally {
    client.close(force: true);
  }
}

Future<SubtitleTrack?> parseSubtitleTrackFromRaw({
  required String sourcePath,
  required String raw,
  required String extension,
}) async {
  final normalizedExtension = _normalizedSubtitleExtension(extension);
  return Isolate.run(
    () => _parseSubtitleTrack(
      sourcePath: sourcePath,
      raw: raw,
      extension: normalizedExtension,
    ),
  );
}

SubtitleTrack? _parseSubtitleTrack({
  required String sourcePath,
  required String raw,
  required String extension,
}) {
  final cues = switch (extension) {
    '.lrc' => _parseLrc(raw),
    '.vtt' || '.webvtt' => _parseWebVtt(raw),
    '.srt' => _parseSrt(raw),
    '.ass' || '.ssa' => _parseAss(raw),
    _ => const <SubtitleCue>[],
  };

  final resolvedCues = cues.isNotEmpty
      ? cues
      : _parseSubtitleTrackByContent(raw);
  if (resolvedCues.isEmpty) return null;
  return SubtitleTrack(sourcePath: sourcePath, cues: resolvedCues);
}

List<SubtitleCue> _parseSubtitleTrackByContent(String raw) {
  final parsers = <List<SubtitleCue> Function()>[
    () => _parseWebVtt(raw),
    () => _parseSrt(raw),
    () => _parseAss(raw),
    () => _parseLrc(raw),
  ];

  for (final parse in parsers) {
    final cues = parse();
    if (cues.isNotEmpty) {
      return cues;
    }
  }

  return const <SubtitleCue>[];
}

Future<File?> _findSubtitleFile(String audioPath) async {
  final audioFile = File(audioPath);
  if (!await audioFile.exists()) return null;

  final directory = audioFile.parent;
  final stem = _subtitleMatchStem(audioPath);
  final candidates = <File>[];

  try {
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;
      final extension = path.extension(entity.path).toLowerCase();
      if (!_supportedSubtitleExtensions.contains(extension)) continue;
      candidates.add(entity);
    }
  } catch (_) {
    return null;
  }

  if (candidates.isEmpty) return null;

  int rank(File file) {
    final fileStem = _subtitleMatchStem(file.path);
    if (fileStem == stem) return 0;
    if (fileStem.startsWith('$stem.')) return 1;
    if (fileStem.startsWith('${stem}_')) return 2;
    if (fileStem.startsWith('$stem ')) return 3;
    return 10;
  }

  candidates.sort((a, b) {
    final rankResult = rank(a).compareTo(rank(b));
    if (rankResult != 0) return rankResult;
    return a.path.toLowerCase().compareTo(b.path.toLowerCase());
  });

  final best = candidates.first;
  return rank(best) >= 10 ? null : best;
}

String _normalizedSubtitleExtension(String extension) =>
    extension.startsWith('.')
    ? extension.toLowerCase()
    : '.${extension.toLowerCase()}';

String _subtitleMatchStem(String value) {
  var current = path.basename(value.toLowerCase());
  while (current.isNotEmpty) {
    final extension = path.extension(current);
    if (extension.isEmpty) {
      break;
    }
    if (!_supportedSubtitleExtensions.contains(extension) &&
        !_subtitleMatchMediaExtensions.contains(extension)) {
      break;
    }
    current = path.withoutExtension(current);
  }
  return current;
}

List<SubtitleCue> _parseLrc(String raw) {
  final timestampPattern = RegExp(r'\[(\d{1,2}):(\d{1,2})(?:[.:](\d{1,3}))?\]');
  final offsetPattern = RegExp(
    r'^\[offset:([+-]?\d+)\]$',
    caseSensitive: false,
  );
  final lineMap = <int, List<String>>{};
  var offsetMs = 0;

  for (final rawLine in raw.replaceAll('\r\n', '\n').split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;

    final offsetMatch = offsetPattern.firstMatch(line);
    if (offsetMatch != null) {
      offsetMs = int.tryParse(offsetMatch.group(1) ?? '') ?? 0;
      continue;
    }

    final matches = timestampPattern.allMatches(line).toList();
    if (matches.isEmpty) continue;

    final text = _normalizeCueText(
      line.replaceAll(timestampPattern, '').trim(),
    );
    if (text.isEmpty) continue;

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
      lineMap.putIfAbsent(safeStartMs, () => <String>[]).add(text);
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
    if (line.isEmpty || line == 'WEBVTT') {
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
    final text = _normalizeCueText(textLines.join('\n'));
    if (text.isNotEmpty) {
      cues.add(SubtitleCue(start: timing.$1, end: timing.$2, text: text));
    }
  }

  return cues;
}

List<SubtitleCue> _parseSrt(String raw) {
  final blocks = raw
      .replaceFirst('\uFEFF', '')
      .replaceAll('\r\n', '\n')
      .split(RegExp(r'\n\s*\n'));
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

    final text = _normalizeCueText(lines.skip(timingIndex + 1).join('\n'));
    if (text.isEmpty) continue;

    cues.add(SubtitleCue(start: timing.$1, end: timing.$2, text: text));
  }

  return cues;
}

List<SubtitleCue> _parseAss(String raw) {
  final lines = raw
      .replaceFirst('\uFEFF', '')
      .replaceAll('\r\n', '\n')
      .split('\n');
  final cues = <SubtitleCue>[];
  var inEvents = false;
  List<String> formatColumns = const <String>[];

  for (final rawLine in lines) {
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
      continue;
    }
    if (!lower.startsWith('dialogue:')) continue;
    if (formatColumns.isEmpty) continue;

    final values = _splitAssDialogue(
      line.substring(line.indexOf(':') + 1),
      formatColumns.length,
    );
    if (values.length != formatColumns.length) continue;

    final startIndex = formatColumns.indexOf('start');
    final endIndex = formatColumns.indexOf('end');
    final textIndex = formatColumns.indexOf('text');
    if (startIndex == -1 || endIndex == -1 || textIndex == -1) continue;

    final start = _parseAssTimestamp(values[startIndex].trim());
    final end = _parseAssTimestamp(values[endIndex].trim());
    if (start == null || end == null || end <= start) continue;

    final text = _normalizeCueText(
      values[textIndex]
          .replaceAll(r'\N', '\n')
          .replaceAll(r'\n', '\n')
          .replaceAll(RegExp(r'\{.*?\}'), ''),
    );
    if (text.isEmpty) continue;

    cues.add(SubtitleCue(start: start, end: end, text: text));
  }

  return cues;
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
    parts[1].trim().split(RegExp(r'\s+')).first,
  );
  if (start == null || end == null || end <= start) return null;
  return (start, end);
}

Duration? _parseGenericTimestamp(String input) {
  final cleaned = input.trim().replaceAll(',', '.');
  final match = RegExp(
    r'^(?:(\d+):)?(\d{1,2}):(\d{2})(?:\.(\d{1,3}))?$',
  ).firstMatch(cleaned);
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
  final match = RegExp(
    r'^(\d+):(\d{1,2}):(\d{2})[.](\d{1,2})$',
  ).firstMatch(input);
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
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .join('\n')
      .trim();
}
