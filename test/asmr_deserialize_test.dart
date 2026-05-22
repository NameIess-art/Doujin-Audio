import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/models/asmr_models.dart';

void main() {
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
