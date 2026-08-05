import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

import '../platform/file_cache_platform_gateway.dart';

enum JsonDocumentLocationKind { folderChild, fileSibling }

final class JsonDocumentLocation {
  const JsonDocumentLocation._({
    required this.kind,
    required this.basePath,
    required this.name,
  });

  const JsonDocumentLocation.folderChild({
    required String folder,
    required String name,
  }) : this._(
         kind: JsonDocumentLocationKind.folderChild,
         basePath: folder,
         name: name,
       );

  const JsonDocumentLocation.fileSibling({
    required String filePath,
    required String name,
  }) : this._(
         kind: JsonDocumentLocationKind.fileSibling,
         basePath: filePath,
         name: name,
       );

  final JsonDocumentLocationKind kind;
  final String basePath;
  final String name;

  bool get usesSaf => basePath.trimLeft().startsWith('content://');

  Map<String, Object?> toPlatformArguments() => <String, Object?>{
    'locationKind': kind.name,
    'basePath': basePath,
    'name': name,
  };

  String get lockKey =>
      '${kind.name}\u0000$basePath\u0000${name.toLowerCase()}';
}

enum JsonDocumentReadStatus { found, missing, unreadable }

final class JsonDocumentSnapshot {
  const JsonDocumentSnapshot({required this.bytes, required this.revision});

  final Uint8List bytes;
  final String revision;

  String get text => utf8.decode(bytes);
}

final class JsonDocumentReadResult {
  const JsonDocumentReadResult._({
    required this.status,
    this.snapshot,
    this.error,
  });

  const JsonDocumentReadResult.found(JsonDocumentSnapshot snapshot)
    : this._(status: JsonDocumentReadStatus.found, snapshot: snapshot);

  const JsonDocumentReadResult.missing()
    : this._(status: JsonDocumentReadStatus.missing);

  const JsonDocumentReadResult.unreadable(String error)
    : this._(status: JsonDocumentReadStatus.unreadable, error: error);

  final JsonDocumentReadStatus status;
  final JsonDocumentSnapshot? snapshot;
  final String? error;
}

enum JsonDocumentWriteMode { createIfAbsent, replaceIfRevision }

enum JsonDocumentWriteStatus { created, replaced, preserved, conflict }

enum JsonDocumentDeleteStatus { deleted, missing, conflict }

final class JsonDocumentDeleteResult {
  const JsonDocumentDeleteResult({required this.status, this.error});

  final JsonDocumentDeleteStatus status;
  final String? error;
}

final class JsonDocumentWriteResult {
  const JsonDocumentWriteResult({
    required this.status,
    this.revision,
    this.bytesWritten = 0,
    this.error,
  });

  final JsonDocumentWriteStatus status;
  final String? revision;
  final int bytesWritten;
  final String? error;

  bool get committed =>
      status == JsonDocumentWriteStatus.created ||
      status == JsonDocumentWriteStatus.replaced;
}

abstract interface class JsonDocumentStore {
  Future<JsonDocumentReadResult> read(JsonDocumentLocation location);

  Future<JsonDocumentWriteResult> write({
    required JsonDocumentLocation location,
    required Uint8List bytes,
    required JsonDocumentWriteMode mode,
    String? expectedRevision,
  });

  Future<JsonDocumentDeleteResult> delete({
    required JsonDocumentLocation location,
    required String expectedRevision,
  });
}

final class DefaultJsonDocumentStore implements JsonDocumentStore {
  DefaultJsonDocumentStore({FileCachePlatformGateway? platformGateway})
    : _platformGateway = platformGateway ?? FileCachePlatformGateway.instance;

  final FileCachePlatformGateway _platformGateway;
  final Map<String, Future<void>> _tails = <String, Future<void>>{};

  @override
  Future<JsonDocumentReadResult> read(JsonDocumentLocation location) {
    return _serialized(location, () async {
      if (location.usesSaf) {
        final value = await _platformGateway.readJsonDocument(
          location.toPlatformArguments(),
        );
        return _decodePlatformRead(value);
      }
      return _readLocal(location);
    });
  }

  @override
  Future<JsonDocumentWriteResult> write({
    required JsonDocumentLocation location,
    required Uint8List bytes,
    required JsonDocumentWriteMode mode,
    String? expectedRevision,
  }) {
    return _serialized(location, () async {
      final validationError = _validate(bytes);
      if (validationError != null) {
        return JsonDocumentWriteResult(
          status: JsonDocumentWriteStatus.conflict,
          error: validationError,
        );
      }
      if (mode == JsonDocumentWriteMode.replaceIfRevision &&
          (expectedRevision == null || expectedRevision.isEmpty)) {
        return const JsonDocumentWriteResult(
          status: JsonDocumentWriteStatus.conflict,
          error: 'expected_revision_required',
        );
      }
      if (location.usesSaf) {
        final value = await _platformGateway.writeJsonDocument(
          location: location.toPlatformArguments(),
          bytes: bytes,
          mode: mode.name,
          expectedRevision: expectedRevision,
        );
        return _decodePlatformWrite(value);
      }
      return _writeLocal(
        location: location,
        bytes: bytes,
        mode: mode,
        expectedRevision: expectedRevision,
      );
    });
  }

  @override
  Future<JsonDocumentDeleteResult> delete({
    required JsonDocumentLocation location,
    required String expectedRevision,
  }) {
    return _serialized(location, () async {
      if (expectedRevision.isEmpty) {
        return const JsonDocumentDeleteResult(
          status: JsonDocumentDeleteStatus.conflict,
          error: 'expected_revision_required',
        );
      }
      if (location.usesSaf) {
        final value = await _platformGateway.deleteJsonDocument(
          location: location.toPlatformArguments(),
          expectedRevision: expectedRevision,
        );
        return _decodePlatformDelete(value);
      }
      try {
        final target = _findCaseInsensitive(_localTarget(location));
        if (target == null) {
          return const JsonDocumentDeleteResult(
            status: JsonDocumentDeleteStatus.missing,
          );
        }
        if (_revision(await target.readAsBytes()) != expectedRevision) {
          return const JsonDocumentDeleteResult(
            status: JsonDocumentDeleteStatus.conflict,
            error: 'revision_mismatch',
          );
        }
        await target.delete();
        return const JsonDocumentDeleteResult(
          status: JsonDocumentDeleteStatus.deleted,
        );
      } on Object catch (error) {
        return JsonDocumentDeleteResult(
          status: JsonDocumentDeleteStatus.conflict,
          error: error.toString(),
        );
      }
    });
  }

  Future<T> _serialized<T>(
    JsonDocumentLocation location,
    Future<T> Function() action,
  ) async {
    final key = location.lockKey;
    final previous = _tails[key] ?? Future<void>.value();
    final ready = previous.then<void>((_) {}, onError: (_, _) {});
    final completer = Completer<void>();
    _tails[key] = completer.future;
    await ready;
    try {
      return await action();
    } finally {
      completer.complete();
      if (identical(_tails[key], completer.future)) {
        final _ = _tails.remove(key);
      }
    }
  }

  JsonDocumentReadResult _readLocal(JsonDocumentLocation location) {
    try {
      final target = _localTarget(location);
      final actual = _findCaseInsensitive(target);
      if (actual == null) return const JsonDocumentReadResult.missing();
      final bytes = actual.readAsBytesSync();
      return JsonDocumentReadResult.found(
        JsonDocumentSnapshot(bytes: bytes, revision: _revision(bytes)),
      );
    } on Object catch (error) {
      return JsonDocumentReadResult.unreadable(error.toString());
    }
  }

  Future<JsonDocumentWriteResult> _writeLocal({
    required JsonDocumentLocation location,
    required Uint8List bytes,
    required JsonDocumentWriteMode mode,
    required String? expectedRevision,
  }) async {
    final target = _localTarget(location);
    final parent = target.parent;
    await parent.create(recursive: true);
    final existing = _findCaseInsensitive(target);
    if (mode == JsonDocumentWriteMode.createIfAbsent && existing != null) {
      return JsonDocumentWriteResult(
        status: JsonDocumentWriteStatus.preserved,
        revision: _revision(await existing.readAsBytes()),
      );
    }
    if (mode == JsonDocumentWriteMode.replaceIfRevision) {
      if (existing == null) {
        return const JsonDocumentWriteResult(
          status: JsonDocumentWriteStatus.conflict,
          error: 'document_missing',
        );
      }
      final currentRevision = _revision(await existing.readAsBytes());
      if (currentRevision != expectedRevision) {
        return JsonDocumentWriteResult(
          status: JsonDocumentWriteStatus.conflict,
          revision: currentRevision,
          error: 'revision_mismatch',
        );
      }
    }

    final nonce = '${DateTime.now().microsecondsSinceEpoch}.$pid';
    final targetName = path.basename(target.path);
    final temporary = File(path.join(parent.path, '.$targetName.$nonce.part'));
    final backup = File(path.join(parent.path, '.$targetName.$nonce.bak'));
    File? movedExisting;
    try {
      final sink = temporary.openWrite(mode: FileMode.writeOnly);
      sink.add(bytes);
      await sink.flush();
      await sink.close();
      final staged = await temporary.readAsBytes();
      if (_validate(staged) != null || _revision(staged) != _revision(bytes)) {
        throw const FormatException('staging_validation_failed');
      }

      final latest = _findCaseInsensitive(target);
      if (mode == JsonDocumentWriteMode.createIfAbsent && latest != null) {
        await temporary.delete();
        return JsonDocumentWriteResult(
          status: JsonDocumentWriteStatus.preserved,
          revision: _revision(await latest.readAsBytes()),
        );
      }
      if (mode == JsonDocumentWriteMode.replaceIfRevision) {
        if (latest == null ||
            _revision(await latest.readAsBytes()) != expectedRevision) {
          await temporary.delete();
          return const JsonDocumentWriteResult(
            status: JsonDocumentWriteStatus.conflict,
            error: 'revision_mismatch',
          );
        }
        movedExisting = await latest.rename(backup.path);
      }

      await temporary.rename(target.path);
      if (movedExisting != null && await movedExisting.exists()) {
        await movedExisting.delete();
      }
      return JsonDocumentWriteResult(
        status: mode == JsonDocumentWriteMode.createIfAbsent
            ? JsonDocumentWriteStatus.created
            : JsonDocumentWriteStatus.replaced,
        revision: _revision(bytes),
        bytesWritten: bytes.length,
      );
    } on Object catch (error) {
      if (await temporary.exists()) await temporary.delete();
      if (movedExisting != null && await movedExisting.exists()) {
        final current = _findCaseInsensitive(target);
        if (current == null) await movedExisting.rename(target.path);
      }
      return JsonDocumentWriteResult(
        status: JsonDocumentWriteStatus.conflict,
        error: error.toString(),
      );
    }
  }

  File _localTarget(JsonDocumentLocation location) {
    final parentPath = switch (location.kind) {
      JsonDocumentLocationKind.folderChild => location.basePath,
      JsonDocumentLocationKind.fileSibling => path.dirname(location.basePath),
    };
    return File(path.join(parentPath, location.name));
  }

  File? _findCaseInsensitive(File target) {
    if (target.existsSync()) return target;
    final parent = target.parent;
    if (!parent.existsSync()) return null;
    final expected = path.basename(target.path).toLowerCase();
    for (final entity in parent.listSync(followLinks: false)) {
      if (entity is File &&
          path.basename(entity.path).toLowerCase() == expected) {
        return entity;
      }
    }
    return null;
  }

  JsonDocumentReadResult _decodePlatformRead(Map<String, Object?>? value) {
    final status = value?['status']?.toString();
    if (status == 'missing') return const JsonDocumentReadResult.missing();
    if (status != 'found') {
      return JsonDocumentReadResult.unreadable(
        value?['error']?.toString() ?? 'platform_read_failed',
      );
    }
    final rawBytes = value?['bytes'];
    final bytes = switch (rawBytes) {
      Uint8List typed => typed,
      List<int> list => Uint8List.fromList(list),
      _ => null,
    };
    final revision = value?['revision']?.toString();
    if (bytes == null || revision == null || revision.isEmpty) {
      return const JsonDocumentReadResult.unreadable(
        'invalid_platform_snapshot',
      );
    }
    return JsonDocumentReadResult.found(
      JsonDocumentSnapshot(bytes: bytes, revision: revision),
    );
  }

  JsonDocumentWriteResult _decodePlatformWrite(Map<String, Object?>? value) {
    final status = switch (value?['status']?.toString()) {
      'created' => JsonDocumentWriteStatus.created,
      'replaced' => JsonDocumentWriteStatus.replaced,
      'preserved' => JsonDocumentWriteStatus.preserved,
      _ => JsonDocumentWriteStatus.conflict,
    };
    return JsonDocumentWriteResult(
      status: status,
      revision: value?['revision']?.toString(),
      bytesWritten: (value?['bytesWritten'] as num?)?.toInt() ?? 0,
      error: value?['error']?.toString(),
    );
  }

  JsonDocumentDeleteResult _decodePlatformDelete(Map<String, Object?>? value) {
    final status = switch (value?['status']?.toString()) {
      'deleted' => JsonDocumentDeleteStatus.deleted,
      'missing' => JsonDocumentDeleteStatus.missing,
      _ => JsonDocumentDeleteStatus.conflict,
    };
    return JsonDocumentDeleteResult(
      status: status,
      error: value?['error']?.toString(),
    );
  }
}

String? _validate(Uint8List bytes) {
  if (bytes.isEmpty) return 'empty_document';
  try {
    final text = utf8.decode(bytes);
    if (text.trim().isEmpty) return 'blank_document';
    jsonDecode(text);
    return null;
  } on Object catch (error) {
    return 'invalid_json: $error';
  }
}

String _revision(List<int> bytes) => sha256.convert(bytes).toString();
