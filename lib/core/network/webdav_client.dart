import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class WebDavException implements Exception {
  const WebDavException(this.message, {this.statusCode, this.uri});

  final String message;
  final int? statusCode;
  final Uri? uri;

  bool get isUnauthorized =>
      statusCode == HttpStatus.unauthorized ||
      statusCode == HttpStatus.forbidden;

  bool get isNotFound => statusCode == HttpStatus.notFound;

  @override
  String toString() => statusCode == null
      ? 'WebDavException($message)'
      : 'WebDavException(HTTP $statusCode: $message)';
}

class WebDavEntry {
  const WebDavEntry({
    required this.uri,
    required this.name,
    required this.isDirectory,
    this.contentLength,
    this.lastModified,
    this.etag,
    this.contentType,
  });

  final Uri uri;
  final String name;
  final bool isDirectory;
  final int? contentLength;
  final DateTime? lastModified;
  final String? etag;
  final String? contentType;
}

/// Lightweight RFC 4918 WebDAV client shared by remote library browsing and
/// cross-platform sync without external XML or native dependencies.
class WebDavClient {
  WebDavClient({
    required Uri baseUri,
    String? username,
    String? password,
    Map<String, String> extraHeaders = const <String, String>{},
    HttpClient Function()? httpClientFactory,
    Duration requestTimeout = const Duration(seconds: 20),
  }) : baseUri = normalizeDirectoryUri(baseUri),
       _authHeader = _encodeBasicAuth(username, password),
       _extraHeaders = Map<String, String>.unmodifiable(extraHeaders),
       _httpClientFactory = httpClientFactory ?? HttpClient.new,
       _requestTimeout = requestTimeout;

  final Uri baseUri;
  final String? _authHeader;
  final Map<String, String> _extraHeaders;
  final HttpClient Function() _httpClientFactory;
  final Duration _requestTimeout;
  HttpClient? _client;
  bool _closed = false;

  static const String _propfindBody =
      '<?xml version="1.0" encoding="utf-8"?>'
      '<d:propfind xmlns:d="DAV:">'
      '<d:prop>'
      '<d:displayname/>'
      '<d:resourcetype/>'
      '<d:getcontentlength/>'
      '<d:getlastmodified/>'
      '<d:getetag/>'
      '<d:getcontenttype/>'
      '</d:prop>'
      '</d:propfind>';

  Map<String, String> get authHeaders => <String, String>{
    ..._extraHeaders,
    if (_authHeader != null) HttpHeaders.authorizationHeader: _authHeader,
  };

  static Uri normalizeDirectoryUri(Uri uri) {
    final path = uri.path.isEmpty
        ? '/'
        : (uri.path.endsWith('/') ? uri.path : '${uri.path}/');
    return uri.replace(path: path);
  }

  Uri resolveRelativePath(String relativePath, {bool isDirectory = false}) {
    final segments = relativePath
        .replaceAll('\\', '/')
        .split('/')
        .where((s) => s.isNotEmpty && s != '.')
        .toList(growable: false);
    if (segments.any((s) => s == '..')) {
      throw ArgumentError.value(relativePath, 'relativePath', 'Invalid ..');
    }
    final baseSegments = baseUri.pathSegments
        .where((s) => s.isNotEmpty)
        .toList(growable: true);
    baseSegments.addAll(segments);
    final encodedPath = baseSegments.isEmpty
        ? '/'
        : '/${baseSegments.map(Uri.encodeComponent).join('/')}${isDirectory ? '/' : ''}';
    return baseUri.replace(path: encodedPath);
  }

  Future<void> testConnection() async {
    final entries = await listDirectory(
      baseUri,
      depth: 0,
      includeSelf: true,
    );
    if (entries.isEmpty) {
      throw WebDavException('Empty PROPFIND response', uri: baseUri);
    }
  }

  Future<List<WebDavEntry>> listDirectory(
    Uri directoryUri, {
    int depth = 1,
    bool includeSelf = false,
    int maxResponseBytes = 16 * 1024 * 1024,
  }) async {
    assert(depth == 0 || depth == 1);
    final target = normalizeDirectoryUri(directoryUri);
    final request = await _openRequest('PROPFIND', target);
    request.headers.set('Depth', '$depth');
    request.headers.set(
      HttpHeaders.contentTypeHeader,
      'application/xml; charset=utf-8',
    );
    final bodyBytes = utf8.encode(_propfindBody);
    request.contentLength = bodyBytes.length;
    request.add(bodyBytes);
    final response = await request.close().timeout(_requestTimeout);
    if (response.statusCode != 207 &&
        (response.statusCode < 200 || response.statusCode >= 300)) {
      await response.listen(null).cancel();
      throw WebDavException(
        'PROPFIND failed',
        statusCode: response.statusCode,
        uri: target,
      );
    }
    final rawXml = utf8.decode(
      await _readLimitedBytes(response, maxBytes: maxResponseBytes),
      allowMalformed: true,
    );
    return parseWebDavMultistatus(
      rawXml,
      requestUri: target,
      includeSelf: includeSelf,
    );
  }

  Future<void> ensureDirectory(Uri directoryUri) async {
    final target = normalizeDirectoryUri(directoryUri);
    final baseSegments = baseUri.pathSegments
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
    final targetSegments = target.pathSegments
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
    if (targetSegments.length < baseSegments.length) return;

    for (var len = baseSegments.length; len <= targetSegments.length; len++) {
      final currentPath = len == 0
          ? '/'
          : '/${targetSegments.take(len).map(Uri.encodeComponent).join('/')}/';
      final currentUri = baseUri.replace(path: currentPath);
      if (len == baseSegments.length) continue;
      final exists = await _exists(currentUri);
      if (exists) continue;
      final request = await _openRequest('MKCOL', currentUri);
      request.contentLength = 0;
      final response = await request.close().timeout(_requestTimeout);
      await response.listen(null).cancel();
      // 201 Created or 405 Method Not Allowed (already created concurrently).
      if (response.statusCode != HttpStatus.created &&
          response.statusCode != HttpStatus.methodNotAllowed &&
          (response.statusCode < 200 || response.statusCode >= 300)) {
        throw WebDavException(
          'MKCOL failed',
          statusCode: response.statusCode,
          uri: currentUri,
        );
      }
    }
  }

  Future<Uint8List> getBytes(
    Uri fileUri, {
    int maxBytes = 64 * 1024 * 1024,
  }) async {
    final request = await _openRequest('GET', fileUri);
    final response = await request.close().timeout(_requestTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await response.listen(null).cancel();
      throw WebDavException(
        'GET failed',
        statusCode: response.statusCode,
        uri: fileUri,
      );
    }
    return _readLimitedBytes(response, maxBytes: maxBytes);
  }

  Future<Uint8List?> getBytesOrNull(
    Uri fileUri, {
    int maxBytes = 4 * 1024 * 1024,
  }) async {
    final request = await _openRequest('GET', fileUri);
    final response = await request.close().timeout(_requestTimeout);
    if (response.statusCode == HttpStatus.notFound) {
      await response.listen(null).cancel();
      return null;
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await response.listen(null).cancel();
      throw WebDavException(
        'GET failed',
        statusCode: response.statusCode,
        uri: fileUri,
      );
    }
    return _readLimitedBytes(response, maxBytes: maxBytes);
  }

  Future<void> moveUri({
    required Uri sourceUri,
    required Uri destinationUri,
    bool overwrite = false,
  }) async {
    final request = await _openRequest('MOVE', sourceUri);
    request.headers.set('Destination', destinationUri.toString());
    request.headers.set('Overwrite', overwrite ? 'T' : 'F');
    request.contentLength = 0;
    final response = await request.close().timeout(_requestTimeout);
    await response.listen(null).cancel();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw WebDavException(
        'MOVE failed',
        statusCode: response.statusCode,
        uri: sourceUri,
      );
    }
  }

  Future<void> putBytesAtomic(Uri fileUri, Uint8List bytes) async {
    final tempUri = fileUri.replace(path: '${fileUri.path}.tmp');
    await _putRaw(tempUri, bytes);
    final moveRequest = await _openRequest('MOVE', tempUri);
    moveRequest.headers.set('Destination', fileUri.toString());
    moveRequest.headers.set('Overwrite', 'T');
    moveRequest.contentLength = 0;
    final moveResponse = await moveRequest.close().timeout(_requestTimeout);
    await moveResponse.listen(null).cancel();
    if (moveResponse.statusCode >= 200 && moveResponse.statusCode < 300) {
      return;
    }
    // Some minimalist WebDAV backends disable MOVE; fall back to direct PUT and
    // best-effort cleanup of the staged file.
    await _deleteIgnoreNotFound(tempUri);
    await _putRaw(fileUri, bytes);
  }

  Future<void> delete(Uri resourceUri) async {
    final request = await _openRequest('DELETE', resourceUri);
    request.contentLength = 0;
    final response = await request.close().timeout(_requestTimeout);
    await response.listen(null).cancel();
    if (response.statusCode != HttpStatus.notFound &&
        (response.statusCode < 200 || response.statusCode >= 300)) {
      throw WebDavException(
        'DELETE failed',
        statusCode: response.statusCode,
        uri: resourceUri,
      );
    }
  }

  void close({bool force = false}) {
    if (_closed) return;
    _closed = true;
    _client?.close(force: force);
    _client = null;
  }

  Future<bool> _exists(Uri uri) async {
    final request = await _openRequest('PROPFIND', uri);
    request.headers.set('Depth', '0');
    request.contentLength = 0;
    final response = await request.close().timeout(_requestTimeout);
    await response.listen(null).cancel();
    if (response.statusCode == 207 ||
        (response.statusCode >= 200 && response.statusCode < 300)) {
      return true;
    }
    if (response.statusCode == HttpStatus.notFound) return false;
    throw WebDavException(
      'Existence check failed',
      statusCode: response.statusCode,
      uri: uri,
    );
  }

  Future<void> _putRaw(Uri uri, Uint8List bytes) async {
    final request = await _openRequest('PUT', uri);
    request.headers.set(
      HttpHeaders.contentTypeHeader,
      'application/octet-stream',
    );
    request.contentLength = bytes.length;
    request.add(bytes);
    final response = await request.close().timeout(_requestTimeout);
    await response.listen(null).cancel();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw WebDavException(
        'PUT failed',
        statusCode: response.statusCode,
        uri: uri,
      );
    }
  }

  Future<void> _deleteIgnoreNotFound(Uri uri) async {
    try {
      await delete(uri);
    } on Object {
      // Best-effort cleanup of temporary upload artifact.
    }
  }

  Future<HttpClientRequest> _openRequest(String method, Uri uri) async {
    if (_closed) throw StateError('WebDavClient is closed');
    final client = _client ??= (_httpClientFactory()
      ..connectionTimeout = _requestTimeout);
    final request = await client
        .openUrl(method, uri)
        .timeout(_requestTimeout);
    request.followRedirects = true;
    for (final entry in _extraHeaders.entries) {
      request.headers.set(entry.key, entry.value);
    }
    if (_authHeader != null) {
      request.headers.set(HttpHeaders.authorizationHeader, _authHeader);
    }
    return request;
  }

  Future<Uint8List> _readLimitedBytes(
    HttpClientResponse response, {
    required int maxBytes,
  }) async {
    if (response.contentLength > maxBytes) {
      await response.listen(null).cancel();
      throw WebDavException('Response exceeds $maxBytes bytes');
    }
    final builder = BytesBuilder(copy: false);
    var total = 0;
    await for (final chunk in response.timeout(_requestTimeout)) {
      total += chunk.length;
      if (total > maxBytes) {
        throw WebDavException('Response exceeds $maxBytes bytes');
      }
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  static String? _encodeBasicAuth(String? username, String? password) {
    final user = username?.trim() ?? '';
    if (user.isEmpty && (password == null || password.isEmpty)) return null;
    return 'Basic ${base64.encode(utf8.encode('$user:${password ?? ''}'))}';
  }
}

final RegExp _responseElementPattern = RegExp(
  r'<(?:[A-Za-z0-9_.-]+:)?response(?:\s[^>]*)?>(.*?)</(?:[A-Za-z0-9_.-]+:)?response>',
  caseSensitive: false,
  dotAll: true,
);

final RegExp _propstatElementPattern = RegExp(
  r'<(?:[A-Za-z0-9_.-]+:)?propstat(?:\s[^>]*)?>(.*?)</(?:[A-Za-z0-9_.-]+:)?propstat>',
  caseSensitive: false,
  dotAll: true,
);

final RegExp _collectionTagPattern = RegExp(
  r'<(?:[A-Za-z0-9_.-]+:)?collection(?:\s[^>]*)?/?>',
  caseSensitive: false,
);

final RegExp _httpStatusPattern = RegExp(r'HTTP/\d+(?:\.\d+)?\s+(\d{3})');

/// Parses RFC 4918 `<multistatus>` XML across diverse server namespace styles.
List<WebDavEntry> parseWebDavMultistatus(
  String xml, {
  required Uri requestUri,
  bool includeSelf = false,
}) {
  final normalizedSelfPath = _canonicalDecodedPath(requestUri.path);
  final entries = <WebDavEntry>[];
  for (final match in _responseElementPattern.allMatches(xml)) {
    final responseBody = match.group(1)!;
    final rawHref = _extractFirstTagText(responseBody, 'href')?.trim();
    if (rawHref == null || rawHref.isEmpty) continue;

    String? propXml;
    for (final propstatMatch in _propstatElementPattern.allMatches(
      responseBody,
    )) {
      final block = propstatMatch.group(1)!;
      final statusText = _extractFirstTagText(block, 'status') ?? '';
      final statusCode = int.tryParse(
        _httpStatusPattern.firstMatch(statusText)?.group(1) ?? '',
      );
      if (statusCode == null || (statusCode >= 200 && statusCode < 300)) {
        propXml = _extractFirstTagInnerXml(block, 'prop') ?? block;
        break;
      }
    }
    propXml ??= _extractFirstTagInnerXml(responseBody, 'prop') ?? responseBody;

    final resourceTypeXml =
        _extractFirstTagInnerXml(propXml, 'resourcetype') ?? '';
    final isCollection =
        _collectionTagPattern.hasMatch(resourceTypeXml) ||
        rawHref.endsWith('/');
    final resolvedUri = _resolveHref(requestUri, rawHref, isCollection);
    final candidatePath = _canonicalDecodedPath(resolvedUri.path);
    if (!includeSelf && candidatePath == normalizedSelfPath) {
      continue;
    }

    final decodedSegments = resolvedUri.path
        .split('/')
        .where((s) => s.isNotEmpty)
        .map(_safeDecodeUriSegment)
        .toList(growable: false);
    final fallbackName = decodedSegments.isEmpty ? '' : decodedSegments.last;
    final displayName = _extractFirstTagText(propXml, 'displayname')?.trim();
    final name = fallbackName.isNotEmpty
        ? fallbackName
        : (displayName ?? '');
    if (name.isEmpty && !includeSelf) continue;

    final rawLength = _extractFirstTagText(propXml, 'getcontentlength')?.trim();
    final rawModified =
        _extractFirstTagText(propXml, 'getlastmodified')?.trim();
    final rawEtag = _extractFirstTagText(propXml, 'getetag')?.trim();
    final rawContentType =
        _extractFirstTagText(propXml, 'getcontenttype')?.trim();

    entries.add(
      WebDavEntry(
        uri: resolvedUri,
        name: name,
        isDirectory: isCollection,
        contentLength: rawLength == null ? null : int.tryParse(rawLength),
        lastModified: rawModified == null ? null : _parseWebDavDate(rawModified),
        etag: rawEtag?.isEmpty == true ? null : rawEtag,
        contentType: rawContentType?.isEmpty == true ? null : rawContentType,
      ),
    );
  }
  return entries;
}

Uri _resolveHref(Uri requestUri, String rawHref, bool isDirectory) {
  final unescaped = _unescapeXmlText(rawHref).trim();
  Uri resolved;
  final hasHttpScheme =
      unescaped.startsWith('http://') || unescaped.startsWith('https://');
  if (hasHttpScheme) {
    final schemeEnd = unescaped.indexOf('://') + 3;
    final pathStart = unescaped.indexOf('/', schemeEnd);
    final normalizedInput = pathStart < 0
        ? unescaped
        : '${unescaped.substring(0, pathStart)}${_encodeHrefPath(unescaped.substring(pathStart))}';
    resolved = Uri.parse(normalizedInput);
  } else {
    final encodedHref = _encodeHrefPath(unescaped);
    try {
      resolved = requestUri.resolve(encodedHref);
    } on FormatException {
      resolved = requestUri.resolve(unescaped);
    }
  }
  final canonicalPath = _encodeHrefPath(resolved.path);
  final normalizedPath =
      isDirectory && !canonicalPath.endsWith('/')
      ? '$canonicalPath/'
      : canonicalPath;
  return resolved.replace(
    scheme: requestUri.scheme,
    host: requestUri.host,
    port: requestUri.hasPort ? requestUri.port : null,
    path: normalizedPath,
  );
}

String _encodeHrefPath(String rawPath) {
  if (rawPath.isEmpty) return '';
  final leadingSlash = rawPath.startsWith('/');
  final trailingSlash = rawPath.length > 1 && rawPath.endsWith('/');
  final segments = rawPath
      .split('/')
      .where((s) => s.isNotEmpty)
      .map((segment) => Uri.encodeComponent(_safeDecodeUriSegment(segment)))
      .join('/');
  if (segments.isEmpty) return leadingSlash ? '/' : '';
  return '${leadingSlash ? '/' : ''}$segments${trailingSlash ? '/' : ''}';
}

String _canonicalDecodedPath(String rawPath) {
  final segments = rawPath
      .split('/')
      .where((s) => s.isNotEmpty)
      .map(_safeDecodeUriSegment)
      .toList(growable: false);
  return segments.isEmpty ? '/' : '/${segments.join('/')}';
}

String _safeDecodeUriSegment(String segment) {
  try {
    return Uri.decodeComponent(segment);
  } on ArgumentError {
    return segment;
  }
}

DateTime? _parseWebDavDate(String value) {
  try {
    return HttpDate.parse(value);
  } on Object {
    return DateTime.tryParse(value);
  }
}

String? _extractFirstTagInnerXml(String xml, String localName) {
  final pattern = RegExp(
    '<(?:[A-Za-z0-9_.-]+:)?$localName(?:\\s[^>]*)?>(.*?)</(?:[A-Za-z0-9_.-]+:)?$localName>',
    caseSensitive: false,
    dotAll: true,
  );
  return pattern.firstMatch(xml)?.group(1);
}

String? _extractFirstTagText(String xml, String localName) {
  final inner = _extractFirstTagInnerXml(xml, localName);
  if (inner == null) return null;
  final strippedCdata = inner.replaceAllMapped(
    RegExp(r'<!\[CDATA\[(.*?)\]\]>', dotAll: true),
    (match) => match.group(1) ?? '',
  );
  return _unescapeXmlText(strippedCdata);
}

String _unescapeXmlText(String input) {
  if (!input.contains('&')) return input;
  return input
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAllMapped(RegExp(r'&#x([0-9A-Fa-f]+);'), (m) {
        final code = int.tryParse(m.group(1)!, radix: 16);
        return code == null ? m.group(0)! : String.fromCharCode(code);
      })
      .replaceAllMapped(RegExp(r'&#([0-9]+);'), (m) {
        final code = int.tryParse(m.group(1)!);
        return code == null ? m.group(0)! : String.fromCharCode(code);
      })
      .replaceAll('&amp;', '&');
}
