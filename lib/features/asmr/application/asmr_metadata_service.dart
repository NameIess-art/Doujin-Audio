import '../../../core/app_language.dart';
import '../domain/asmr_models.dart';
import '../../../core/media/audio_detail.dart';
import '../../../core/media/dlsite_metadata.dart';
import 'asmr_api_service.dart';
import '../../library/application/dlsite_metadata_service.dart';

class AsmrMetadataService {
  AsmrMetadataService({AsmrApiService? apiService})
    : _apiService = apiService ?? AsmrApiService();

  final AsmrApiService _apiService;

  Future<DlsiteMetadata> fetchByRjCode(
    String rjCode, {
    AppLanguage language = AppLanguage.zh,
  }) async {
    final normalizedRjCode = AudioDetail.findRjCodeInText(rjCode);
    if (normalizedRjCode == null) {
      throw const DlsiteMetadataException('Invalid RJ code');
    }
    final page = await _apiService.searchWorks(
      keyword: normalizedRjCode,
      order: 'release',
      sort: 'desc',
      pageSize: 20,
      language: _asmrLanguage(language),
    );
    final exact = page.works.where(
      (work) => work.rjCode.toUpperCase() == normalizedRjCode,
    );
    if (exact.isEmpty) {
      throw const DlsiteMetadataException('No ASMR.ONE metadata found');
    }
    return _metadataFromWork(exact.first);
  }

  Future<List<DlsiteMetadata>> searchByTitleCandidates(
    Iterable<String> titles, {
    AppLanguage language = AppLanguage.zh,
  }) async {
    final seen = <String>{};
    final resultsByRjCode = <String, _ScoredAsmrMetadata>{};
    final normalizedTitles = titles
        .map((title) => title.trim())
        .where((title) => title.isNotEmpty && seen.add(title))
        .toList(growable: false);

    for (final title in normalizedTitles) {
      final page = await _apiService.searchWorks(
        keyword: title,
        order: 'release',
        sort: 'desc',
        pageSize: 20,
        language: _asmrLanguage(language),
      );
      final keywords = extractDlsiteTitleKeywords(title);
      for (final work in page.works) {
        final metadata = _metadataFromWork(work);
        final score = _scoreTitleMatch(metadata.workTitle, keywords);
        if (score <= 0) continue;
        final key = metadata.rjCode.trim().isNotEmpty
            ? metadata.rjCode
            : metadata.workTitle;
        final existing = resultsByRjCode[key];
        if (existing == null || existing.score < score) {
          resultsByRjCode[key] = _ScoredAsmrMetadata(metadata, score);
        }
      }
    }

    final results = resultsByRjCode.values.toList(growable: false)
      ..sort((a, b) => b.score.compareTo(a.score));
    if (results.isEmpty) {
      throw const DlsiteMetadataException('No ASMR.ONE metadata found');
    }
    return results.map((item) => item.metadata).toList(growable: false);
  }

  DlsiteMetadata _metadataFromWork(AsmrWork work) {
    return DlsiteMetadata(
      rjCode: work.rjCode.toUpperCase(),
      workTitle: work.title,
      circleName: work.circleName,
      voiceActors: AudioDetail.normalizeList(work.voiceActors),
      tags: AudioDetail.normalizeList(work.tags),
      releaseDate: work.releaseDate,
      duration: work.duration > Duration.zero ? work.duration : null,
      salesCount: work.dlCount > 0 ? work.dlCount : null,
      rating: work.rating > 0 ? work.rating.clamp(0, 5).toDouble() : null,
      coverUrl: _coverUrlFor(work),
    );
  }

  String? _coverUrlFor(AsmrWork work) {
    final candidates = <String>[
      work.mainCoverUrl,
      work.coverUrl,
      work.thumbnailUrl,
    ];
    for (final candidate in candidates) {
      final value = candidate.trim();
      if (value.isNotEmpty) return value;
    }
    return null;
  }

  AsmrContentLanguage _asmrLanguage(AppLanguage language) {
    return AsmrContentLanguage.fromAppLanguageName(language.name);
  }

  int _scoreTitleMatch(String title, Iterable<String> keywords) {
    final normalizedTitle = title.toLowerCase();
    var score = 0;
    for (final keyword in keywords.toSet()) {
      if (normalizedTitle.contains(keyword.toLowerCase())) score++;
    }
    return score;
  }
}

class _ScoredAsmrMetadata {
  const _ScoredAsmrMetadata(this.metadata, this.score);

  final DlsiteMetadata metadata;
  final int score;
}
