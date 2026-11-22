import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/media/media_file_support.dart';

void main() {
  test('supported media detection accepts audio and video containers', () {
    expect(isSupportedMediaFile('/library/voice.mp3'), isTrue);
    expect(isSupportedMediaFile('/library/clip.mp4'), isTrue);
    expect(isSupportedMediaFile('/library/movie.mkv'), isTrue);
    expect(isSupportedMediaFile('/library/cover.jpg'), isFalse);
  });

  test('video media detection distinguishes video containers', () {
    expect(isVideoMediaFile('/library/clip.mp4'), isTrue);
    expect(isVideoMediaFile('/library/movie.webm'), isTrue);
    expect(isVideoMediaFile('/library/voice.m4a'), isFalse);
  });

  test('HTTP(S) URLs strip query and fragment before media format checks', () {
    expect(
      isVideoMediaFile('https://cdn.example.com/media/clip.mp4?token=abc#t=10'),
      isTrue,
    );
    expect(
      isSupportedMediaFile(
        'https://cdn.example.com/media/clip.mp4?token=abc#t=10',
      ),
      isTrue,
    );
    expect(
      isSupportedMediaFile('http://cdn.example.com/audio/track.MP3?sig=1'),
      isTrue,
    );
    expect(
      isVideoMediaFile('http://cdn.example.com/audio/track.MP3?sig=1'),
      isFalse,
    );
    expect(
      isSupportedMediaFile('https://cdn.example.com/cover.jpg?v=2#top'),
      isFalse,
    );
    expect(isVideoMediaFile('/library/clip#1.mp4'), isTrue);
  });
}
