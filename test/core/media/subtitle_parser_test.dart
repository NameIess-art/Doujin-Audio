import 'package:doujin_audio/core/media/subtitle_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ASS timestamp fractional precision (#71)', () {
    test('parses 1-digit and 2-digit fractional seconds accurately', () {
      const raw = '''
[Script Info]
ScriptType: v4.00+

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:01.5,0:00:02.5,Default,,0,0,0,,Tenths
Dialogue: 0,0:00:03.05,0:00:04.50,Default,,0,0,0,,Centiseconds
''';

      final track = parseSubtitleTrackSync(
        sourcePath: 'sample.ass',
        raw: raw,
        extension: '.ass',
      );

      expect(track, isNotNull);
      expect(track!.cues, hasLength(2));
      expect(track.cues[0].start, const Duration(milliseconds: 1500));
      expect(track.cues[0].end, const Duration(milliseconds: 2500));
      expect(track.cues[1].start, const Duration(milliseconds: 3050));
      expect(track.cues[1].end, const Duration(milliseconds: 4500));
    });
  });

  group('SubtitleTrack timelineCues and timelineCueIndexAt (#22)', () {
    test(
      'preserves source order in cues while exposing time-ordered timelineCues and binary search',
      () {
        const raw = '''
[Script Info]
ScriptType: v4.00+

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:30.00,0:00:35.00,Title,,0,0,0,,Late sign
Dialogue: 0,0:00:02.00,0:00:05.00,Default,,0,0,0,,First line
Dialogue: 0,0:00:10.00,0:00:14.00,Default,,0,0,0,,Second line
Dialogue: 0,0:00:10.00,0:00:12.00,Default,,0,0,0,,Second line tie
''';

        final track = parseSubtitleTrackSync(
          sourcePath: 'unordered.ass',
          raw: raw,
          extension: '.ass',
        )!;

        // Source order stays intact for ASS editing.
        expect(track.cues.map((cue) => cue.text).toList(), [
          'Late sign',
          'First line',
          'Second line',
          'Second line tie',
        ]);

        // Timeline view order is stably sorted by start time.
        expect(track.timelineCues.map((cue) => cue.text).toList(), [
          'First line',
          'Second line',
          'Second line tie',
          'Late sign',
        ]);

        expect(track.timelineCueIndexAt(Duration.zero), 0);
        expect(track.timelineCueIndexAt(const Duration(seconds: 3)), 0);
        expect(track.timelineCueIndexAt(const Duration(seconds: 10)), 2);
        expect(track.timelineCueIndexAt(const Duration(seconds: 32)), 3);

        final shifted = track.withOffset(const Duration(seconds: 5));
        expect(identical(shifted.timelineCues, track.timelineCues), isTrue);
        expect(shifted.timelineCueIndexAt(const Duration(seconds: 6)), 0);
        expect(shifted.timelineCueIndexAt(const Duration(seconds: 15)), 2);
        expect(shifted.timelineCueIndexAt(const Duration(seconds: 36)), 3);
      },
    );

    test('returns null timelineCueIndexAt for empty track', () {
      final track = SubtitleTrack(sourcePath: 'empty.srt', cues: const []);
      expect(track.timelineCues, isEmpty);
      expect(track.timelineCueIndexAt(const Duration(seconds: 1)), isNull);
    });
  });
}
