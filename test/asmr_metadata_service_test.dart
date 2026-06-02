import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/models/asmr_models.dart';
import 'package:nameless_audio/services/asmr_api_service.dart';
import 'package:nameless_audio/services/asmr_metadata_service.dart';

void main() {
  test('fetchByRjCode returns exact ASMR.ONE work metadata', () async {
    final service = AsmrMetadataService(
      apiService: _FakeAsmrApiService(
        works: [
          _work(sourceId: 'RJ000001', title: 'Other'),
          _work(
            sourceId: 'RJ123456',
            title: 'Target',
            releaseDate: DateTime(2024, 5, 6),
            dlCount: 1234,
            rating: 4.5,
          ),
        ],
      ),
    );

    final metadata = await service.fetchByRjCode('folder RJ123456');

    expect(metadata.rjCode, 'RJ123456');
    expect(metadata.workTitle, 'Target');
    expect(metadata.releaseDate, DateTime(2024, 5, 6));
    expect(metadata.salesCount, 1234);
    expect(metadata.rating, 4.5);
  });

  test('searchByTitleCandidates scores ASMR.ONE title matches', () async {
    final service = AsmrMetadataService(
      apiService: _FakeAsmrApiService(
        works: [
          _work(sourceId: 'RJ000001', title: 'Other'),
          _work(sourceId: 'RJ123456', title: 'Sleep ASMR'),
        ],
      ),
    );

    final results = await service.searchByTitleCandidates(['Sleep ASMR']);

    expect(results, hasLength(1));
    expect(results.single.rjCode, 'RJ123456');
  });
}

class _FakeAsmrApiService extends AsmrApiService {
  _FakeAsmrApiService({required this.works});

  final List<AsmrWork> works;

  @override
  Future<AsmrWorkPage> searchWorks({
    required String keyword,
    required String order,
    required String sort,
    int page = 1,
    int pageSize = 40,
    String? token,
    AsmrContentLanguage language = AsmrContentLanguage.zh,
  }) async {
    return AsmrWorkPage(
      works: works,
      totalCount: works.length,
      currentPage: page,
      pageSize: pageSize,
    );
  }
}

AsmrWork _work({
  required String sourceId,
  required String title,
  DateTime? releaseDate,
  int dlCount = 0,
  double rating = 0,
}) {
  return AsmrWork(
    id: sourceId.hashCode,
    title: title,
    circleName: 'Circle',
    sourceId: sourceId,
    sourceType: 'asmr',
    sourceUrl: '',
    coverUrl: 'https://example.com/cover.jpg',
    thumbnailUrl: '',
    mainCoverUrl: '',
    releaseDate: releaseDate,
    createDate: null,
    duration: Duration.zero,
    dlCount: dlCount,
    reviewCount: 0,
    rating: rating,
    voiceActors: const <String>['Voice'],
    tags: const <String>['ASMR'],
  );
}
