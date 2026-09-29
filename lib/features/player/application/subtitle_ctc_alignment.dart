import 'dart:typed_data';

class CtcAlignedLine {
  const CtcAlignedLine(this.text, this.startSeconds, this.endSeconds);

  final String text;
  final double startSeconds;
  final double endSeconds;
}

/// Aligns a supplied script against consecutive CTC grids.
/// The caller must supply the blank ID and each grid's actual audio duration.
class SubtitleCtcAlignment {
  SubtitleCtcAlignment({
    required List<String> lines,
    required List<String> vocab,
    required int blankId,
  }) : _lines = List.of(lines),
       _blankId = blankId,
       _vocabSize = vocab.length {
    if (lines.isEmpty || blankId < 0 || blankId >= vocab.length) {
      throw ArgumentError('Invalid CTC transcript or blank ID');
    }
    final tokenIds = <String, int>{
      for (var i = 0; i < vocab.length; i++) vocab[i]: i,
    };
    final boundary = tokenIds['|'];
    final words = <({String text, int line})>[];
    for (var line = 0; line < lines.length; line++) {
      var current = '';
      void flush() {
        if (current.isEmpty) return;
        words.add((text: current, line: line));
        current = '';
      }

      for (final rune in lines[line].runes) {
        final character = String.fromCharCode(rune);
        if (rune == 0x20 ||
            rune == 0x09 ||
            rune == 0x0a ||
            rune == 0x0d ||
            _isAlignmentPunctuation(rune)) {
          flush();
        } else if (_isCjk(rune)) {
          flush();
          words.add((text: character, line: line));
        } else {
          current += character;
        }
      }
      flush();
    }
    for (var word = 0; word < words.length; word++) {
      if (word > 0 && boundary != null && boundary != blankId) {
        _labels.add(boundary);
        _lineForLabel.add(-1);
      }
      for (final rune in words[word].text.runes) {
        final character = String.fromCharCode(rune);
        final id = rune < 128
            ? tokenIds[character.toLowerCase()] ?? tokenIds[character]
            : tokenIds[character];
        if (id == null || id == blankId) continue;
        _labels.add(id);
        _lineForLabel.add(words[word].line);
      }
    }
    final states = _labels.length * 2 + 1;
    _scores = List<double>.filled(states, double.negativeInfinity);
  }

  final List<String> _lines;
  final int _blankId;
  final int _vocabSize;
  final List<int> _labels = [];
  final List<int> _lineForLabel = [];
  // Four two-bit transition sources (stay, advance, skip) per byte.
  final List<Uint8List> _back = [];
  final List<({double start, double end})> _times = [];
  late List<double> _scores;
  bool _finished = false;

  void addChunk({
    required Float32List logits,
    required int nFrames,
    required int nVocab,
    required double startSeconds,
    required double durationSeconds,
  }) {
    if (_finished ||
        nFrames <= 0 ||
        nVocab != _vocabSize ||
        logits.length != nFrames * nVocab ||
        !startSeconds.isFinite ||
        startSeconds < 0 ||
        !durationSeconds.isFinite ||
        durationSeconds <= 0 ||
        (_times.isNotEmpty && (startSeconds - _times.last.end).abs() > 1e-4)) {
      throw ArgumentError('Invalid or non-contiguous CTC chunk');
    }
    final frameDuration = durationSeconds / nFrames;
    final stateCount = _scores.length;
    for (var frame = 0; frame < nFrames; frame++) {
      final offset = frame * nVocab;
      for (var token = 0; token < nVocab; token++) {
        if (!logits[offset + token].isFinite) {
          throw ArgumentError('Non-finite CTC logits');
        }
      }
      final back = Uint8List((stateCount + 3) >> 2);
      if (_times.isEmpty) {
        _scores[0] = logits[offset + _blankId];
        if (stateCount > 1) {
          _scores[1] = logits[offset + _labels[0]];
        }
      } else {
        final next = List<double>.filled(stateCount, double.negativeInfinity);
        for (var state = 0; state < stateCount; state++) {
          final token = state.isEven ? _blankId : _labels[state ~/ 2];
          var best = _scores[state];
          var source = 0;
          if (state >= 1 && _scores[state - 1] > best) {
            best = _scores[state - 1];
            source = 1;
          }
          if (state >= 2 &&
              token != _blankId &&
              token != _labels[(state - 2) ~/ 2] &&
              _scores[state - 2] > best) {
            best = _scores[state - 2];
            source = 2;
          }
          if (best.isFinite) {
            next[state] = best + logits[offset + token];
            back[state >> 2] |= source << ((state & 3) * 2);
          }
        }
        _scores = next;
      }
      _back.add(back);
      final frameStart = startSeconds + frame * frameDuration;
      _times.add((start: frameStart, end: frameStart + frameDuration));
    }
  }

  /// Advances through unavailable or silent audio without assigning text to it.
  void addSilence({
    required double startSeconds,
    required double durationSeconds,
  }) {
    if (_finished ||
        !startSeconds.isFinite ||
        startSeconds < 0 ||
        !durationSeconds.isFinite ||
        durationSeconds <= 0 ||
        (_times.isNotEmpty && (startSeconds - _times.last.end).abs() > 1e-4)) {
      throw ArgumentError('Invalid or non-contiguous silent interval');
    }
    final next = List<double>.filled(_scores.length, double.negativeInfinity);
    final back = Uint8List((_scores.length + 3) >> 2);
    if (_times.isEmpty) {
      next[0] = 0;
    } else {
      for (var state = 0; state < _scores.length; state += 2) {
        var best = _scores[state];
        if (state > 0 && _scores[state - 1] > best) {
          best = _scores[state - 1];
          back[state >> 2] |= 1 << ((state & 3) * 2);
        }
        next[state] = best;
      }
    }
    _scores = next;
    _back.add(back);
    _times.add((start: startSeconds, end: startSeconds + durationSeconds));
  }

  /// Returns null for lines with no vocabulary characters or no valid path.
  List<CtcAlignedLine?> finish() {
    if (_finished) throw StateError('CTC alignment already finished');
    _finished = true;
    final result = List<CtcAlignedLine?>.filled(_lines.length, null);
    if (_labels.isEmpty || _times.isEmpty) return result;
    var state = _scores.length - 1;
    if (_scores[state - 1] > _scores[state]) state--;
    if (!_scores[state].isFinite) return result;

    final starts = List<double?>.filled(_lines.length, null);
    final ends = List<double?>.filled(_lines.length, null);
    for (var frame = _times.length - 1; frame >= 0; frame--) {
      if (state.isOdd) {
        final line = _lineForLabel[state ~/ 2];
        if (line >= 0) {
          ends[line] ??= _times[frame].end;
          starts[line] = _times[frame].start;
        }
      }
      if (frame > 0) {
        state -= (_back[frame][state >> 2] >> ((state & 3) * 2)) & 3;
      }
    }
    for (var line = 0; line < _lines.length; line++) {
      final start = starts[line];
      final end = ends[line];
      if (start != null && end != null) {
        result[line] = CtcAlignedLine(_lines[line], start, end);
      }
    }
    return result;
  }
}

bool _isCjk(int rune) =>
    (rune >= 0x4e00 && rune <= 0x9fff) ||
    (rune >= 0x3400 && rune <= 0x4dbf) ||
    (rune >= 0x3040 && rune <= 0x309f) ||
    (rune >= 0x30a0 && rune <= 0x30ff) ||
    (rune >= 0xac00 && rune <= 0xd7af) ||
    (rune >= 0x3000 && rune <= 0x303f) ||
    (rune >= 0xff00 && rune <= 0xffef);

bool _isAlignmentPunctuation(int rune) {
  if (rune == 0x27) return false;
  if (rune < 0x80) {
    return !(rune >= 0x30 && rune <= 0x39) &&
        !(rune >= 0x41 && rune <= 0x5a) &&
        !(rune >= 0x61 && rune <= 0x7a) &&
        rune != 0x20 &&
        rune != 0x09 &&
        rune != 0x0a &&
        rune != 0x0d &&
        rune != 0x0b &&
        rune != 0x0c;
  }
  return (rune >= 0x2000 && rune <= 0x206f) ||
      (rune >= 0x3000 && rune <= 0x303f) ||
      (rune >= 0xfe10 && rune <= 0xfe1f) ||
      (rune >= 0xfe30 && rune <= 0xfe4f) ||
      (rune >= 0xff00 && rune <= 0xff65);
}
