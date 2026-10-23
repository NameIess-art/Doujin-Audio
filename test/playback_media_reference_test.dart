import 'package:doujin_audio/core/media/playback_media_reference.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'chapters sharing a stream keep separate identities and strip transport fragment',
    () {
      final first = PlaybackMediaReference.parse(
        'https://v.weeab0o.xyz/RJ1.m3u8#eara-chapter=0,1000&file=one.mp3&download=https%3A%2F%2Fexample.com%2Fone',
      );
      final second = PlaybackMediaReference.parse(
        'https://v.weeab0o.xyz/RJ1.m3u8#eara-chapter=1000,3000&file=two.mp3',
      );
      expect(first.streamUrl, second.streamUrl);
      expect(first.streamUrl, 'https://v.weeab0o.xyz/RJ1.m3u8');
      expect(first.logicalUrl, isNot(second.logicalUrl));
      expect(first.durationMs, 1000);
      expect(second.durationMs, 2000);
      expect(first.downloadUrl, 'https://example.com/one');
      expect(first.httpHeaders, {'Referer': 'https://japaneseasmr.com/'});
      expect(
        PlaybackMediaReference.fromJson(first.toJson()).toJson(),
        first.toJson(),
      );
      expect(
        PlaybackMediaReference.parse(first.logicalUrl).toJson(),
        first.toJson(),
      );
    },
  );
  test(
    'ordinary sources retain their address and do not receive Japanese headers',
    () {
      final reference = PlaybackMediaReference.parse(
        'https://example.com/file.wav#marker',
      );
      expect(reference.streamUrl, 'https://example.com/file.wav#marker');
      expect(reference.isChapter, false);
      expect(reference.httpHeaders, isEmpty);
      expect(
        PlaybackMediaReference.requestHeadersForUri(
          Uri.parse('https://v.weeab0o.xyz.evil.test/x'),
        ),
        isEmpty,
      );
    },
  );
  test('invalid chapter boundaries are rejected', () {
    for (final value in ['-1,100', '100,99', 'no,100']) {
      expect(
        () => PlaybackMediaReference.parse(
          'https://example.com/a.m3u8#eara-chapter=$value',
        ),
        throwsFormatException,
      );
    }
  });
}
