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

  String get lockKey {
    if (usesSaf) {
      final normalizedBase = basePath.trim().replaceAll(RegExp(r'/+$'), '');
      return '${kind.name}\u0000$normalizedBase\u0000${name.toLowerCase()}';
    }
    final parentPath = switch (kind) {
      JsonDocumentLocationKind.folderChild => basePath,
      JsonDocumentLocationKind.fileSibling => path.dirname(basePath),
    };
    var targetPath = path.normalize(path.absolute(path.join(parentPath, name)));
    if (Platform.isWindows) targetPath = targetPath.toLowerCase();
    return 'local\u0000$targetPath';
  }
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
        final recoveryError = await _recoverLocal(location);
        if (recoveryError != null) {
          return JsonDocumentDeleteResult(
            status: JsonDocumentDeleteStatus.conflict,
            error: recoveryError,
          );
        }
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
  ) => _JsonDocumentOperationCoordinator.run(location.lockKey, action);

  Future<JsonDocumentReadResult> _readLocal(
    JsonDocumentLocation location,
  ) async {
    try {
      final recoveryError = await _recoverLocal(location);
      if (recoveryError != null) {
        return JsonDocumentReadResult.unreadable(recoveryError);
      }
      final target = _localTarget(location);
      final actual = _findCaseInsensitive(target);
      if (actual == null) return const JsonDocumentReadResult.missing();
      final bytes = await actual.readAsBytes();
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
    final recoveryError = await _recoverLocal(location);
    if (recoveryError != null) {
      return JsonDocumentWriteResult(
        status: JsonDocumentWriteStatus.conflict,
        error: recoveryError,
      );
    }
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

    final temporary = _transactionFile(target, '.doujin.part');
    final backup = _transactionFile(target, '.doujin.bak');
    File? movedExisting;
    try {
      final stagedFile = await temporary.open(mode: FileMode.write);
      try {
        await stagedFile.writeFrom(bytes);
        await stagedFile.flush();
      } finally {
        await stagedFile.close();
      }
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
      final committed = await target.readAsBytes();
      if (_validate(committed) != null ||
          _revision(committed) != _revision(bytes)) {
        throw const FormatException('commit_validation_failed');
      }
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
        if (current != null) await current.delete();
        await movedExisting.rename(target.path);
      }
      return JsonDocumentWriteResult(
        status: JsonDocumentWriteStatus.conflict,
        error: error.toString(),
      );
    }
  }

  Future<String?> _recoverLocal(JsonDocumentLocation location) async {
    final target = _localTarget(location);
    final actualTarget = _findCaseInsensitive(target);
    final backup = _findCaseInsensitive(
      _transactionFile(target, '.doujin.bak'),
    );
    final staged = _findCaseInsensitive(
      _transactionFile(target, '.doujin.part'),
    );
    final targetValid = await _isValidJsonFile(actualTarget);
    final backupValid = await _isValidJsonFile(backup);
    final stagedValid = await _isValidJsonFile(staged);

    try {
      if (targetValid) {
        await _deleteIfPresent(backup);
        await _deleteIfPresent(staged);
        return null;
      }

      if (backupValid) {
        await _deleteIfPresent(actualTarget);
        await _deleteIfPresent(staged);
        await backup!.rename(target.path);
        return null;
      }

      if (stagedValid) {
        await _deleteIfPresent(actualTarget);
        await _deleteIfPresent(backup);
        await staged!.rename(target.path);
        return null;
      }

      if (actualTarget != null || backup != null || staged != null) {
        return 'transaction_recovery_failed';
      }
      return null;
    } on Object catch (error) {
      return 'transaction_recovery_failed: $error';
    }
  }

  Future<bool> _isValidJsonFile(File? file) async {
    if (file == null) return false;
    try {
      return _validate(await file.readAsBytes()) == null;
    } on Object {
      return false;
    }
  }

  Future<void> _deleteIfPresent(File? file) async {
    if (file != null && await file.exists()) await file.delete();
  }

  File _transactionFile(File target, String suffix) =>
      File('${target.path}$suffix');

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

final class _JsonDocumentOperationCoordinator {
  static final Map<String, Future<void>> _tails = <String, Future<void>>{};

  static Future<T> run<T>(String key, Future<T> Function() action) async {
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
