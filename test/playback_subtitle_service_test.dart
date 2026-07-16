import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/features/player/application/playback_subtitle_service.dart';

void main() {
  test('loads, caches, and clears a local subtitle track', () async {
    final directory = await Directory.systemTemp.createTemp(
      'nameless_audio_subtitle_',
    );
    addTearDown(() => directory.delete(recursive: true));
    final audioPath = '${directory.path}${Platform.pathSeparator}track.mp3';
    final subtitlePath = '${directory.path}${Platform.pathSeparator}track.lrc';
    await File(audioPath).writeAsBytes(const <int>[]);
    await File(subtitlePath).writeAsString('[00:01.00]first line');

    var loadedCount = 0;
    final service = PlaybackSubtitleService(
      trackResolver: (_) => null,
      onTrackLoaded: (_, _) => loadedCount++,
    );

    final first = await service.load(audioPath);
    final second = await service.load(audioPath);

    expect(first, isNotNull);
    expect(second, same(first));
    expect(service.trackSync(audioPath), same(first));
    expect(
      service.textAt(audioPath, const Duration(milliseconds: 1100)),
      'first line',
    );
    expect(loadedCount, 1);

    service.clear();
    expect(service.hasResult(audioPath), isFalse);
    expect(service.trackSync(audioPath), isNull);
  });
}
