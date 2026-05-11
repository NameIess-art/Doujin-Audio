import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import '../models/audio_detail.dart';
import '../models/dlsite_metadata.dart';

class DlsiteMetadataException implements Exception {
  const DlsiteMetadataException(this.message);

  final String message;

  @override
  String toString() => message;
}

class DlsiteMetadataService {
  DlsiteMetadataService({HttpClient? httpClient})
    : _httpClient = httpClient ?? HttpClient();

  final HttpClient _httpClient;

  Future<DlsiteMetadata> fetchByRjCode(String rjCode) async {
    final normalized = AudioDetail.findRjCodeInText(rjCode);
    if (normalized == null) {
      throw const DlsiteMetadataException('Invalid RJ code');
    }

    final uri = Uri.https('www.dlsite.com', '/maniax/api/=/product.json', {
      'workno': normalized,
    });
    final response = await _get(uri);
    final decoded = json.decode(response);
    if (decoded is! List || decoded.isEmpty || decoded.first is! Map) {
      throw const DlsiteMetadataException('No DLsite metadata found');
    }

    final metadata = DlsiteMetadata.fromProductJson(
      (decoded.first as Map).cast<String, dynamic>(),
    );
    if (metadata.rjCode.isEmpty || metadata.workTitle.isEmpty) {
      throw const DlsiteMetadataException('Incomplete DLsite metadata');
    }
    return metadata;
  }

  Future<String> downloadCover({
    required String coverUrl,
    required String folderPath,
    required String rjCode,
  }) async {
    final uri = Uri.parse(coverUrl);
    final extension = _coverExtension(uri);
    final destination = File(
      path.join(folderPath, 'dlsite_${rjCode.toUpperCase()}_cover$extension'),
    );
    final request = await _httpClient.getUrl(uri);
    _applyHeaders(request);
    final response = await request.close();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw DlsiteMetadataException(
        'Cover download failed: ${response.statusCode}',
      );
    }
    await response.pipe(destination.openWrite());
    return destination.path;
  }

  Future<String> _get(Uri uri) async {
    final request = await _httpClient.getUrl(uri);
    _applyHeaders(request);
    final response = await request.close();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw DlsiteMetadataException(
        'DLsite request failed: ${response.statusCode}',
      );
    }
    return utf8.decode(
      await response.fold<List<int>>(
        <int>[],
        (buffer, chunk) => buffer..addAll(chunk),
      ),
    );
  }

  void _applyHeaders(HttpClientRequest request) {
    request.headers.set(
      HttpHeaders.userAgentHeader,
      'Mozilla/5.0 NamelessAudio/0.8.1',
    );
    request.headers.set(
      HttpHeaders.acceptHeader,
      'application/json,text/*,*/*',
    );
  }

  String _coverExtension(Uri uri) {
    final extension = path.extension(uri.path).toLowerCase();
    if (const <String>{'.jpg', '.jpeg', '.png', '.webp'}.contains(extension)) {
      return extension;
    }
    return '.jpg';
  }
}
