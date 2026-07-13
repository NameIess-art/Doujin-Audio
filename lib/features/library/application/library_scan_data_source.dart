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

import '../../../core/platform/file_cache_platform_gateway.dart';
import 'library_scan_models.dart';
import '../../../core/media/media_file_support.dart';
import '../../../core/media/path_matcher.dart';

typedef LibraryChildFolderListing = ({List<String> folders, bool complete});

abstract interface class LibraryScanDataSource {
  Future<bool> ensureReadPermissionForSources(Iterable<String> sources);

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

  Future<Map<String, Object?>> scanFileSystemFolder(String folderPath);
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
    return statuses.values.any(
      (status) => status.isGranted || status.isLimited,
    );
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
    return FilePicker.platform.getDirectoryPath(dialogTitle: dialogTitle);
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

    final result = await FilePicker.platform.pickFiles(
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
  Future<Map<String, Object?>> scanFileSystemFolder(String folderPath) {
    return Isolate.run(() => scanFileSystemFolderPayload(folderPath));
  }

  Future<Directory> _persistentImportDirectory() async {
    final supportDir = await getApplicationSupportDirectory();
    return Directory(path.join(supportDir.path, 'nameless_audio_imports'));
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

Map<String, Object?> scanFileSystemFolderPayload(String folderPath) {
  final folder = Directory(folderPath);
  final normalizedRoot = path.normalize(folderPath);
  if (!folder.existsSync()) {
    return const <String, Object?>{
      'tracks': <Object?>[],
      'folderPaths': <Object?>[],
      'discoveredPaths': <String>{},
      'failureCount': 1,
    };
  }

  final pendingDirs = Queue<Directory>()..add(folder);
  final folderPaths = <String>[];
  final tracks = <Map<String, Object?>>[];
  final seenPaths = <String>{};
  var failures = 0;

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
        folderPaths.add(directoryPath);
        continue;
      }
      if (entity is! File) continue;

      final absolutePath = path.normalize(entity.path);
      if (!isSupportedMediaFile(absolutePath) || !seenPaths.add(absolutePath)) {
        continue;
      }

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

      tracks.add(<String, Object?>{
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
    }
  }

  return <String, Object?>{
    'tracks': tracks,
    'folderPaths': folderPaths,
    'discoveredPaths': Set<String>.unmodifiable(seenPaths),
    'failureCount': failures,
  };
}

@visibleForTesting
Map<String, Object?> scanFileSystemFolderPayloadForTest(String folderPath) {
  return scanFileSystemFolderPayload(folderPath);
}
