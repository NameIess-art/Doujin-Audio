import 'audio_detail.dart';

class DlsiteMetadata {
  const DlsiteMetadata({
    required this.rjCode,
    required this.workTitle,
    required this.circleName,
    required this.voiceActors,
    required this.tags,
    this.coverUrl,
  });

  factory DlsiteMetadata.fromProductJson(Map<String, dynamic> json) {
    final rjCode =
        _stringValue(json['workno']) ?? _stringValue(json['product_id']);
    final title =
        _stringValue(json['work_name']) ??
        _stringValue(json['product_name']) ??
        _stringValue(json['alt_name']);
    final circleName =
        _stringValue(json['maker_name']) ?? _stringValue(json['maker_name_en']);

    return DlsiteMetadata(
      rjCode: (rjCode ?? '').toUpperCase(),
      workTitle: title ?? '',
      circleName: circleName ?? '',
      voiceActors: _creatorNames(json, 'voice_by'),
      tags: _genreNames(json),
      coverUrl: _normalizeUrl(_nestedString(json['image_main'], 'url')),
    );
  }

  final String rjCode;
  final String workTitle;
  final String circleName;
  final List<String> voiceActors;
  final List<String> tags;
  final String? coverUrl;

  DlsiteMetadata copyWith({
    String? rjCode,
    String? workTitle,
    String? circleName,
    List<String>? voiceActors,
    List<String>? tags,
    String? coverUrl,
  }) {
    return DlsiteMetadata(
      rjCode: rjCode ?? this.rjCode,
      workTitle: workTitle ?? this.workTitle,
      circleName: circleName ?? this.circleName,
      voiceActors: voiceActors ?? this.voiceActors,
      tags: tags ?? this.tags,
      coverUrl: coverUrl ?? this.coverUrl,
    );
  }
}

String? _stringValue(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

String? _nestedString(Object? object, String key) {
  if (object is! Map) return null;
  return _stringValue(object[key]);
}

List<String> _creatorNames(Map<String, dynamic> json, String key) {
  final creators = json['creaters'] ?? json['creators'];
  if (creators is! Map) return const <String>[];
  final rawList = creators[key];
  if (rawList is! List) return const <String>[];
  return _uniqueStrings(
    rawList
        .whereType<Map>()
        .map((item) => _stringValue(item['name']))
        .whereType<String>(),
  );
}

List<String> _genreNames(Map<String, dynamic> json) {
  final rawGenres = json['genres_replaced'] ?? json['genres'];
  if (rawGenres is! List) return const <String>[];
  return _uniqueStrings(
    rawGenres
        .whereType<Map>()
        .map((item) => _stringValue(item['name']))
        .whereType<String>(),
  );
}

List<String> _uniqueStrings(Iterable<String> values) {
  final seen = <String>{};
  final result = <String>[];
  for (final value in values) {
    if (seen.add(value)) result.add(value);
  }
  return List<String>.unmodifiable(result);
}

String? _normalizeUrl(String? rawUrl) {
  if (rawUrl == null) return null;
  if (rawUrl.startsWith('//')) return 'https:$rawUrl';
  if (rawUrl.startsWith('/')) return 'https://www.dlsite.com$rawUrl';
  return rawUrl;
}

class DlsiteMetadataApplyResult {
  const DlsiteMetadataApplyResult({
    required this.detail,
    this.coverPath,
    this.coverError,
  });

  final AudioDetail detail;
  final String? coverPath;
  final Object? coverError;

  bool get coverFailed => coverError != null;
}
