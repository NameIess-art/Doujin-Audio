import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import '../../../core/media/subtitle_parser.dart';

class AsrWordTiming {
  const AsrWordTiming({
    required this.text,
    required this.startSeconds,
    required this.endSeconds,
  });

  final String text;
  final double startSeconds;
  final double endSeconds;
}

typedef AsrRawTokenBytes = ({
  Uint8List bytes,
  double startSeconds,
  double endSeconds,
});

/// Returns the number of trailing bytes (1..3) that form an incomplete leading
/// prefix of a valid multi-byte UTF-8 sequence, or 0 when [bytes] ends at a
/// code-point boundary or invalid byte sequence.
int trailingIncompleteUtf8Bytes(List<int> bytes) {
  final length = bytes.length;
  if (length == 0) return 0;
  var continuations = 0;
  while (continuations < length &&
      continuations < 3 &&
      (bytes[length - 1 - continuations] & 0xC0) == 0x80) {
    continuations++;
  }
  if (continuations == length) return 0;
  final lead = bytes[length - 1 - continuations];
  final int expectedLength;
  if (lead < 0x80) {
    return 0;
  } else if (lead >= 0xC2 && lead <= 0xDF) {
    expectedLength = 2;
  } else if (lead >= 0xE0 && lead <= 0xEF) {
    expectedLength = 3;
  } else if (lead >= 0xF0 && lead <= 0xF4) {
    expectedLength = 4;
  } else {
    return 0;
  }
  final actualLength = 1 + continuations;
  return actualLength < expectedLength ? actualLength : 0;
}

bool _isSpecialWhisperTokenBytes(Uint8List bytes) {
  if (bytes.length < 2) return false;
  // Skip Whisper inline special tokens such as [_BEG_], [_TT_120], <|ja|>.
  return (bytes[0] == 0x5B && bytes[1] == 0x5F) ||
      (bytes[0] == 0x3C && bytes[1] == 0x7C);
}

/// Reassembles Whisper byte-level BPE tokens into valid UTF-8 [AsrWordTiming]
/// items without throwing on multi-byte CJK characters split across tokens.
List<AsrWordTiming> assembleUtf8AsrTokenWords(
  Iterable<AsrRawTokenBytes> rawTokens,
) {
  final words = <AsrWordTiming>[];
  final pending = <int>[];
  double? pendingStart;
  double? pendingEnd;

  void emitDecoded(List<int> byteSlice, double start, double end) {
    final decoded = utf8
        .decode(byteSlice, allowMalformed: true)
        .replaceAll('\uFFFD', '');
    if (decoded.isEmpty) return;
    final safeStart = math.max(0.0, start);
    final safeEnd = math.max(safeStart, end);
    words.add(
      AsrWordTiming(
        text: decoded,
        startSeconds: safeStart,
        endSeconds: safeEnd,
      ),
    );
  }

  for (final token in rawTokens) {
    if (token.bytes.isEmpty || _isSpecialWhisperTokenBytes(token.bytes)) {
      continue;
    }
    if (pending.isEmpty) {
      pendingStart = token.startSeconds;
      pendingEnd = math.max(token.startSeconds, token.endSeconds);
    } else {
      pendingEnd = math.max(pendingEnd!, token.endSeconds);
    }
    pending.addAll(token.bytes);

    final incomplete = trailingIncompleteUtf8Bytes(pending);
    final completeLength = pending.length - incomplete;
    if (completeLength > 0) {
      final completeBytes = incomplete == 0
          ? pending
          : pending.sublist(0, completeLength);
      emitDecoded(completeBytes, pendingStart!, pendingEnd);
      if (incomplete == 0) {
        pending.clear();
        pendingStart = null;
        pendingEnd = null;
      } else {
        final tail = pending.sublist(completeLength);
        pending
          ..clear()
          ..addAll(tail);
        pendingStart = token.startSeconds;
        pendingEnd = math.max(token.startSeconds, token.endSeconds);
      }
    }
  }

  if (pending.isNotEmpty && pendingStart != null && pendingEnd != null) {
    emitDecoded(pending, pendingStart, pendingEnd);
  }
  return words;
}

class AsrRawSegment {
  const AsrRawSegment({
    required this.text,
    required this.startSeconds,
    required this.endSeconds,
    this.noSpeechProb = -1.0,
    this.words = const <AsrWordTiming>[],
  });

  final String text;
  final double startSeconds;
  final double endSeconds;
  final double noSpeechProb;
  final List<AsrWordTiming> words;
}

class AsrVadSpan {
  const AsrVadSpan({required this.startSeconds, required this.endSeconds});

  final double startSeconds;
  final double endSeconds;
}

class VadWindowPlan {
  const VadWindowPlan({required this.slices, required this.nextFrameOffset});

  final List<({int startFrame, int endFrame})> slices;
  final int nextFrameOffset;
}

/// Downmixes 16 kHz interleaved stereo s16le PCM into mono float32 while
/// preventing phase cancellation on out-of-phase binaural tracks and preserving
/// single-ear whisper amplitude.
Float32List downmixBinauralS16LeToMonoF32(Uint8List stereoS16Le) {
  final frameCount = stereoS16Le.length ~/ 4;
  if (frameCount == 0) return Float32List(0);
  final view = ByteData.sublistView(stereoS16Le, 0, frameCount * 4);
  final output = Float32List(frameCount);

  const blockFrames = 800; // 50 ms at 16 kHz
  const rampFrames = 64; // 4 ms crossfade across block weight updates
  var prevWL = 0.5;
  var prevWR = 0.5;
  var initialized = false;

  for (var blockStart = 0; blockStart < frameCount; blockStart += blockFrames) {
    final blockEnd = math.min(frameCount, blockStart + blockFrames);
    var sumL2 = 0.0;
    var sumR2 = 0.0;
    var sumM2 = 0.0;
    for (var i = blockStart; i < blockEnd; i++) {
      final offset = i * 4;
      final l = view.getInt16(offset, Endian.little) / 32768.0;
      final r = view.getInt16(offset + 2, Endian.little) / 32768.0;
      final m = 0.5 * (l + r);
      sumL2 += l * l;
      sumR2 += r * r;
      sumM2 += m * m;
    }

    final maxSide = math.max(sumL2, sumR2);
    double targetWL;
    double targetWR;
    if (maxSide <= 1e-10) {
      targetWL = 0.5;
      targetWR = 0.5;
    } else if (sumM2 < 0.25 * maxSide) {
      // Out-of-phase channels cancel in (L + R) / 2; select the stronger ear.
      if (sumL2 >= sumR2) {
        targetWL = 1.0;
        targetWR = 0.0;
      } else {
        targetWL = 0.0;
        targetWR = 1.0;
      }
    } else {
      final rmsL = math.sqrt(sumL2);
      final rmsR = math.sqrt(sumR2);
      final denom = rmsL + rmsR;
      targetWL = denom <= 0.0 ? 0.5 : rmsL / denom;
      targetWR = denom <= 0.0 ? 0.5 : rmsR / denom;
    }

    if (!initialized) {
      prevWL = targetWL;
      prevWR = targetWR;
      initialized = true;
    }

    final blockLen = blockEnd - blockStart;
    final rampLen = math.min(rampFrames, blockLen);
    for (var j = 0; j < blockLen; j++) {
      final i = blockStart + j;
      final offset = i * 4;
      final l = view.getInt16(offset, Endian.little) / 32768.0;
      final r = view.getInt16(offset + 2, Endian.little) / 32768.0;
      final double wL;
      final double wR;
      if (j < rampLen) {
        final alpha = (j + 1) / rampLen;
        wL = prevWL + (targetWL - prevWL) * alpha;
        wR = prevWR + (targetWR - prevWR) * alpha;
      } else {
        wL = targetWL;
        wR = targetWR;
      }
      final mixed = wL * l + wR * r;
      output[i] = mixed.clamp(-1.0, 1.0);
    }
    prevWL = targetWL;
    prevWR = targetWR;
  }

  return output;
}

/// Merges nearby VAD spans and rolls back the window cut point when a trailing
/// utterance touches the right window edge so sentences are not split mid-word.
VadWindowPlan planVadWindowSlices({
  required int windowStartFrame,
  required int windowFrameCount,
  required bool isFinalWindow,
  required List<AsrVadSpan> spans,
  int sampleRate = 16000,
  double mergeGapSeconds = 1.8,
  double maxSliceSeconds = 26.0,
  double boundaryGuardSeconds = 0.25,
  int minAdvanceSeconds = 10,
}) {
  if (windowFrameCount <= 0 || sampleRate <= 0) {
    return VadWindowPlan(slices: const [], nextFrameOffset: windowStartFrame);
  }
  final windowDuration = windowFrameCount / sampleRate;
  final normalized = <({double start, double end})>[];
  for (final span in spans) {
    final s = span.startSeconds.clamp(0.0, windowDuration);
    final e = span.endSeconds.clamp(0.0, windowDuration);
    if (e - s >= 0.08) {
      normalized.add((start: s, end: e));
    }
  }
  if (normalized.isEmpty) {
    return VadWindowPlan(
      slices: const [],
      nextFrameOffset: windowStartFrame + windowFrameCount,
    );
  }
  normalized.sort((a, b) {
    final cmp = a.start.compareTo(b.start);
    return cmp != 0 ? cmp : a.end.compareTo(b.end);
  });

  final merged = <({double start, double end})>[];
  for (final item in normalized) {
    var cursor = item.start;
    while (item.end - cursor > maxSliceSeconds) {
      merged.add((start: cursor, end: cursor + maxSliceSeconds));
      cursor += maxSliceSeconds;
    }
    final piece = (start: cursor, end: item.end);
    if (piece.end - piece.start < 0.08) continue;
    if (merged.isEmpty) {
      merged.add(piece);
      continue;
    }
    final prev = merged.last;
    if (piece.start - prev.end <= mergeGapSeconds &&
        math.max(prev.end, piece.end) - prev.start <= maxSliceSeconds) {
      merged[merged.length - 1] = (
        start: prev.start,
        end: math.max(prev.end, piece.end),
      );
    } else {
      merged.add(piece);
    }
  }

  if (merged.isEmpty) {
    return VadWindowPlan(
      slices: const [],
      nextFrameOffset: windowStartFrame + windowFrameCount,
    );
  }

  var nextOffset = windowStartFrame + windowFrameCount;
  if (!isFinalWindow) {
    final last = merged.last;
    if (last.end >= windowDuration - boundaryGuardSeconds) {
      final rollbackFrames = (last.start * sampleRate).floor();
      final minAdvanceFrames = minAdvanceSeconds * sampleRate;
      if (rollbackFrames >= minAdvanceFrames) {
        merged.removeLast();
        nextOffset = windowStartFrame + rollbackFrames;
      }
    }
  }

  final slices = <({int startFrame, int endFrame})>[];
  for (final span in merged) {
    final s = (span.start * sampleRate).floor().clamp(0, windowFrameCount);
    final e = (span.end * sampleRate).ceil().clamp(0, windowFrameCount);
    if (e > s) {
      slices.add((startFrame: s, endFrame: e));
    }
  }
  return VadWindowPlan(slices: slices, nextFrameOffset: nextOffset);
}

/// Applies gentle linear gain to quiet whisper slices while rejecting near-zero
/// digital noise floors.
Float32List? normalizeWhisperSlice(Float32List samples) {
  if (samples.isEmpty) return null;
  var peak = 0.0;
  for (var i = 0; i < samples.length; i++) {
    final absVal = samples[i].abs();
    if (absVal > peak) peak = absVal;
  }
  if (peak < 0.003) return null;
  if (peak >= 0.25) return samples;
  final gain = math.min(3.5, 0.35 / peak);
  final out = Float32List(samples.length);
  for (var i = 0; i < samples.length; i++) {
    out[i] = (samples[i] * gain).clamp(-1.0, 1.0);
  }
  return out;
}

final RegExp _specialTokenPattern = RegExp(r'<\|[^>]*\|>|\[_[^\]]*\]');
final RegExp _pureStageDirectionPattern = RegExp(
  r'^[\s(\[（【｛<〈]*(?:音楽|拍手|笑|笑い|咳|ため息|吐息|環境音|雑音|無音|BGM|SE|music|applause|sigh|whispering)[\s)\]）】｝>〉.!！?？…♪]*$',
  caseSensitive: false,
);
final RegExp _meaningfulTextPattern = RegExp(
  r'[\u3040-\u30ff\u3400-\u9fffA-Za-z0-9]',
);
final RegExp _hallucinationBoilerplatePattern = RegExp(
  r'^(?:ご視聴ありがとうございました|ご視聴ありがとうございます|チャンネル登録(?:よろしく)?(?:お願いします)?|高評価(?:よろしく)?(?:お願いします)?|字幕(?:作成|提供|協力).*|Subtitles by .*|Amara\.org.*)$',
  caseSensitive: false,
);
final RegExp _repetitionLoopPattern = RegExp(
  r'(([^\s、，,]{1,4})([、，,\s]*))(?:\1){5,}(?:\2)?',
);
final RegExp _sentenceEndPunctuation = RegExp(r'[。！？!?♪]$');
final RegExp _clausePausePunctuation = RegExp(r'[、，,]$');
final RegExp _whitespaceCollapse = RegExp(r'[ \t]+');

String? cleanTranscribedText(String raw, {double noSpeechProb = -1.0}) {
  if (noSpeechProb >= 0.80) return null;
  var text = raw.replaceAll(_specialTokenPattern, '').trim();
  if (text.isEmpty) return null;
  text = text.replaceAll(_whitespaceCollapse, ' ').trim();
  if (_pureStageDirectionPattern.hasMatch(text)) return null;
  if (!_meaningfulTextPattern.hasMatch(text)) return null;

  final normalizedForCheck = text.replaceAll(RegExp(r'[。！!？?…・\s]'), '');
  if (_hallucinationBoilerplatePattern.hasMatch(normalizedForCheck) ||
      _hallucinationBoilerplatePattern.hasMatch(text)) {
    return null;
  }

  // Collapse decoder repetition loops such as "あ、あ、あ、あ、あ、あ..."
  text = text.replaceAllMapped(_repetitionLoopPattern, (match) {
    final stem = match.group(2)!;
    final sep = match.group(3)!;
    return '$stem$sep$stem$sep$stem…';
  });

  if (noSpeechProb >= 0.55 && normalizedForCheck.runes.length <= 2) {
    return null;
  }
  return text.trim().isEmpty ? null : text.trim();
}

/// Converts raw ASR segments into ordered, non-overlapping [SubtitleCue] items
/// that satisfy `PlaybackSubtitleService` validation constraints.
List<SubtitleCue> buildSanitizedTranscriptionCues(
  List<AsrRawSegment> rawSegments, {
  Duration? maxDuration,
}) {
  const minCueMs = 200;
  final maxMs = maxDuration?.inMilliseconds;
  if (maxMs != null && maxMs < minCueMs) {
    return const <SubtitleCue>[];
  }

  final pieces = <({int startMs, int endMs, String text})>[];
  for (final seg in rawSegments) {
    final cleaned = cleanTranscribedText(
      seg.text,
      noSpeechProb: seg.noSpeechProb,
    );
    if (cleaned == null) continue;
    pieces.addAll(_splitSegmentIntoPieces(seg, cleaned));
  }
  if (pieces.isEmpty) return const <SubtitleCue>[];

  final clamped = <({int startMs, int endMs, String text})>[];
  for (final item in pieces) {
    var s = math.max(0, item.startMs);
    var e = math.max(s + minCueMs, item.endMs);
    if (maxMs != null) {
      if (s >= maxMs) s = math.max(0, maxMs - minCueMs);
      if (e > maxMs) e = maxMs;
      if (e <= s) continue;
    }
    clamped.add((startMs: s, endMs: e, text: item.text));
  }
  if (clamped.isEmpty) return const <SubtitleCue>[];

  clamped.sort((a, b) {
    final cmp = a.startMs.compareTo(b.startMs);
    return cmp != 0 ? cmp : a.endMs.compareTo(b.endMs);
  });

  final ordered = <({int startMs, int endMs, String text})>[];
  for (final curr in clamped) {
    if (ordered.isEmpty) {
      ordered.add(curr);
      continue;
    }
    final prev = ordered.last;
    if (curr.text == prev.text && (curr.startMs - prev.startMs).abs() < 400) {
      ordered[ordered.length - 1] = (
        startMs: prev.startMs,
        endMs: math.max(prev.endMs, curr.endMs),
        text: prev.text,
      );
      continue;
    }
    if (curr.startMs >= prev.endMs) {
      ordered.add(curr);
      continue;
    }
    // Resolve overlap while keeping each cue at least minCueMs long.
    if (curr.startMs - prev.startMs >= minCueMs) {
      ordered[ordered.length - 1] = (
        startMs: prev.startMs,
        endMs: curr.startMs,
        text: prev.text,
      );
      ordered.add((
        startMs: curr.startMs,
        endMs: math.max(curr.endMs, curr.startMs + minCueMs),
        text: curr.text,
      ));
    } else {
      final adjustedPrevEnd = prev.startMs + minCueMs;
      if (maxMs != null && adjustedPrevEnd + minCueMs > maxMs) {
        // Not enough room at the end of the track for a separate cue; merge.
        ordered[ordered.length - 1] = (
          startMs: prev.startMs,
          endMs: maxMs,
          text: '${prev.text} ${curr.text}'.trim(),
        );
      } else {
        ordered[ordered.length - 1] = (
          startMs: prev.startMs,
          endMs: adjustedPrevEnd,
          text: prev.text,
        );
        final shiftedStart = adjustedPrevEnd;
        var shiftedEnd = math.max(curr.endMs, shiftedStart + minCueMs);
        if (maxMs != null && shiftedEnd > maxMs) {
          shiftedEnd = maxMs;
        }
        if (shiftedEnd > shiftedStart) {
          ordered.add((
            startMs: shiftedStart,
            endMs: shiftedEnd,
            text: curr.text,
          ));
        }
      }
    }
  }

  return <SubtitleCue>[
    for (final item in ordered)
      if (item.endMs > item.startMs && item.text.trim().isNotEmpty)
        SubtitleCue(
          start: Duration(milliseconds: item.startMs),
          end: Duration(milliseconds: item.endMs),
          text: item.text,
        ),
  ];
}

List<({int startMs, int endMs, String text})> _splitSegmentIntoPieces(
  AsrRawSegment seg,
  String cleanedText,
) {
  const maxChars = 42;
  const maxDurationSec = 8.0;
  const silenceBreakSec = 1.0;
  final segDuration = seg.endSeconds - seg.startSeconds;
  final validWords = <AsrWordTiming>[
    for (final w in seg.words)
      if (w.text.replaceAll(_specialTokenPattern, '').isNotEmpty &&
          w.endSeconds >= w.startSeconds)
        w,
  ];
  var hasSilenceBreak = false;
  for (var i = 0; i + 1 < validWords.length; i++) {
    if (validWords[i + 1].startSeconds - validWords[i].endSeconds >=
        silenceBreakSec) {
      hasSilenceBreak = true;
      break;
    }
  }
  if (validWords.length < 2 ||
      (!hasSilenceBreak &&
          cleanedText.runes.length <= maxChars &&
          segDuration <= maxDurationSec)) {
    return <({int startMs, int endMs, String text})>[
      (
        startMs: (seg.startSeconds * 1000).round(),
        endMs: (seg.endSeconds * 1000).round(),
        text: cleanedText,
      ),
    ];
  }

  final pieces = <({int startMs, int endMs, String text})>[];
  final buffer = StringBuffer();
  double? chunkStart;
  double? chunkEnd;
  var charCount = 0;

  void flushChunk() {
    final built = cleanTranscribedText(buffer.toString());
    if (built != null && chunkStart != null && chunkEnd != null) {
      pieces.add((
        startMs: (chunkStart! * 1000).round(),
        endMs: (chunkEnd! * 1000).round(),
        text: built,
      ));
    }
    buffer.clear();
    chunkStart = null;
    chunkEnd = null;
    charCount = 0;
  }

  for (var i = 0; i < validWords.length; i++) {
    final word = validWords[i];
    final wordText = word.text.replaceAll(_specialTokenPattern, '');
    if (wordText.isEmpty) continue;
    chunkStart ??= math.max(seg.startSeconds, word.startSeconds);
    chunkEnd = math.max(chunkStart!, word.endSeconds);
    buffer.write(wordText);
    charCount += wordText.runes.length;

    final isLast = i == validWords.length - 1;
    if (isLast) {
      chunkEnd = math.max(chunkEnd!, seg.endSeconds);
      flushChunk();
      break;
    }

    final gapToNext = validWords[i + 1].startSeconds - word.endSeconds;
    final spanSec = chunkEnd! - chunkStart!;
    final hitSilenceGap = charCount >= 2 && gapToNext >= silenceBreakSec;
    final hitSentenceEnd =
        charCount >= 12 && _sentenceEndPunctuation.hasMatch(wordText.trim());
    final hitPauseBreak =
        (charCount >= 20 && gapToNext >= 0.35) ||
        (charCount >= 24 && _clausePausePunctuation.hasMatch(wordText.trim()));
    final hitHardLimit = charCount >= maxChars || spanSec >= 10.0;

    if (hitSilenceGap || hitSentenceEnd || hitPauseBreak || hitHardLimit) {
      flushChunk();
    }
  }

  if (pieces.isEmpty) {
    return <({int startMs, int endMs, String text})>[
      (
        startMs: (seg.startSeconds * 1000).round(),
        endMs: (seg.endSeconds * 1000).round(),
        text: cleanedText,
      ),
    ];
  }
  return pieces;
}
