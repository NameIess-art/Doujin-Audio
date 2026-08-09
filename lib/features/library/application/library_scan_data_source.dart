import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../core/logging/app_log_service.dart';
import '../../../core/platform/file_cache_platform_gateway.dart';
import 'library_scan_models.dart';
import '../../../core/media/media_file_support.dart';
import '../../../core/media/path_matcher.dart';

typedef LibraryChildFolderListing = ({List<String> folders, bool complete});

bool _hasRequiredAndroidMediaReadPermissions({
  required bool legacyStorageGranted,
  required bool audioGranted,
  required bool videosGranted,
}) {
  return legacyStorageGranted || (audioGranted && videosGranted);
}

bool _isGrantedOrLimited(PermissionStatus status) {
  return status.isGranted || status.isLimited;
}

abstract interface class LibraryScanDataSource {
  Future<bool> ensureReadPermissionForSources(Iterable<String> sources);

  Future<String> resolveRestorablePath(String source);

  Future<bool> sourceExists(String source);

  Future<NativeScanResult> scanFolder(String folderPath);

  Future<NativeScanResult> scanFolderChunked(
    String folderPath,
    FutureOr<bool> Function(FolderScanChunk chunk) onChunk, {
    FutureOr<void> Function(FolderScanSessionEvent event)? onProgress,
  });

  Future<LibraryChildFolderListing> listImmediateChildFolders(
    String folderPath,
  );

  Future<String?> pickAudioFolder({required String dialogTitle});

  Future<List<PickedAudioFile>?> pickAudioFiles({required String dialogTitle});

  Future<NativeScanResult> scanFileSystemFolderChunked(
    String folderPath,
    FutureOr<bool> Function(FolderScanChunk chunk) onChunk,
  );
}

class PlatformLibraryScanDataSource implements LibraryScanDataSource {
  PlatformLibraryScanDataSource({
    FileCachePlatformGateway? platformGateway,
    bool Function()? isAndroid,
  }) : _platformGateway = platformGateway ?? FileCachePlatformGateway.instance,
       _isAndroid = isAndroid ?? (() => Platform.isAndroid);

  final FileCachePlatformGateway _platformGateway;
  final bool Function() _isAndroid;

  @override
  Future<bool> ensureReadPermissionForSources(Iterable<String> sources) async {
    if (!_isAndroid()) return true;
    final sourceList = sources
        .where((source) => source.trim().isNotEmpty)
        .toList(growable: false);
    if (sourceList.isNotEmpty && sourceList.every(PathMatcher.isContentUri)) {
      return true;
    }
    final manageStatus = await Permission.manageExternalStorage.request();
    if (manageStatus.isGranted) return true;
    final statuses = await [
      Permission.audio,
      Permission.videos,
      Permission.storage,
    ].request();
    return _hasRequiredAndroidMediaReadPermissions(
      legacyStorageGranted: _isGrantedOrLimited(
        statuses[Permission.storage] ?? PermissionStatus.denied,
      ),
      audioGranted: _isGrantedOrLimited(
        statuses[Permission.audio] ?? PermissionStatus.denied,
      ),
      videosGranted: _isGrantedOrLimited(
        statuses[Permission.videos] ?? PermissionStatus.denied,
      ),
    );
  }

  @override
  Future<String> resolveRestorablePath(String source) async {
    final value = source.trim();
    if (value.isEmpty || !PathMatcher.isContentUri(value) || !_isAndroid()) {
      return value;
    }
    return await _platformGateway.resolveDocumentFileSystemPath(value) ?? value;
  }

  @override
  Future<bool> sourceExists(String source) async {
    final value = source.trim();
    if (value.isEmpty) return false;
    if (PathMatcher.isContentUri(value)) {
      if (!_isAndroid()) return false;
      return _platformGateway.documentPathExists(value);
    }
    return await FileSystemEntity.type(value, followLinks: false) !=
        FileSystemEntityType.notFound;
  }

  @override
  Future<NativeScanResult> scanFolder(String folderPath) {
    return _platformGateway.scanFolder(folderPath);
  }

  @override
  Future<NativeScanResult> scanFolderChunked(
    String folderPath,
    FutureOr<bool> Function(FolderScanChunk chunk) onChunk, {
    FutureOr<void> Function(FolderScanSessionEvent event)? onProgress,
  }) {
    return _platformGateway.scanFolderChunked(
      folderPath,
      onChunk,
      onProgress: onProgress,
    );
  }

  @override
  Future<LibraryChildFolderListing> listImmediateChildFolders(
    String folderPath,
  ) async {
    if (_isAndroid()) {
      final folders = await _platformGateway.listChildFolders(folderPath);
      if (folders != null) return (folders: folders, complete: true);
      if (PathMatcher.isContentUri(folderPath)) {
        return (folders: const <String>[], complete: false);
      }
    }

    final directory = Directory(folderPath);
    if (!await directory.exists()) {
      return (folders: const <String>[], complete: false);
    }

    final childFolders = <String>[];
    try {
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is Directory) {
          childFolders.add(path.normalize(entity.path));
        }
      }
    } catch (_) {
      return (folders: const <String>[], complete: false);
    }
    childFolders.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return (folders: childFolders, complete: true);
  }

  @override
  Future<String?> pickAudioFolder({required String dialogTitle}) async {
    if (_isAndroid()) {
      try {
        final folderPath = await _platformGateway.pickAudioFolder();
        if (folderPath != null && folderPath.isNotEmpty) return folderPath;
        return null;
      } on PlatformException {
        // Fall through to the cross-platform picker.
      }
    }
    return FilePicker.getDirectoryPath(dialogTitle: dialogTitle);
  }

  @override
  Future<List<PickedAudioFile>?> pickAudioFiles({
    required String dialogTitle,
  }) async {
    if (_isAndroid()) {
      try {
        return await _platformGateway.pickAudioFiles();
      } on PlatformException {
        // Fall through to the cross-platform picker.
      }
    }

    final result = await FilePicker.pickFiles(
      allowMultiple: true,
      withReadStream: true,
      dialogTitle: dialogTitle,
    );
    if (result == null) return null;

    final resolved = <PickedAudioFile>[];
    for (var index = 0; index < result.files.length; index++) {
      final file = result.files[index];
      final rawPath = file.path;
      if (rawPath != null &&
          rawPath.isNotEmpty &&
          !rawPath.startsWith('content://')) {
        resolved.add(
          PickedAudioFile(uri: path.normalize(rawPath), name: file.name),
        );
        continue;
      }
      final cachedPath = await _cachePickedFile(file, index);
      if (cachedPath != null) {
        resolved.add(
          PickedAudioFile(uri: path.normalize(cachedPath), name: file.name),
        );
      }
    }
    return resolved;
  }

  @override
  Future<NativeScanResult> scanFileSystemFolderChunked(
    String folderPath,
    FutureOr<bool> Function(FolderScanChunk chunk) onChunk,
  ) async {
    const chunkSize = 120;
    final receivePort = ReceivePort();
    Isolate? worker;
    final discoveredPaths = <String>{};
    try {
      worker = await Isolate.spawn<List<Object?>>(
        _scanFileSystemFolderWorker,
        <Object?>[folderPath, receivePort.sendPort, chunkSize],
        onError: receivePort.sendPort,
        onExit: receivePort.sendPort,
      );
      await for (final message in receivePort) {
        if (message == null) {
          return NativeScanResult.failed(
            code: 'filesystem_scan_ended',
            message: 'Filesystem scan isolate ended without a terminal event.',
          );
        }
        if (message is List) {
          return NativeScanResult.failed(
            code: 'filesystem_scan_error',
            message: message.isEmpty ? null : message.first.toString(),
          );
        }
        if (message is! Map) continue;
        final payload = message.cast<Object?, Object?>();
        switch (payload['type']) {
          case 'chunk':
            final tracks = <ScannedTrack>[];
            final chunkPaths = <String>{};
            final rawTracks = payload['tracks'];
            if (rawTracks is Iterable) {
              for (final rawTrack in rawTracks) {
                if (rawTrack is! Map) continue;
                final scanned = ScannedTrack.fromPayload(
                  rawTrack.cast<Object?, Object?>(),
                );
                final normalizedPath = PathMatcher.normalize(scanned.path);
                if (normalizedPath.isEmpty ||
                    !discoveredPaths.add(normalizedPath)) {
                  continue;
                }
                tracks.add(scanned);
                chunkPaths.add(normalizedPath);
              }
            }
            final folders = (payload['folders'] as Iterable? ?? const [])
                .whereType<String>()
                .map(path.normalize)
                .toList(growable: false);
            if (tracks.isEmpty && folders.isEmpty) continue;
            final keepGoing = await onChunk(
              FolderScanChunk(
                tracks: List<ScannedTrack>.unmodifiable(tracks),
                paths: Set<String>.unmodifiable(chunkPaths),
                folders: List<String>.unmodifiable(folders),
              ),
            );
            if (!keepGoing) {
              return NativeScanResult.success(
                const <ScannedTrack>[],
                Set<String>.unmodifiable(discoveredPaths),
                completenessKnown: true,
                wasCancelled: true,
              );
            }
            continue;
          case 'done':
            return NativeScanResult.success(
              const <ScannedTrack>[],
              Set<String>.unmodifiable(discoveredPaths),
              failureCount: (payload['failureCount'] as num?)?.toInt() ?? 0,
              completenessKnown: true,
            );
          case 'error':
            return NativeScanResult.failed(
              code: 'filesystem_scan_error',
              message: payload['message']?.toString(),
            );
        }
      }
      return NativeScanResult.failed(
        code: 'filesystem_scan_ended',
        message: 'Filesystem scan isolate ended without a terminal event.',
      );
    } catch (error, stackTrace) {
      AppLogService.error(
        'filesystem_library_scan_failed',
        error: error,
        stackTrace: stackTrace,
      );
      return NativeScanResult.failed(
        code: 'filesystem_scan_error',
        message: error.toString(),
      );
    } finally {
      receivePort.close();
      worker?.kill(priority: Isolate.immediate);
    }
  }

  Future<Directory> _persistentImportDirectory() async {
    final supportDir = await getApplicationSupportDirectory();
    return Directory(path.join(supportDir.path, 'doujin_audio_imports'));
  }

  Future<String?> _cachePickedFile(PlatformFile file, int index) async {
    final stream = file.readStream;
    if (stream != null) {
      try {
        final cacheDir = await _persistentImportDirectory();
        if (!await cacheDir.exists()) await cacheDir.create(recursive: true);
        final extension = path.extension(file.name);
        final outPath = path.join(
          cacheDir.path,
          '${DateTime.now().microsecondsSinceEpoch}_$index'
          '${extension.isEmpty ? '.bin' : extension}',
        );
        await stream.pipe(File(outPath).openWrite());
        return outPath;
      } catch (_) {
        // Fall through to the native content-uri cache.
      }
    }

    final identifier = file.identifier;
    if (_isAndroid() &&
        identifier != null &&
        identifier.startsWith('content://')) {
      try {
        return await _platformGateway.cacheFromUri(
          uri: identifier,
          name: file.name,
          index: index,
        );
      } catch (_) {
        return null;
      }
    }
    return null;
  }
}

void _scanFileSystemFolderWorker(List<Object?> arguments) {
  final folderPath = arguments[0]! as String;
  final sendPort = arguments[1]! as SendPort;
  final chunkSize = arguments[2]! as int;
  try {
    final failureCount = _enumerateFileSystemFolderChunks(
      folderPath,
      chunkSize: chunkSize,
      emit: (tracks, folders) {
        sendPort.send(<String, Object?>{
          'type': 'chunk',
          'tracks': tracks,
          'folders': folders,
        });
      },
    );
    sendPort.send(<String, Object?>{
      'type': 'done',
      'failureCount': failureCount,
    });
  } catch (error) {
    sendPort.send(<String, Object?>{
      'type': 'error',
      'message': error.toString(),
    });
  }
}

int _enumerateFileSystemFolderChunks(
  String folderPath, {
  required int chunkSize,
  required void Function(
    List<Map<String, Object?>> tracks,
    List<String> folders,
  )
  emit,
}) {
  final folder = Directory(folderPath);
  final normalizedRoot = path.normalize(folderPath);
  if (!folder.existsSync()) {
    return 1;
  }

  final pendingDirs = Queue<Directory>()..add(folder);
  final folderBuffer = <String>[];
  final trackBuffer = <Map<String, Object?>>[];
  var failures = 0;

  void flush() {
    if (trackBuffer.isEmpty && folderBuffer.isEmpty) return;
    emit(
      List<Map<String, Object?>>.of(trackBuffer),
      List<String>.of(folderBuffer),
    );
    trackBuffer.clear();
    folderBuffer.clear();
  }

  while (pendingDirs.isNotEmpty) {
    final currentDir = pendingDirs.removeFirst();
    List<FileSystemEntity> children;
    try {
      children = currentDir.listSync(followLinks: false);
    } catch (_) {
      failures++;
      continue;
    }

    for (final entity in children) {
      if (entity is Directory) {
        final directoryPath = path.normalize(entity.path);
        pendingDirs.add(Directory(directoryPath));
        folderBuffer.add(directoryPath);
        if (trackBuffer.length + folderBuffer.length >= chunkSize) flush();
        continue;
      }
      if (entity is! File) continue;

      final absolutePath = path.normalize(entity.path);
      if (!isSupportedMediaFile(absolutePath)) continue;

      FileStat? fileStat;
      try {
        fileStat = entity.statSync();
      } catch (_) {
        // File timestamps are optional scan metadata.
      }

      final parentFolder = path.dirname(absolutePath);
      final relative = PathMatcher.relativeWithin(absolutePath, normalizedRoot);
      var groupKey = parentFolder;
      var groupTitle = path.basename(parentFolder);
      var groupSubtitle = parentFolder;

      if (relative != null) {
        final relativeDir = path.dirname(relative).replaceAll('\\', '/');
        if (relativeDir == '.' || relativeDir.isEmpty) {
          groupKey = normalizedRoot;
          groupTitle = path.basename(normalizedRoot);
          groupSubtitle = normalizedRoot;
        } else {
          final topLevel = relativeDir.split('/').first;
          groupKey = path.join(normalizedRoot, topLevel);
          groupTitle = topLevel;
          groupSubtitle = groupKey;
        }
      } else {
        final folderName = path.basename(parentFolder);
        groupTitle = folderName.isEmpty ? parentFolder : folderName;
      }

      trackBuffer.add(<String, Object?>{
        'path': absolutePath,
        'displayName': path.basenameWithoutExtension(absolutePath),
        'groupKey': groupKey,
        'groupTitle': groupTitle,
        'groupSubtitle': groupSubtitle,
        'isSingle': false,
        'isVideo': isVideoMediaFile(absolutePath),
        'scannedAtMs': DateTime.now().millisecondsSinceEpoch,
        'fileSizeBytes': fileStat?.size,
        'modifiedAtMs': fileStat?.modified.millisecondsSinceEpoch,
      });
      if (trackBuffer.length + folderBuffer.length >= chunkSize) flush();
    }
  }
  flush();
  return failures;
}

@visibleForTesting
Map<String, Object?> scanFileSystemFolderPayloadForTest(String folderPath) {
  final tracks = <Map<String, Object?>>[];
  final folderPaths = <String>[];
  final discoveredPaths = <String>{};
  final failureCount = _enumerateFileSystemFolderChunks(
    folderPath,
    chunkSize: 120,
    emit: (chunkTracks, chunkFolders) {
      tracks.addAll(chunkTracks);
      folderPaths.addAll(chunkFolders);
      discoveredPaths.addAll(
        chunkTracks
            .map((track) => track['path'])
            .whereType<String>()
            .map(PathMatcher.normalize),
      );
    },
  );
  return <String, Object?>{
    'tracks': tracks,
    'folderPaths': folderPaths,
    'discoveredPaths': Set<String>.unmodifiable(discoveredPaths),
    'failureCount': failureCount,
  };
}
