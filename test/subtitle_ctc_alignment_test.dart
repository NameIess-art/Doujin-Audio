import 'dart:typed_data';

import 'package:doujin_audio/features/player/application/subtitle_ctc_alignment.dart';
import 'package:flutter_test/flutter_test.dart';

Float32List logitsFor(List<int> bestTokens, int vocabSize) {
  return Float32List.fromList([
    for (final best in bestTokens)
      for (var token = 0; token < vocabSize; token++)
        token == best ? 8.0 : -8.0,
  ]);
}

void main() {
  test(
    'aligns repeated Japanese characters across chunks and preserves silence',
    () {
      final alignment = SubtitleCtcAlignment(
        lines: ['ああ', 'い'],
        vocab: ['<blank>', 'あ', 'い', '|'],
        blankId: 0,
      );

      alignment.addChunk(
        logits: logitsFor([0, 0, 1], 4),
        nFrames: 3,
        nVocab: 4,
        startSeconds: 0,
        durationSeconds: 0.3,
      );
      alignment.addChunk(
        logits: logitsFor([3, 1, 0, 0, 0, 3, 0, 2, 0], 4),
        nFrames: 9,
        nVocab: 4,
        startSeconds: 0.3,
        durationSeconds: 0.9,
      );

      final lines = alignment.finish();
      expect(lines, hasLength(2));
      expect(lines[0]?.startSeconds, closeTo(0.2, 0.001));
      expect(lines[0]?.endSeconds, closeTo(0.5, 0.001));
      expect(lines[1]?.startSeconds, closeTo(1.0, 0.001));
      expect(lines[1]?.endSeconds, closeTo(1.1, 0.001));
    },
  );

  test('CJK characters require word separators when the vocab has a bar', () {
    final alignment = SubtitleCtcAlignment(
      lines: ['あい'],
      vocab: ['<blank>', 'あ', 'い', '|'],
      blankId: 0,
    );
    alignment.addChunk(
      logits: logitsFor([1, 2], 4),
      nFrames: 2,
      nVocab: 4,
      startSeconds: 0,
      durationSeconds: 0.2,
    );
    expect(alignment.finish(), [isNull]);
  });

  test('repeated labels require an intervening blank without a bar', () {
    SubtitleCtcAlignment alignment() => SubtitleCtcAlignment(
      lines: ['ああ'],
      vocab: ['<blank>', 'あ'],
      blankId: 0,
    );
    final tooShort = alignment();
    tooShort.addChunk(
      logits: logitsFor([1, 1], 2),
      nFrames: 2,
      nVocab: 2,
      startSeconds: 0,
      durationSeconds: 0.2,
    );
    expect(tooShort.finish(), [isNull]);

    final valid = alignment();
    valid.addChunk(
      logits: logitsFor([1, 0, 1], 2),
      nFrames: 3,
      nVocab: 2,
      startSeconds: 0,
      durationSeconds: 0.3,
    );
    expect(valid.finish().single?.endSeconds, closeTo(0.3, 0.001));
  });

  test('punctuation is skipped before CTC token lookup', () {
    final alignment = SubtitleCtcAlignment(
      lines: ['。'],
      vocab: ['<blank>', '。', '|'],
      blankId: 0,
    );
    alignment.addChunk(
      logits: logitsFor([1], 3),
      nFrames: 1,
      nVocab: 3,
      startSeconds: 0,
      durationSeconds: 0.1,
    );
    expect(alignment.finish(), [isNull]);
  });

  test('rejects a gap between chunks that would hide unaligned audio', () {
    final alignment = SubtitleCtcAlignment(
      lines: ['あ'],
      vocab: ['<blank>', 'あ'],
      blankId: 0,
    );
    alignment.addChunk(
      logits: logitsFor([1], 2),
      nFrames: 1,
      nVocab: 2,
      startSeconds: 0,
      durationSeconds: 0.1,
    );
    expect(
      () => alignment.addChunk(
        logits: logitsFor([0], 2),
        nFrames: 1,
        nVocab: 2,
        startSeconds: 0.2,
        durationSeconds: 0.1,
      ),
      throwsArgumentError,
    );
  });

  test('one blank-only frame preserves a long silence between lines', () {
    final alignment = SubtitleCtcAlignment(
      lines: ['あ', 'い'],
      vocab: ['<blank>', 'あ', 'い', '|'],
      blankId: 0,
    );
    alignment.addChunk(
      logits: logitsFor([1], 4),
      nFrames: 1,
      nVocab: 4,
      startSeconds: 0,
      durationSeconds: 0.1,
    );
    alignment.addSilence(startSeconds: 0.1, durationSeconds: 5);
    alignment.addChunk(
      logits: logitsFor([3, 2], 4),
      nFrames: 2,
      nVocab: 4,
      startSeconds: 5.1,
      durationSeconds: 0.2,
    );
    final lines = alignment.finish();
    expect(lines[0]?.startSeconds, closeTo(0, 0.001));
    expect(lines[0]?.endSeconds, closeTo(0.1, 0.001));
    expect(lines[1]?.startSeconds, closeTo(5.2, 0.001));
    expect(lines[1]?.endSeconds, closeTo(5.3, 0.001));
  });

  test('packed backpointers retain timing over many CJK lines', () {
    final alignment = SubtitleCtcAlignment(
      lines: List<String>.filled(64, 'あ'),
      vocab: ['<blank>', 'あ', '|'],
      blankId: 0,
    );
    final tokens = List<int>.generate(127, (index) => index.isEven ? 1 : 2);
    alignment.addChunk(
      logits: logitsFor(tokens.sublist(0, 61), 3),
      nFrames: 61,
      nVocab: 3,
      startSeconds: 0,
      durationSeconds: 6.1,
    );
    alignment.addChunk(
      logits: logitsFor(tokens.sublist(61), 3),
      nFrames: 66,
      nVocab: 3,
      startSeconds: 6.1,
      durationSeconds: 6.6,
    );

    final lines = alignment.finish();
    expect(lines, hasLength(64));
    for (var index = 0; index < lines.length; index++) {
      expect(lines[index]?.startSeconds, closeTo(index * 0.2, 0.001));
      expect(lines[index]?.endSeconds, closeTo(index * 0.2 + 0.1, 0.001));
    }
  });
}
