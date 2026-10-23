/// A transport address and optional chapter range. The original URL remains the
/// logical identity, because several chapters can share a single HLS stream.
class PlaybackMediaReference {
  const PlaybackMediaReference({
    required this.streamUrl,
    this.startMs = 0,
    this.endMs,
    this.downloadUrl,
    this.fileName,
    this.httpHeaders = const {},
  });

  final String streamUrl;
  final int startMs;
  final int? endMs;
  final String? downloadUrl;
  final String? fileName;
  final Map<String, String> httpHeaders;

  bool get isChapter => startMs > 0 || endMs != null;
  bool get isHls =>
      Uri.tryParse(streamUrl)?.path.toLowerCase().endsWith('.m3u8') == true;
  int? get durationMs => endMs == null ? null : endMs! - startMs;

  String get logicalUrl {
    if (!isChapter && downloadUrl == null && fileName == null) return streamUrl;
    return Uri.parse(streamUrl)
        .replace(
          fragment: Uri(
            queryParameters: {
              'eara-chapter': '$startMs,${endMs ?? ''}',
              'file': ?fileName,
              'download': ?downloadUrl,
            },
          ).query,
        )
        .toString();
  }

  factory PlaybackMediaReference.parse(String url) {
    final uri = Uri.parse(url);
    final values = uri.fragment.startsWith('eara-chapter=')
        ? Uri.splitQueryString(uri.fragment)
        : const <String, String>{};
    final range = values['eara-chapter']?.split(',');
    final start = range == null ? 0 : int.tryParse(range.first);
    final end = range == null || range.length < 2 || range[1].isEmpty
        ? null
        : int.tryParse(range[1]);
    if (start == null ||
        start < 0 ||
        (range != null &&
            (range.length != 2 || (range[1].isNotEmpty && end == null))) ||
        (end != null && end <= start)) {
      throw const FormatException('Invalid chapter range');
    }
    final streamUrl = values.isEmpty ? url : uri.removeFragment().toString();
    return PlaybackMediaReference(
      streamUrl: streamUrl,
      startMs: start,
      endMs: end,
      downloadUrl: values['download']?.isEmpty == false
          ? values['download']
          : null,
      fileName: values['file'],
      httpHeaders: requestHeadersForUri(Uri.parse(streamUrl)),
    );
  }

  factory PlaybackMediaReference.fromJson(Map<String, dynamic> json) =>
      PlaybackMediaReference(
        streamUrl: json['streamUrl'] as String,
        startMs: (json['startMs'] as num?)?.toInt() ?? 0,
        endMs: (json['endMs'] as num?)?.toInt(),
        downloadUrl: json['downloadUrl'] as String?,
        fileName: json['fileName'] as String?,
        httpHeaders:
            (json['httpHeaders'] as Map?)?.cast<String, String>() ?? const {},
      );

  Map<String, dynamic> toJson() => {
    'streamUrl': streamUrl,
    'startMs': startMs,
    if (endMs != null) 'endMs': endMs,
    if (downloadUrl != null) 'downloadUrl': downloadUrl,
    if (fileName != null) 'fileName': fileName,
    if (httpHeaders.isNotEmpty) 'httpHeaders': httpHeaders,
  };

  /// Per-resource headers must never become default headers for other sources.
  static Map<String, String> requestHeadersForUri(Uri uri) {
    final host = uri.host.toLowerCase();
    if (host == 'japaneseasmr.com' ||
        host.endsWith('.japaneseasmr.com') ||
        host == 'v.weeab0o.xyz' ||
        host == 'pic.weeabo0.xyz') {
      return const {'Referer': 'https://japaneseasmr.com/'};
    }
    return const {};
  }
}
