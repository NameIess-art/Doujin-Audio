import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/models/music_track.dart';
import 'package:nameless_audio/models/time_segment_label.dart';
import 'package:nameless_audio/services/path_matcher.dart';

void main() {
  test('uses normalized local path as track key', () {
    const track = MusicTrack(
      path: '/library/work/../work/01.mp3',
      displayName: '01',
      groupKey: '/library/work',
      groupTitle: 'Work',
      groupSubtitle: '/library/work',
      isSingle: false,
    );

    expect(
      TimeSegmentLabel.trackKeyFor(track),
      PathMatcher.normalize('/library/work/01.mp3'),
    );
  });

  test('uses stable ASMR source id and relative path as track key', () {
    const track = MusicTrack(
      path: 'https://example.com/temporary-url.mp3',
      displayName: 'Track',
      groupKey: 'asmr-work-1',
      groupTitle: 'Work',
      groupSubtitle: 'RJ123456',
      isSingle: false,
      remoteMetadataKind: 'asmr.one',
      remoteMetadata: <String, Object?>{
        'sourceId': 'RJ123456',
        'trackRelativePath': 'audio/track.mp3',
      },
    );

    expect(
      TimeSegmentLabel.trackKeyFor(track),
      'asmr.one:RJ123456:audio/track.mp3',
    );
  });

  test('falls back to normalized path when ASMR metadata is incomplete', () {
    const track = MusicTrack(
      path: 'https://example.com/track.mp3',
      displayName: 'Track',
      groupKey: 'asmr-work-1',
      groupTitle: 'Work',
      groupSubtitle: 'RJ123456',
      isSingle: false,
      remoteMetadataKind: 'asmr.one',
      remoteMetadata: <String, Object?>{'sourceId': 'RJ123456'},
    );

    expect(
      TimeSegmentLabel.trackKeyFor(track),
      'https://example.com/track.mp3',
    );
  });
}
