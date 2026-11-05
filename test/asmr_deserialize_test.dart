import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';

void main() {
  for (final field in ['voiceActors', 'vas']) {
    test('AsmrWork reads $field from frozen track metadata', () {
      final track = MusicTrack(
        path: 'https://example.test/audio.mp3',
        displayName: 'Track',
        groupKey: 'asmr-123',
        groupTitle: 'Work',
        groupSubtitle: '',
        isSingle: false,
        remoteMetadataKind: MusicTrack.remoteMetadataKindAsmrOne,
        remoteMetadata: {
          'id': 123,
          'title': 'Work',
          field: [
            {'name': 'Actor one'},
            'Actor two',
            {'id': 3},
          ],
        },
      );

      final work = AsmrWork.fromJson(track.remoteMetadata!);

      expect(work.voiceActors, ['Actor one', 'Actor two']);
    });
  }

  test('AsmrWork serialization/deserialization', () {
    final works = [
      AsmrWork(
        id: 123,
        title: 'Test Title',
        circleName: 'Test Circle',
        sourceId: 'RJ123456',
        sourceType: 'DLsite',
        sourceUrl: 'http://test.com',
        coverUrl: 'http://test.com/cover',
        thumbnailUrl: 'http://test.com/thumb',
        mainCoverUrl: 'http://test.com/main',
        releaseDate: DateTime.now(),
        createDate: DateTime.now(),
        duration: const Duration(hours: 1),
        dlCount: 100,
        reviewCount: 50,
        rating: 4.5,
        voiceActors: const ['Actor1'],
        tags: const ['Tag1'],
        isFavorite: true,
      ),
    ];

    final payload = works.map((w) => w.toJson()).toList();
    final jsonStr = json.encode(payload);

    // Simulate AppPreferences.readJson
    final decoded = json.decode(jsonStr);

    try {
      final list = decoded as List<dynamic>? ?? const <dynamic>[];
      final mapped = list
          .whereType<Map<Object?, Object?>>()
          .map(
            (item) => AsmrWork.fromJson(
              item.map((key, value) => MapEntry(key.toString(), value)),
            ),
          )
          .toList(growable: false);
      expect(mapped.length, 1);
    } catch (e) {
      fail('Failed: $e');
    }
  });
}
