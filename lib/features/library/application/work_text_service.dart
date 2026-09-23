import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:charset/charset.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logging/app_log_service.dart';
import '../../../core/platform/file_cache_platform_gateway.dart';

enum WorkTextEncoding {
  utf8('UTF-8'),
  shiftJis('Shift-JIS'),
  gbk('GBK');

  const WorkTextEncoding(this.label);
  final String label;
}

enum WorkDocType {
  text,
  markdown,
  pdf;

  static WorkDocType fromPath(String filePath) {
    final lower = filePath.toLowerCase();
    if (lower.endsWith('.md')) return WorkDocType.markdown;
    if (lower.endsWith('.pdf')) return WorkDocType.pdf;
    return WorkDocType.text;
  }
}

@immutable
class WorkTextFile {
  const WorkTextFile({
    required this.name,
    required this.relativePath,
    required this.path,
  });

  final String name;
  final String relativePath;
  final String path;

  WorkDocType get docType =>
      WorkDocType.fromPath(path.isNotEmpty ? path : name);

  bool get isPdf => docType == WorkDocType.pdf;
  bool get isMarkdown => docType == WorkDocType.markdown;

  String get displayName {
    final dotIndex = name.lastIndexOf('.');
    if (dotIndex > 0) {
      return name.substring(0, dotIndex);
    }
    return name;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WorkTextFile &&
          name == other.name &&
          relativePath == other.relativePath &&
          path == other.path;

  @override
  int get hashCode => Object.hash(name, relativePath, path);
}

({String text, WorkTextEncoding encoding}) decodeWorkText(
  Uint8List bytes, {
  WorkTextEncoding? overrideEncoding,
}) {
  if (bytes.isEmpty) {
    return (text: '', encoding: overrideEncoding ?? WorkTextEncoding.utf8);
  }

  if (overrideEncoding != null) {
    final text = _decodeWithEncoding(bytes, overrideEncoding);
    return (text: text, encoding: overrideEncoding);
  }

  // 1. Check for UTF-8 BOM: 0xEF, 0xBB, 0xBF
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    final text = utf8.decode(bytes.sublist(3), allowMalformed: true);
    return (text: text, encoding: WorkTextEncoding.utf8);
  }

  // 2. Try strict UTF-8
  try {
    final text = utf8.decode(bytes, allowMalformed: false);
    return (text: text, encoding: WorkTextEncoding.utf8);
  } on FormatException {
    // Not valid UTF-8, proceed to Shift-JIS vs GBK
  }

  // 3. Detect between Shift-JIS and GBK
  final detected = Charset.detect(bytes, orders: [shiftJis, gbk]);
  if (detected == gbk) {
    return (
      text: _decodeWithEncoding(bytes, WorkTextEncoding.gbk),
      encoding: WorkTextEncoding.gbk,
    );
  } else if (detected == shiftJis) {
    return (
      text: _decodeWithEncoding(bytes, WorkTextEncoding.shiftJis),
      encoding: WorkTextEncoding.shiftJis,
    );
  }

  final canShiftJis = Charset.canDecode(shiftJis, bytes);
  final canGbk = Charset.canDecode(gbk, bytes);
  if (canShiftJis && !canGbk) {
    return (
      text: _decodeWithEncoding(bytes, WorkTextEncoding.shiftJis),
      encoding: WorkTextEncoding.shiftJis,
    );
  }
  if (canGbk && !canShiftJis) {
    return (
      text: _decodeWithEncoding(bytes, WorkTextEncoding.gbk),
      encoding: WorkTextEncoding.gbk,
    );
  }

  // Default fallback: Shift-JIS (standard for Japanese voice drama) -> GBK -> UTF-8
  try {
    final text = shiftJis.decode(bytes);
    return (text: text, encoding: WorkTextEncoding.shiftJis);
  } catch (_) {
    try {
      final text = gbk.decode(bytes);
      return (text: text, encoding: WorkTextEncoding.gbk);
    } catch (_) {
      return (
        text: utf8.decode(bytes, allowMalformed: true),
        encoding: WorkTextEncoding.utf8,
      );
    }
  }
}

String _decodeWithEncoding(Uint8List bytes, WorkTextEncoding encoding) {
  try {
    switch (encoding) {
      case WorkTextEncoding.utf8:
        return utf8.decode(bytes, allowMalformed: true);
      case WorkTextEncoding.shiftJis:
        return shiftJis.decode(bytes);
      case WorkTextEncoding.gbk:
        return gbk.decode(bytes);
    }
  } catch (_) {
    return utf8.decode(bytes, allowMalformed: true);
  }
}

class WorkTextService {
  WorkTextService({
    FileCachePlatformGateway? platformGateway,
    HttpClient Function()? httpClientFactory,
  }) : _platformGateway = platformGateway ?? FileCachePlatformGateway.instance,
       _httpClientFactory = httpClientFactory ?? HttpClient.new;

  final FileCachePlatformGateway _platformGateway;
  final HttpClient Function() _httpClientFactory;

  Future<List<WorkTextFile>> findWorkTextFiles(String workFolderPath) async {
    if (workFolderPath.trim().isEmpty) return const [];
    final rawList = await _platformGateway.discoverWorkTexts(workFolderPath);
    return rawList
        .map((map) {
          return WorkTextFile(
            name: map['name'] ?? '',
            relativePath: map['relativePath'] ?? '',
            path: map['path'] ?? '',
          );
        })
        .where((f) => f.name.isNotEmpty && f.path.isNotEmpty)
        .toList(growable: false);
  }

  Future<({String text, WorkTextEncoding encoding})> readDecodedText(
    WorkTextFile file, {
    WorkTextEncoding? encodingOverride,
  }) async {
    final bytes = await readDocumentBytes(file);
    if (bytes == null) {
      return (text: '', encoding: encodingOverride ?? WorkTextEncoding.utf8);
    }
    return decodeWorkText(bytes, overrideEncoding: encodingOverride);
  }

  Future<Uint8List?> readDocumentBytes(WorkTextFile file) async {
    final filePath = file.path.trim();
    if (filePath.startsWith('http://') || filePath.startsWith('https://')) {
      final uri = Uri.tryParse(filePath);
      if (uri == null) return null;
      final client = _httpClientFactory();
      HttpClientRequest? request;
      try {
        try {
          client.connectionTimeout = const Duration(seconds: 15);
        } catch (_) {
          // Timeout configuration is optional for custom test clients.
        }
        request = await client.getUrl(uri).timeout(const Duration(seconds: 15));
        final response =
            await request.close().timeout(const Duration(seconds: 15));
        if (response.statusCode < 200 || response.statusCode >= 300) {
          return null;
        }
        final bytesBuilder = BytesBuilder(copy: false);
        await for (final chunk in response.timeout(const Duration(seconds: 30))) {
          bytesBuilder.add(chunk);
        }
        return bytesBuilder.takeBytes();
      } catch (error, stackTrace) {
        request?.abort(error);
        AppLogService.warning(
          'read_remote_document_bytes_failed',
          error: error,
          stackTrace: stackTrace,
        );
        return null;
      } finally {
        client.close(force: true);
      }
    }
    return _platformGateway.readDocumentBytes(file.path);
  }
}

final workTextServiceProvider = Provider<WorkTextService>((ref) {
  return WorkTextService();
});
