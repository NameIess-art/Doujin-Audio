import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/services/media_file_support.dart';

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
}
