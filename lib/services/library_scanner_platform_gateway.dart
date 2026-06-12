import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;

import 'library_scan_models.dart';
import 'media_file_support.dart';
import 'path_display.dart';
import 'platform_channels.dart';

class LibraryScannerPlatformGateway {
  LibraryScannerPlatformGateway();

  static const MethodChannel _channel = MethodChannel(FileCacheChannel.name);
  static const EventChannel _scanEvents = EventChannel(
    FileCacheChannel.scanEvents,
  );

  int _scanSessionSeed = 0;

  Future<NativeScanResult> scanFolder(String folderPath) async {
    if (!Platform.isAndroid) return const NativeScanResult.notSupported();
    final streamedScan = await _scanFolderStream(folderPath);
    if (streamedScan.ok || !streamedScan.notSupported) return streamedScan;
    return _scanFolderLegacy(folderPath);
  }

  Future<List<String>?> listChildFolders(String folderPath) async {
    if (!Platform.isAndroid) return null;
    try {
      final data = await _channel.invokeMethod<List<dynamic>>(
        FileCacheMethod.listChildFolders,
        {'folder': folderPath},
      );
      return data
          ?.map((item) => item?.toString().trim() ?? '')
          .where((item) => item.isNotEmpty)
          .toList(growable: false);
    } catch (_) {
      // Native listing is optional; the scanner falls back to file-system I/O.
      return null;
    }
  }

  Future<String?> pickAudioFolder() async {
    final raw = await _channel.invokeMapMethod<String, Object?>(
      FileCacheMethod.pickAudioFolder,
    );
    final pathValue = raw?['path']?.toString().trim();
    return pathValue == null || pathValue.isEmpty ? null : pathValue;
  }

  Future<List<PickedAudioFile>?> pickAudioFiles() async {
    final raw = await _channel.invokeMapMethod<String, Object?>(
      FileCacheMethod.pickAudioFiles,
    );
    final items = raw?['files'];
    if (items is! List) return null;
    final files = <PickedAudioFile>[];
    for (final item in items) {
      if (item is! Map) continue;
      final map = item.cast<Object?, Object?>();
      final uri = map['uri']?.toString().trim();
      final name = map['name']?.toString().trim();
      final audioTypeHint = name == null || name.isEmpty
          ? (uri ?? '')
          : path.normalize(name);
      if (uri == null || uri.isEmpty || !isSupportedMediaFile(audioTypeHint)) {
        continue;
      }
      files.add(
        PickedAudioFile(
          uri: uri,
          name: name == null || name.isEmpty
              ? PathDisplay.fileName(uri, withoutExtension: true)
              : name,
        ),
      );
    }
    return files;
  }

  Future<String?> cacheFromUri({
    required String uri,
    required String name,
    required int index,
  }) {
    return _channel.invokeMethod<String>(FileCacheMethod.cacheFromUri, {
      'uri': uri,
      'name': name,
      'index': index,
    });
  }

  Future<NativeScanResult> _scanFolderStream(String folderPath) async {
    final sessionId =
        '${DateTime.now().microsecondsSinceEpoch}-${_scanSessionSeed++}';
    final tracks = <ScannedTrack>[];
    final paths = <String>{};
    final completer = Completer<NativeScanResult>();
    StreamSubscription<dynamic>? subscription;

    void complete(NativeScanResult result) {
      if (!completer.isCompleted) completer.complete(result);
    }

    try {
      subscription = _scanEvents
          .receiveBroadcastStream(<String, Object?>{'sessionId': sessionId})
          .listen(
            (event) {
              if (event is! Map) return;
              final scanEvent = FolderScanSessionEvent.fromPayload(
                event.cast<Object?, Object?>(),
              );
              if (scanEvent.sessionId != sessionId) return;
              if (scanEvent.isChunk) {
                tracks.addAll(scanEvent.chunk.tracks);
                paths.addAll(scanEvent.chunk.paths);
              } else if (scanEvent.isDone) {
                complete(
                  NativeScanResult.success(
                    List<ScannedTrack>.unmodifiable(tracks),
                    Set<String>.unmodifiable(paths),
                  ),
                );
              } else if (scanEvent.isError) {
                complete(
                  NativeScanResult.failed(
                    code: scanEvent.errorCode,
                    message: scanEvent.errorMessage,
                  ),
                );
              }
            },
            onError: (Object error) => complete(
              NativeScanResult.failed(
                code: 'scan_event_error',
                message: error.toString(),
              ),
            ),
          );
      final started = await _channel.invokeMethod<bool>(
        FileCacheMethod.startFolderScan,
        <String, Object?>{
          'sessionId': sessionId,
          'folder': folderPath,
          'chunkSize': 120,
        },
      );
      if (started != true) return const NativeScanResult.notSupported();
      return await completer.future;
    } on MissingPluginException {
      return const NativeScanResult.notSupported();
    } on PlatformException catch (error) {
      if (error.code == 'notImplemented') {
        return const NativeScanResult.notSupported();
      }
      return NativeScanResult.failed(code: error.code, message: error.message);
    } catch (error) {
      return NativeScanResult.failed(
        code: 'scan_unknown_error',
        message: error.toString(),
      );
    } finally {
      await subscription?.cancel();
      if (!completer.isCompleted) unawaited(_cancelFolderScan(sessionId));
    }
  }

  Future<void> _cancelFolderScan(String sessionId) async {
    try {
      await _channel.invokeMethod<bool>(
        FileCacheMethod.cancelFolderScan,
        <String, Object?>{'sessionId': sessionId},
      );
    } catch (_) {
      // Cancellation is best effort because the native scan may already end.
    }
  }

  Future<NativeScanResult> _scanFolderLegacy(String folderPath) async {
    try {
      final data = await _channel.invokeMethod<List<dynamic>>(
        FileCacheMethod.scanFolder,
        {'folder': folderPath},
      );
      if (data == null) {
        return const NativeScanResult.failed(
          code: 'scan_empty_response',
          message: 'Native scan returned null data.',
        );
      }
      final payload = await Isolate.run(() => parseNativeScanPayload(data));
      return NativeScanResult.success(payload.tracks, payload.paths);
    } on PlatformException catch (error) {
      return NativeScanResult.failed(code: error.code, message: error.message);
    } catch (error) {
      return NativeScanResult.failed(
        code: 'scan_unknown_error',
        message: error.toString(),
      );
    }
  }
}
