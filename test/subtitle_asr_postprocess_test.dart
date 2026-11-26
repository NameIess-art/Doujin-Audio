import 'dart:convert';
import 'dart:typed_data';

import 'package:doujin_audio/features/player/application/subtitle_asr_postprocess.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _encodeStereoS16Le(List<(double, double)> frames) {
  final bytes = ByteData(frames.length * 4);
  for (var i = 0; i < frames.length; i++) {
    final (l, r) = frames[i];
    final li = (l * 32767.0).round().clamp(-32768, 32767);
    final ri = (r * 32767.0).round().clamp(-32768, 32767);
    bytes.setInt16(i * 4, li, Endian.little);
    bytes.setInt16(i * 4 + 2, ri, Endian.little);
  }
  return bytes.buffer.asUint8List();
}

void main() {
  group('downmixBinauralS16LeToMonoF32', () {
    test('prevents phase cancellation on inverted binaural channels', () {
      final stereo = _encodeStereoS16Le(
        List<(double, double)>.generate(
          800,
          (i) => i.isEven ? (0.4, -0.4) : (-0.4, 0.4),
        ),
      );
      final mono = downmixBinauralS16LeToMonoF32(stereo);
      expect(mono.length, 800);
      final peak = mono.fold<double>(
        0.0,
        (maxVal, sample) => sample.abs() > maxVal ? sample.abs() : maxVal,
      );
      expect(peak, closeTo(0.4, 0.02));
    });

    test('preserves single-ear whisper amplitude without 6 dB attenuation', () {
      final stereo = _encodeStereoS16Le(
        List<(double, double)>.filled(800, (0.2, 0.0)),
      );
      final mono = downmixBinauralS16LeToMonoF32(stereo);
      expect(mono.last, closeTo(0.2, 0.01));
    });

    test('keeps symmetric stereo amplitude unchanged', () {
      final stereo = _encodeStereoS16Le(
        List<(double, double)>.filled(800, (0.5, 0.5)),
      );
      final mono = downmixBinauralS16LeToMonoF32(stereo);
      expect(mono.last, closeTo(0.5, 0.01));
    });
  });

  group('normalizeWhisperSlice', () {
    test('drops near-silent noise floors and boosts quiet whispers', () {
      final noise = Float32List.fromList([0.001, -0.002, 0.0]);
      expect(normalizeWhisperSlice(noise), isNull);

      final quiet = Float32List.fromList([0.08, -0.04]);
      final boosted = normalizeWhisperSlice(quiet)!;
      expect(boosted[0], closeTo(0.28, 0.001));

      final normal = Float32List.fromList([0.4, -0.3]);
      expect(identical(normalizeWhisperSlice(normal), normal), isTrue);
    });
  });

  group('planVadWindowSlices', () {
    test('merges short gaps and rolls back trailing boundary speech', () {
      const sr = 16000;
      const windowFrames = 60 * sr;
      final plan = planVadWindowSlices(
        windowStartFrame: 0,
        windowFrameCount: windowFrames,
        isFinalWindow: false,
        spans: const [
          AsrVadSpan(startSeconds: 2.0, endSeconds: 5.0),
          AsrVadSpan(startSeconds: 5.3, endSeconds: 8.5),
          AsrVadSpan(startSeconds: 56.0, endSeconds: 59.9),
        ],
      );
      expect(plan.slices.length, 1);
      expect(plan.slices.single.startFrame, 2 * sr);
      expect(plan.slices.single.endFrame, (8.5 * sr).round());
      expect(plan.nextFrameOffset, 56 * sr);
    });

    test('retains trailing utterance on the final window', () {
      const sr = 16000;
      const windowFrames = 30 * sr;
      final plan = planVadWindowSlices(
        windowStartFrame: 60 * sr,
        windowFrameCount: windowFrames,
        isFinalWindow: true,
        spans: const [AsrVadSpan(startSeconds: 26.0, endSeconds: 29.95)],
      );
      expect(plan.slices.length, 1);
      expect(plan.nextFrameOffset, 90 * sr);
    });
  });

  group('buildSanitizedTranscriptionCues', () {
    test(
      'filters hallucinations and stage tags while keeping bedtime dialogue',
      () {
        final cues = buildSanitizedTranscriptionCues(const [
          AsrRawSegment(
            text: 'ご視聴ありがとうございました。',
            startSeconds: 0.0,
            endSeconds: 2.0,
          ),
          AsrRawSegment(text: '（音楽）', startSeconds: 2.5, endSeconds: 4.0),
          AsrRawSegment(
            text: 'ん…',
            startSeconds: 4.5,
            endSeconds: 5.0,
            noSpeechProb: 0.85,
          ),
          AsrRawSegment(
            text: 'おやすみなさい、また明日ね。',
            startSeconds: 6.0,
            endSeconds: 9.0,
            noSpeechProb: 0.12,
          ),
          AsrRawSegment(
            text: 'あ、あ、あ、あ、あ、あ、あ、あ',
            startSeconds: 10.0,
            endSeconds: 12.0,
          ),
        ]);
        expect(cues.map((cue) => cue.text).toList(), [
          'おやすみなさい、また明日ね。',
          'あ、あ、あ…',
        ]);
      },
    );

    test(
      'splits long word-timed segments and guarantees non-overlapping order',
      () {
        final cues = buildSanitizedTranscriptionCues(
          const [
            AsrRawSegment(
              text: '今日も一日お疲れ様でした。ゆっくり目を閉じて休んでくださいね。',
              startSeconds: 1.0,
              endSeconds: 11.0,
              words: [
                AsrWordTiming(
                  text: '今日も一日お疲れ様でした。',
                  startSeconds: 1.0,
                  endSeconds: 4.8,
                ),
                AsrWordTiming(
                  text: 'ゆっくり目を閉じて休んでくださいね。',
                  startSeconds: 5.3,
                  endSeconds: 10.8,
                ),
              ],
            ),
            // Slightly overlapping segment and zero-duration edge case:
            AsrRawSegment(text: 'いい夢見てね。', startSeconds: 10.6, endSeconds: 10.6),
          ],
          maxDuration: const Duration(seconds: 12),
        );

        expect(cues.length, 3);
        expect(cues[0].text, '今日も一日お疲れ様でした。');
        expect(cues[1].text, 'ゆっくり目を閉じて休んでくださいね。');
        expect(cues[2].text, 'いい夢見てね。');
        for (var i = 0; i < cues.length; i++) {
          expect(cues[i].start >= Duration.zero, isTrue);
          expect(cues[i].end - cues[i].start >= const Duration(milliseconds: 200), isTrue);
          if (i > 0) {
            expect(cues[i].start >= cues[i - 1].end, isTrue);
          }
        }
      },
    );

    test(
      'splits short merged segments across internal silence pauses >= 1.0s',
      () {
        final cues = buildSanitizedTranscriptionCues(const [
          AsrRawSegment(
            text: 'おやすみ。また明日ね。',
            startSeconds: 1.0,
            endSeconds: 5.5,
            words: [
              AsrWordTiming(text: 'おやす', startSeconds: 1.0, endSeconds: 1.7),
              AsrWordTiming(text: 'み。', startSeconds: 1.7, endSeconds: 2.1),
              AsrWordTiming(text: 'また', startSeconds: 3.6, endSeconds: 4.2),
              AsrWordTiming(text: '明日ね。', startSeconds: 4.2, endSeconds: 5.5),
            ],
          ),
        ]);
        expect(cues.map((c) => c.text).toList(), ['おやすみ。', 'また明日ね。']);
        expect(cues[0].end, const Duration(milliseconds: 2100));
        expect(cues[1].start, const Duration(milliseconds: 3600));
      },
    );
  });

  group('assembleUtf8AsrTokenWords', () {
    test(
      'reassembles multi-byte Japanese kanji split across byte-level BPE tokens',
      () {
        // 'お疲れ' -> 'お' [E3 81 8A], '疲' [E7 96 B2], 'れ' [E3 82 8C]
        final oBytes = Uint8List.fromList(utf8.encode('お'));
        final tsukaBytes = Uint8List.fromList(utf8.encode('疲'));
        final reBytes = Uint8List.fromList(utf8.encode('れ'));

        final words = assembleUtf8AsrTokenWords([
          (
            bytes: Uint8List.fromList(ascii.encode('[_BEG_]')),
            startSeconds: 0.0,
            endSeconds: 0.0,
          ),
          (bytes: oBytes, startSeconds: 1.00, endSeconds: 1.15),
          // 2-byte prefix of 3-byte '疲' (exact case that threw at offset 2):
          (
            bytes: Uint8List.sublistView(tsukaBytes, 0, 2),
            startSeconds: 1.15,
            endSeconds: 1.24,
          ),
          // Final byte of '疲' fused with 1st byte of 'れ':
          (
            bytes: Uint8List.fromList([tsukaBytes[2], reBytes[0]]),
            startSeconds: 1.24,
            endSeconds: 1.32,
          ),
          // Remaining 2 bytes of 'れ':
          (
            bytes: Uint8List.sublistView(reBytes, 1),
            startSeconds: 1.32,
            endSeconds: 1.45,
          ),
          (
            bytes: Uint8List.fromList(ascii.encode('<|endoftext|>')),
            startSeconds: 1.45,
            endSeconds: 1.45,
          ),
        ]);

        expect(words.map((w) => w.text).toList(), ['お', '疲', 'れ']);
        expect(words[0].startSeconds, closeTo(1.00, 1e-6));
        expect(words[0].endSeconds, closeTo(1.15, 1e-6));
        expect(words[1].startSeconds, closeTo(1.15, 1e-6));
        expect(words[1].endSeconds, closeTo(1.32, 1e-6));
        expect(words[2].startSeconds, closeTo(1.24, 1e-6));
        expect(words[2].endSeconds, closeTo(1.45, 1e-6));
      },
    );

    test('tolerates truncated or malformed UTF-8 bytes without throwing', () {
      final good = utf8.encode('今');
      final words = assembleUtf8AsrTokenWords([
        (
          bytes: Uint8List.fromList([...good, 0xE6, 0x97]),
          startSeconds: 0.5,
          endSeconds: 0.9,
        ),
      ]);
      expect(words.single.text, '今');
    });
  });
}
