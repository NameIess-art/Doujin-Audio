import 'dart:convert';
import 'dart:io';

class RemoteSourceHeaderRule {
  RemoteSourceHeaderRule({
    required this.id,
    required Uri baseUri,
    required Map<String, String> headers,
  }) : scheme = baseUri.scheme.toLowerCase(),
       host = baseUri.host.toLowerCase(),
       port = _effectivePort(baseUri),
       pathPrefix = _normalizePathPrefix(baseUri.path),
       headers = Map<String, String>.unmodifiable(headers);

  factory RemoteSourceHeaderRule.basicAuth({
    required String id,
    required Uri baseUri,
    required String username,
    required String password,
  }) {
    final encoded = base64.encode(utf8.encode('$username:$password'));
    return RemoteSourceHeaderRule(
      id: id,
      baseUri: baseUri,
      headers: <String, String>{
        HttpHeaders.authorizationHeader: 'Basic $encoded',
      },
    );
  }

  factory RemoteSourceHeaderRule.bearerToken({
    required String id,
    required Uri baseUri,
    required String token,
  }) {
    return RemoteSourceHeaderRule(
      id: id,
      baseUri: baseUri,
      headers: <String, String>{
        HttpHeaders.authorizationHeader: 'Bearer $token',
      },
    );
  }

  final String id;
  final String scheme;
  final String host;
  final int port;
  final String pathPrefix;
  final Map<String, String> headers;

  bool matches(Uri uri) {
    final uriScheme = uri.scheme.toLowerCase();
    if (uriScheme != scheme || uri.host.toLowerCase() != host) return false;
    if (_effectivePort(uri) != port) return false;
    if (pathPrefix == '/') return true;
    final candidatePath = _normalizeCandidatePath(uri.path);
    return candidatePath == pathPrefix ||
        candidatePath.startsWith('$pathPrefix/');
  }

  static int _effectivePort(Uri uri) {
    if (uri.hasPort) return uri.port;
    return switch (uri.scheme.toLowerCase()) {
      'https' => 443,
      'http' => 80,
      _ => 0,
    };
  }

  static String _normalizePathPrefix(String rawPath) {
    var normalized = _decodeSegmentsPath(rawPath);
    while (normalized.length > 1 && normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized.isEmpty ? '/' : normalized;
  }

  static String _normalizeCandidatePath(String rawPath) {
    final normalized = _decodeSegmentsPath(rawPath);
    return normalized.isEmpty ? '/' : normalized;
  }

  static String _decodeSegmentsPath(String rawPath) {
    if (rawPath.isEmpty || rawPath == '/') return '/';
    final segments = rawPath
        .split('/')
        .where((s) => s.isNotEmpty)
        .map((segment) {
          try {
            return Uri.decodeComponent(segment);
          } on ArgumentError {
            return segment;
          }
        })
        .toList(growable: false);
    if (segments.isEmpty) return '/';
    return '/${segments.join('/')}';
  }
}

/// Scopes remote source credentials to exact origin + base-path prefixes in RAM
/// so secrets never enter persisted playback URLs, SQLite rows, or logs.
class RemoteSourceHeaderRegistry {
  RemoteSourceHeaderRegistry();

  static final RemoteSourceHeaderRegistry instance =
      RemoteSourceHeaderRegistry();

  final Map<String, RemoteSourceHeaderRule> _rulesById =
      <String, RemoteSourceHeaderRule>{};
  int _revision = 0;

  int get revision => _revision;

  void upsertRule(RemoteSourceHeaderRule rule) {
    if (rule.headers.isEmpty || rule.host.isEmpty) {
      if (_rulesById.remove(rule.id) != null) _revision++;
      return;
    }
    _rulesById[rule.id] = rule;
    _revision++;
  }

  void removeRule(String id) {
    if (_rulesById.remove(id) != null) _revision++;
  }

  void replaceAll(Iterable<RemoteSourceHeaderRule> rules) {
    _rulesById.clear();
    for (final rule in rules) {
      if (rule.headers.isNotEmpty && rule.host.isNotEmpty) {
        _rulesById[rule.id] = rule;
      }
    }
    _revision++;
  }

  void clear() {
    if (_rulesById.isEmpty) return;
    _rulesById.clear();
    _revision++;
  }

  Map<String, String> headersForUri(Uri uri, {String? sourceId}) {
    if (sourceId != null) {
      final rule = _rulesById[sourceId];
      return rule != null && rule.matches(uri)
          ? rule.headers
          : const <String, String>{};
    }
    if (_rulesById.isEmpty) return const <String, String>{};
    RemoteSourceHeaderRule? bestMatch;
    for (final rule in _rulesById.values) {
      if (!rule.matches(uri)) continue;
      if (bestMatch == null ||
          rule.pathPrefix.length > bestMatch.pathPrefix.length) {
        bestMatch = rule;
      }
    }
    return bestMatch?.headers ?? const <String, String>{};
  }
}
