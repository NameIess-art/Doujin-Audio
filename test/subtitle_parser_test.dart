import 'package:doujin_audio/core/media/subtitle_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses LRC with leading BOM and offset tag', () async {
    final track = await parseSubtitleTrackFromRaw(
      sourcePath: 'test.lrc',
      raw: '\uFEFF[offset:500]\n[00:01.00]Hello\n[00:03.00]World',
      extension: '.lrc',
    );

    expect(track, isNotNull);
    expect(track!.cues, hasLength(2));
    expect(track.cues.first.start, const Duration(milliseconds: 1500));
    expect(track.cues.first.text, 'Hello');
  });

  test('parses WebVTT header line with title metadata', () async {
    final track = await parseSubtitleTrackFromRaw(
      sourcePath: 'test.vtt',
      raw: 'WEBVTT - Sample Track\n\n00:00:01.000 --> 00:00:03.000\nLine one',
      extension: '.vtt',
    );

    expect(track, isNotNull);
    expect(track!.cues, hasLength(1));
    expect(track.cues.first.start, const Duration(seconds: 1));
    expect(track.cues.first.end, const Duration(seconds: 3));
    expect(track.cues.first.text, 'Line one');
  });

  test('parses WebVTT cues with identifiers starting with NOTE while skipping comments', () async {
    final track = await parseSubtitleTrackFromRaw(
      sourcePath: 'notes.vtt',
      raw: '''
WEBVTT

NOTE
This multiline comment
should be ignored.

NOTE inline comment
Still a comment.

NOTE\ttab comment

NOTE1
00:00:01.000 --> 00:00:02.000
First cue

NOTE-2
00:00:03.000 --> 00:00:04.000
Second cue
''',
      extension: '.vtt',
    );

    expect(track, isNotNull);
    expect(track!.cues, hasLength(2));
    expect(track.cues[0].text, 'First cue');
    expect(track.cues[1].text, 'Second cue');
  });
}
