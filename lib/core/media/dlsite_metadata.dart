import '../immutable_collections.dart';
import 'audio_detail.dart';

class DlsiteMetadata {
  DlsiteMetadata({
    required this.rjCode,
    required this.workTitle,
    required this.circleName,
    required List<String> voiceActors,
    required List<String> tags,
    this.releaseDate,
    this.duration,
    this.salesCount,
    this.rating,
    this.coverUrl,
  }) : voiceActors = immutableList(voiceActors),
       tags = immutableList(tags);

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
      releaseDate:
          _dateValue(json['regist_date']) ?? _dateValue(json['release_date']),
      duration: _durationValue(json),
      salesCount:
          _intValue(json['dl_count']) ??
          _intValue(json['sales']) ??
          _intValue(json['sales_count']),
      rating: _ratingValue(
        json['rate_average_2dp'] ??
            json['rate_average'] ??
            json['rate_average_star'],
      ),
      coverUrl: _normalizeUrl(_nestedString(json['image_main'], 'url')),
    );
  }

  final String rjCode;
  final String workTitle;
  final String circleName;
  final List<String> voiceActors;
  final List<String> tags;
  final DateTime? releaseDate;
  final Duration? duration;
  final int? salesCount;
  final double? rating;
  final String? coverUrl;

  DlsiteMetadata copyWith({
    String? rjCode,
    String? workTitle,
    String? circleName,
    List<String>? voiceActors,
    List<String>? tags,
    Object? releaseDate = _copyUnset,
    Object? duration = _copyUnset,
    Object? salesCount = _copyUnset,
    Object? rating = _copyUnset,
    String? coverUrl,
  }) {
    return DlsiteMetadata(
      rjCode: rjCode ?? this.rjCode,
      workTitle: workTitle ?? this.workTitle,
      circleName: circleName ?? this.circleName,
      voiceActors: voiceActors ?? this.voiceActors,
      tags: tags ?? this.tags,
      releaseDate: releaseDate == _copyUnset
          ? this.releaseDate
          : releaseDate as DateTime?,
      duration: duration == _copyUnset ? this.duration : duration as Duration?,
      salesCount: salesCount == _copyUnset
          ? this.salesCount
          : salesCount as int?,
      rating: rating == _copyUnset ? this.rating : rating as double?,
      coverUrl: coverUrl ?? this.coverUrl,
    );
  }
}

const Object _copyUnset = Object();

String? _stringValue(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

String? _nestedString(Object? object, String key) {
  if (object is! Map) return null;
  return _stringValue(object[key]);
}

DateTime? _dateValue(Object? value) {
  final raw = _stringValue(value);
  if (raw == null) return null;
  return DateTime.tryParse(raw.replaceAll('/', '-'));
}

int? _intValue(Object? value) {
  if (value is num) return value.toInt();
  final raw = _stringValue(value);
  if (raw == null) return null;
  final digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
  return digits.isEmpty ? null : int.tryParse(digits);
}

Duration? _durationValue(Map<String, dynamic> json) {
  final durationMs = _intValue(json['duration_ms'] ?? json['durationMs']);
  if (durationMs != null && durationMs > 0) {
    return Duration(milliseconds: durationMs);
  }
  final raw = json['duration'];
  if (raw is String && raw.contains(':')) {
    final parts = raw.split(':').map(int.tryParse).toList(growable: false);
    if (parts.length >= 2 &&
        parts.length <= 3 &&
        parts.every((v) => v != null)) {
      final values = parts.cast<int>();
      final seconds = values.reversed
          .toList(growable: false)
          .asMap()
          .entries
          .fold<int>(
            0,
            (sum, entry) =>
                sum +
                entry.value *
                    (entry.key == 0
                        ? 1
                        : entry.key == 1
                        ? 60
                        : 3600),
          );
      return seconds > 0 ? Duration(seconds: seconds) : null;
    }
  }
  final seconds = raw is num
      ? raw.round()
      : raw is String
      ? double.tryParse(raw.trim())?.round()
      : null;
  return seconds != null && seconds > 0 ? Duration(seconds: seconds) : null;
}

double? _ratingValue(Object? value) {
  if (value == null) return null;
  final raw = value is num
      ? value.toDouble()
      : double.tryParse(value.toString());
  if (raw == null || raw <= 0) return null;
  final normalized = raw > 5 ? raw / 10 : raw;
  return normalized.clamp(0, 5).toDouble();
}

List<String> _creatorNames(Map<String, dynamic> json, String key) {
  final creators = json['creaters'] ?? json['creators'];
  if (creators is! Map<Object?, Object?>) return const <String>[];
  final rawList = creators[key];
  if (rawList is! List<Object?>) return const <String>[];
  return _uniqueStrings(
    rawList
        .whereType<Map<Object?, Object?>>()
        .map((item) => _stringValue(item['name']))
        .whereType<String>(),
  );
}

List<String> _genreNames(Map<String, dynamic> json) {
  final rawGenres = json['genres_replaced'] ?? json['genres'];
  if (rawGenres is! List<Object?>) return const <String>[];
  return _uniqueStrings(
    rawGenres
        .whereType<Map<Object?, Object?>>()
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
