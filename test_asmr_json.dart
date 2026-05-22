import 'dart:convert';
import 'lib/models/asmr_models.dart';

void main() {
  final work = AsmrWork(
    id: 1,
    title: 'Test',
    circleName: 'Circle',
    sourceId: 'RJ123',
    sourceType: 'DLsite',
    sourceUrl: 'url',
    coverUrl: 'cover',
    thumbnailUrl: 'thumb',
    mainCoverUrl: 'main',
    releaseDate: DateTime.now(),
    createDate: DateTime.now(),
    duration: Duration(minutes: 5),
    dlCount: 10,
    reviewCount: 5,
    rating: 4.5,
    voiceActors: ['VA1'],
    tags: ['Tag1'],
    hasSubtitle: true,
    isFavorite: true,
  );
  
  final jsonStr = json.encode(work.toJson());
  print('Encoded: $jsonStr');
  
  try {
    final decoded = AsmrWork.fromJson(json.decode(jsonStr) as Map<String, dynamic>);
    print('Decoded success: ${decoded.title}');
  } catch (e, stackTrace) {
    print('Error: $e');
    print(stackTrace);
  }
}
