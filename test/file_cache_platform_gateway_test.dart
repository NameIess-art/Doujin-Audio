import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/platform/file_cache_platform_gateway.dart';
import 'package:doujin_audio/core/platform/platform_channels.dart';
import 'package:doujin_audio/core/media/path_matcher.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('test/file_cache_gateway');
  const scanEvents = EventChannel('test/file_cache_gateway/scan_events');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late FileCachePlatformGateway gateway;
  late List<MethodCall> calls;

  Map<String, Object?> success(Object? value) => <String, Object?>{
    'ok': true,
    'value': value,
  };

  setUp(() {
    calls = <MethodCall>[];
    gateway = FileCachePlatformGateway(
      channel: channel,
      scanEvents: scanEvents,
      isAndroid: () => true,
    );
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockStreamHandler(scanEvents, null);
  });

  test('typed document operations preserve the platform payload', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return success(true);
    });

    expect(
      await gateway.copyFileToFolder(
        sourcePath: '/tmp/source.mp3',
        folder: 'content://library',
        relativePath: 'work/source.mp3',
        overwrite: true,
      ),
      isTrue,
    );

    expect(calls.single.method, FileCacheMethod.copyFileToFolder);
    expect(calls.single.arguments, <String, Object?>{
      'sourcePath': '/tmp/source.mp3',
      'folder': 'content://library',
      'relativePath': 'work/source.mp3',
      'overwrite': true,
    });
  });

  test('storage usage decodes the stable platform payload', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return success(<String, Object?>{
        'totalBytes': 1000,
        'availableBytes': 400,
        'cacheBytes': 120,
      });
    });

    final usage = await gateway.readStorageUsage();

    expect(usage?.totalBytes, 1000);
    expect(usage?.availableBytes, 400);
    expect(usage?.cacheBytes, 120);
    expect(calls.single.method, FileCacheMethod.getStorageUsage);
    expect(calls.single.arguments, isNull);
  });

  test(
    'persisted URI reconciliation sends unique retained references',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return success(<String, Object?>{
          'retainedCount': 2,
          'releasedCount': 1,
          'failedUris': <String>['content://provider/tree/failed'],
        });
      });

      final result = await gateway.reconcilePersistedUriPermissions(<String>[
        'content://provider/tree/library',
        'content://provider/tree/library',
        'content://provider/document/track',
      ]);

      expect(result?.retainedCount, 2);
      expect(result?.releasedCount, 1);
      expect(result?.failedUris, <String>['content://provider/tree/failed']);
      expect(
        calls.single.method,
        FileCacheMethod.reconcilePersistedUriPermissions,
      );
      expect(
        (calls.single.arguments as Map<Object?, Object?>)['retainedUris'],
        <String>[
          'content://provider/tree/library',
          'content://provider/document/track',
        ],
      );
    },
  );

  test('JSON delete sends a revision-guarded structured request', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return success(<String, Object?>{'status': 'deleted'});
    });

    final result = await gateway.deleteJsonDocument(
      location: const <String, Object?>{
        'locationKind': 'folderChild',
        'basePath': 'content://library',
        'name': 'doujin-audio.json',
      },
      expectedRevision: 'revision-1',
    );

    expect(result?['status'], 'deleted');
    expect(calls.single.method, FileCacheMethod.deleteJsonDocument);
    expect(calls.single.arguments, <String, Object?>{
      'locationKind': 'folderChild',
      'basePath': 'content://library',
      'name': 'doujin-audio.json',
      'expectedRevision': 'revision-1',
    });
  });

  test(
    'document existence keeps native query failure distinct from missing',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        return <String, Object?>{
          'ok': false,
          'errorCode': 'document_path_exists_failed',
          'error': 'provider unavailable',
        };
      });

      expect(await gateway.documentPathExistence('content://library'), isNull);
      expect(await gateway.documentPathExists('content://library'), isFalse);
    },
  );

  test(
    'exportFile maps arguments and preserves success or cancellation',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return success(calls.length == 1 ? 'content://exported' : null);
      });

      expect(
        await gateway.exportFile(
          sourcePath: '/tmp/diagnostic.zip',
          fileName: 'diagnostic.zip',
          mimeType: 'application/zip',
        ),
        'content://exported',
      );
      expect(
        await gateway.exportFile(
          sourcePath: '/tmp/diagnostic.zip',
          fileName: 'diagnostic.zip',
          mimeType: 'application/zip',
        ),
        isNull,
      );
      expect(calls.first.method, FileCacheMethod.exportFile);
      expect(calls.first.arguments, <String, Object?>{
        'sourcePath': '/tmp/diagnostic.zip',
        'fileName': 'diagnostic.zip',
        'mimeType': 'application/zip',
      });
    },
  );

  test('exportFile skips the native channel outside Android', () async {
    final nonAndroidGateway = FileCachePlatformGateway(
      channel: channel,
      isAndroid: () => false,
    );
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return 'unexpected';
    });

    expect(
      await nonAndroidGateway.exportFile(
        sourcePath: '/tmp/report.zip',
        fileName: 'report.zip',
        mimeType: 'application/zip',
      ),
      isNull,
    );
    expect(calls, isEmpty);
  });

  test('typed media helpers parse native values', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return success(switch (call.method) {
        FileCacheMethod.discoverRootImages => <Object?>[
          <String, String>{
            'path': ' /cache/cover-a ',
            'sourcePath': ' content://cover-a ',
          },
          '',
          'content://cover-b',
        ],
        FileCacheMethod.resolveTrackSubtitle => <String, Object?>{
          'sourcePath': 'content://subtitle',
          'text': 'subtitle',
          'extension': '.srt',
        },
        FileCacheMethod.resolveMediaDuration => 123456,
        _ => null,
      });
    });

    expect(
      await gateway.discoverRootImages(
        path: 'content://track',
        rootFolder: 'content://folder',
      ),
      const <CoverImageReference>[
        CoverImageReference(
          displayPath: '/cache/cover-a',
          sourcePath: 'content://cover-a',
        ),
        CoverImageReference(
          displayPath: 'content://cover-b',
          sourcePath: 'content://cover-b',
        ),
      ],
    );
    expect(
      await gateway.resolveTrackSubtitle(path: 'content://track'),
      containsPair('extension', '.srt'),
    );
    expect(
      await gateway.resolveMediaDuration('content://track'),
      const Duration(milliseconds: 123456),
    );
  });

  test(
    'Windows discovery preserves empty success and missing-directory failure',
    () async {
      final folder = await Directory.systemTemp.createTemp('目录 cache ');
      addTearDown(() => folder.delete(recursive: true));
      final windows = FileCachePlatformGateway(
        isAndroid: () => false,
        isWindows: () => true,
      );
      expect(await windows.discoverWorkTexts(folder.path), isEmpty);
      expect(
        await windows.discoverRootImages(
          path: folder.path,
          rootFolder: folder.path,
        ),
        isEmpty,
      );
      final missing = '${folder.path}${Platform.pathSeparator}missing';
      await expectLater(
        windows.discoverWorkTexts(missing),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(
        windows.discoverRootImages(path: missing, rootFolder: missing),
        throwsA(isA<FileSystemException>()),
      );
    },
  );

  test(
    'directory discovery distinguishes failure from successful empty scans',
    () async {
      messenger.setMockMethodCallHandler(channel, (_) async => success([]));
      expect(await gateway.discoverWorkTexts('content://work'), isEmpty);
      expect(
        await gateway.discoverRootImages(
          path: 'content://work',
          rootFolder: 'content://work',
        ),
        isEmpty,
      );
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => {
          'ok': false,
          'errorCode': 'access_denied',
          'error': 'Access denied',
        },
      );
      await expectLater(
        gateway.discoverWorkTexts('content://work'),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'access_denied',
          ),
        ),
      );
      await expectLater(
        gateway.discoverRootImages(
          path: 'content://work',
          rootFolder: 'content://work',
        ),
        throwsA(isA<PlatformException>()),
      );
    },
  );

  test(
    'structured JSON document and byte-write helpers preserve values',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return success(switch (call.method) {
          FileCacheMethod.writeJsonDocument => <String, Object?>{
            'status': 'created',
            'revision': 'abc',
            'bytesWritten': 2,
          },
          FileCacheMethod.writeFileBytesToFolder => <String, String>{
            'path': '/cache/saved.jpg',
            'sourcePath': 'content://saved',
          },
          _ => null,
        });
      });

      expect(
        await gateway.writeJsonDocument(
          location: <String, Object?>{
            'locationKind': 'folderChild',
            'basePath': 'content://folder',
            'name': 'data.json',
          },
          bytes: Uint8List.fromList(<int>[123, 125]),
          mode: 'createIfAbsent',
        ),
        containsPair('status', 'created'),
      );
      expect(
        await gateway.writeFileBytesToFolder(
          folder: 'content://folder',
          name: 'cover.jpg',
          bytes: Uint8List.fromList(<int>[1, 2, 3]),
          mimeType: 'image/jpeg',
        ),
        const CoverImageReference(
          displayPath: '/cache/saved.jpg',
          sourcePath: 'content://saved',
        ),
      );
      expect(calls.map((call) => call.method), <String>[
        FileCacheMethod.writeJsonDocument,
        FileCacheMethod.writeFileBytesToFolder,
      ]);
      expect(calls.first.arguments, <String, Object?>{
        'locationKind': 'folderChild',
        'basePath': 'content://folder',
        'name': 'data.json',
        'bytes': Uint8List.fromList(<int>[123, 125]),
        'mode': 'createIfAbsent',
        'expectedRevision': null,
      });
    },
  );

  test(
    'saveTrackSubtitle sends the audio identity and original source for moving',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return success('content://folder/voice.lrc');
      });

      final bytes = Uint8List.fromList(<int>[91, 48, 48, 58, 48, 49, 93]);
      expect(
        await gateway.saveTrackSubtitle(
          trackPath: 'content://folder/voice.mp3',
          groupKey: 'content://folder',
          extension: '.lrc',
          sourcePath: 'content://selected/subtitle',
          overwrite: true,
          bytes: bytes,
        ),
        'content://folder/voice.lrc',
      );
      expect(calls.single.method, FileCacheMethod.writeTrackSubtitle);
      expect(calls.single.arguments, <String, Object?>{
        'trackPath': 'content://folder/voice.mp3',
        'groupKey': 'content://folder',
        'extension': '.lrc',
        'sourcePath': 'content://selected/subtitle',
        'overwrite': true,
        'bytes': bytes,
      });
    },
  );

  test('new SAF translations use a create-only filename suffix', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return success('content://folder/new-translation');
    });
    final bytes = Uint8List.fromList([65]);
    expect(
      await gateway.saveTrackSubtitle(
        trackPath: 'content://folder/audio',
        groupKey: 'content://folder',
        extension: '.srt',
        createNew: true,
        fileNameSuffix: '.translated.zh-CN',
        bytes: bytes,
      ),
      'content://folder/new-translation',
    );
    expect(calls.single.method, FileCacheMethod.writeTrackSubtitle);
    expect(calls.single.arguments, {
      'trackPath': 'content://folder/audio',
      'groupKey': 'content://folder',
      'extension': '.srt',
      'overwrite': false,
      'createNew': true,
      'fileNameSuffix': '.translated.zh-CN',
      'bytes': bytes,
    });
    for (final overwrite in [false, true]) {
      await expectLater(
        gateway.saveTrackSubtitle(
          trackPath: 'content://folder/audio',
          extension: '.srt',
          createNew: true,
          fileNameSuffix: '.translated.en',
          sourcePath: overwrite ? null : 'content://folder/original',
          overwrite: overwrite,
          bytes: bytes,
        ),
        throwsArgumentError,
      );
    }
    expect(calls, hasLength(1));
  });

  test('SAF subtitle choices preserve opaque URIs and display names', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return success([
        {'sourcePath': 'content://folder/123', 'name': 'voice.ja.srt'},
        {
          'sourcePath': 'content://folder/456',
          'name': 'voice.mp3.translated.en.srt',
        },
      ]);
    });
    final files = await gateway.listTrackSubtitles(
      trackPath: 'content://folder/audio',
      groupKey: 'content://folder',
    );
    expect(files, [
      (sourcePath: 'content://folder/123', name: 'voice.ja.srt'),
      (sourcePath: 'content://folder/456', name: 'voice.mp3.translated.en.srt'),
    ]);
    expect(calls.single.method, FileCacheMethod.listTrackSubtitles);
    expect(calls.single.arguments, {
      'trackPath': 'content://folder/audio',
      'groupKey': 'content://folder',
    });
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => {
        'ok': false,
        'errorCode': 'subtitle_list_failed',
        'error': 'No permission',
      },
    );
    await expectLater(
      gateway.listTrackSubtitles(trackPath: 'content://folder/audio'),
      throwsA(
        isA<PlatformException>().having(
          (e) => e.code,
          'code',
          'subtitle_list_failed',
        ),
      ),
    );
  });

  test('writeTrackSubtitle targets the original subtitle URI', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return success(true);
    });
    final bytes = Uint8List.fromList([65]);
    expect(
      await gateway.writeTrackSubtitle(
        path: 'content://folder/subtitle.srt',
        bytes: bytes,
      ),
      isTrue,
    );
    expect(calls.single.method, FileCacheMethod.writeTrackSubtitle);
    expect(calls.single.arguments, {
      'path': 'content://folder/subtitle.srt',
      'bytes': bytes,
    });
  });

  test(
    'malformed and failed optional envelopes keep technical errors out of values',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        return switch (call.method) {
          FileCacheMethod.resolveTrackCover => <String, Object?>{
            'value': 'legacy-without-ok',
          },
          FileCacheMethod.resolveTrackSubtitle => <String, Object?>{
            'ok': false,
            'errorCode': 'subtitle_resolve_failed',
            'error': 'native parser failed',
            'details': <String, Object?>{'exception': 'IOException'},
          },
          _ => success(null),
        };
      });

      expect(await gateway.resolveTrackCover(path: 'content://track'), isNull);
      expect(
        await gateway.resolveTrackSubtitle(path: 'content://track'),
        isNull,
      );
    },
  );

  test(
    'unsupported platform scan and metadata report unsupported without calls',
    () async {
      final nonAndroidGateway = FileCachePlatformGateway(
        channel: channel,
        isAndroid: () => false,
        isWindows: () => false,
      );

      expect(
        (await nonAndroidGateway.scanFolder('/music')).notSupported,
        isTrue,
      );
      expect(await nonAndroidGateway.listChildFolders('/music'), isNull);
      expect(
        await nonAndroidGateway.resolveMediaDuration('/music/track.flac'),
        isNull,
      );
    },
  );

  for (final collect in [true, false]) {
    for (final failures in [0, 3]) {
      test(
        'scan preserves incomplete result (collect=$collect, failures=$failures)',
        () async {
          messenger.setMockStreamHandler(
            scanEvents,
            MockStreamHandler.inline(onListen: (_, _) {}),
          );
          messenger.setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return success(true);
          });
          final scan = collect
              ? gateway.scanFolder('/music')
              : gateway.scanFolderChunked('/music', (_) => true);
          await _waitForMethodCall(calls, FileCacheMethod.startFolderScan, 1);
          final args = Map<String, Object?>.from(
            calls
                    .firstWhere(
                      (call) => call.method == FileCacheMethod.startFolderScan,
                    )
                    .arguments
                as Map,
          );
          Future<void> emit(Map<String, Object?> event) async {
            await messenger.handlePlatformMessage(
              scanEvents.name,
              scanEvents.codec.encodeSuccessEnvelope(event),
              null,
            );
          }

          await emit({
            ...args,
            'generationId': 'obsolete',
            'eventType': 'completed',
          });
          expect((await gateway.scanFolder('/other')).errorCode, 'scan_busy');
          await emit({
            ...args,
            'eventType': 'chunk',
            'chunkSequence': 1,
            'tracks': [
              {'path': '/music/one.mp3'},
            ],
            'failureCount': failures == 0 ? 0 : 2,
          });
          await emit({
            ...args,
            'eventType': 'completed',
            'failureCount': failures == 0 ? 0 : 1,
            'complete': false,
          });
          final result = await scan;
          expect(result.ok, isTrue);
          expect(
            result.paths,
            contains(PathMatcher.normalize('/music/one.mp3')),
          );
          expect(result.failureCount, failures);
          expect(result.completenessKnown, isFalse);
          expect(result.isComplete, isFalse);
          expect(result.tracks, hasLength(collect ? 1 : 0));
        },
      );
    }
  }

  test('scan completion waits for the pending chunk callback', () async {
    messenger.setMockStreamHandler(
      scanEvents,
      MockStreamHandler.inline(onListen: (_, _) {}),
    );
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return success(true);
    });
    final entered = Completer<void>();
    final release = Completer<void>();
    var completed = false;
    final scan = gateway.scanFolderChunked('/music', (_) async {
      entered.complete();
      await release.future;
      return true;
    });
    unawaited(
      scan.then((_) {
        completed = true;
      }),
    );
    await _waitForMethodCall(calls, FileCacheMethod.startFolderScan, 1);
    final args = Map<String, Object?>.from(
      calls
              .firstWhere(
                (call) => call.method == FileCacheMethod.startFolderScan,
              )
              .arguments
          as Map,
    );
    Future<void> emit(String eventType) async {
      await messenger.handlePlatformMessage(
        scanEvents.name,
        scanEvents.codec.encodeSuccessEnvelope({
          ...args,
          'eventType': eventType,
          if (eventType == 'chunk') 'chunkSequence': 1,
          if (eventType == 'completed') 'complete': true,
        }),
        null,
      );
    }

    await emit('chunk');
    await entered.future;
    expect(
      calls.where(
        (call) => call.method == FileCacheMethod.acknowledgeFolderScanChunk,
      ),
      isEmpty,
    );
    await emit('completed');
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);
    release.complete();
    expect((await scan).isComplete, isTrue);
    expect(
      calls
          .singleWhere(
            (call) => call.method == FileCacheMethod.acknowledgeFolderScanChunk,
          )
          .arguments,
      {'taskId': args['taskId'], 'chunkSequence': 1},
    );
  });

  for (final outcome in [
    'false',
    'throw',
    'cancel',
    'ackRejected',
    'ackError',
  ]) {
    test(
      'chunk processing stops without further acknowledgement ($outcome)',
      () async {
        messenger.setMockStreamHandler(
          scanEvents,
          MockStreamHandler.inline(onListen: (_, _) {}),
        );
        late Map<String, Object?> args;
        Future<void> emit(String type) => messenger.handlePlatformMessage(
          scanEvents.name,
          scanEvents.codec.encodeSuccessEnvelope({
            ...args,
            'eventType': type,
            if (type == 'chunk') 'chunkSequence': 1,
          }),
          null,
        );
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == FileCacheMethod.acknowledgeFolderScanChunk) {
            if (outcome == 'ackError') {
              throw PlatformException(code: 'ack_failed');
            }
            return success(outcome != 'ackRejected');
          }
          return success(true);
        });
        final entered = Completer<void>();
        final release = Completer<void>();
        final scan = gateway.scanFolderChunked('/music', (_) async {
          entered.complete();
          await release.future;
          if (outcome == 'throw') throw StateError('merge failed');
          return outcome != 'false';
        });
        await _waitForMethodCall(calls, FileCacheMethod.startFolderScan, 1);
        args = Map<String, Object?>.from(calls.first.arguments as Map);
        await emit('chunk');
        await entered.future;
        if (outcome == 'cancel') {
          var completed = false;
          unawaited(scan.then((_) => completed = true));
          await gateway.cancelActiveFolderScan();
          expect(completed, isFalse);
        }
        release.complete();
        final result = await scan;
        expect(result.wasCancelled, outcome == 'false' || outcome == 'cancel');
        if (outcome == 'throw') expect(result.errorCode, 'scan_handler_error');
        if (outcome.startsWith('ack')) {
          expect(result.errorCode, 'scan_acknowledgement_failed');
        }
        expect(
          calls.where(
            (call) => call.method == FileCacheMethod.acknowledgeFolderScanChunk,
          ),
          hasLength(outcome.startsWith('ack') ? 1 : 0),
        );
        expect(
          calls.where(
            (call) => call.method == FileCacheMethod.cancelFolderScan,
          ),
          hasLength(1),
        );
      },
    );
  }

  test('idle cancellation completes without a native terminal event', () async {
    messenger.setMockStreamHandler(
      scanEvents,
      MockStreamHandler.inline(onListen: (_, _) {}),
    );
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return success(true);
    });
    final scan = gateway.scanFolderChunked('/music', (_) => true);
    await _waitForMethodCall(calls, FileCacheMethod.startFolderScan, 1);
    await gateway.cancelActiveFolderScan();
    final result = await scan;
    expect(result.ok, isTrue);
    expect(result.wasCancelled, isTrue);
    expect(result.isComplete, isFalse);
    expect(
      calls.where(
        (call) => call.method == FileCacheMethod.acknowledgeFolderScanChunk,
      ),
      isEmpty,
    );
    expect(
      calls.where((call) => call.method == FileCacheMethod.cancelFolderScan),
      hasLength(1),
    );
  });

  test(
    'successive chunks acknowledge their own sequence after processing',
    () async {
      messenger.setMockStreamHandler(
        scanEvents,
        MockStreamHandler.inline(onListen: (_, _) {}),
      );
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return success(true);
      });
      final handled = <String>[];
      final progress = <int>[];
      final scan = gateway.scanFolderChunked(
        '/music',
        (chunk) {
          handled.add(chunk.tracks.single.path);
          expect(progress.last, handled.length * 120);
          expect(
            calls.where(
              (call) =>
                  call.method == FileCacheMethod.acknowledgeFolderScanChunk,
            ),
            hasLength(handled.length - 1),
          );
          return true;
        },
        onProgress: (event) async {
          await Future<void>.delayed(Duration.zero);
          expect(event.total, 300);
          progress.add(event.processed);
        },
      );
      await _waitForMethodCall(calls, FileCacheMethod.startFolderScan, 1);
      final args = Map<String, Object?>.from(calls.first.arguments as Map);
      for (var sequence = 1; sequence <= 2; sequence++) {
        await messenger.handlePlatformMessage(
          scanEvents.name,
          scanEvents.codec.encodeSuccessEnvelope({
            ...args,
            'eventType': 'chunk',
            'chunkSequence': sequence,
            'processed': sequence * 120,
            'total': 300,
            'tracks': [
              {'path': '/music/$sequence.mp3'},
            ],
          }),
          null,
        );
        await _waitForMethodCall(
          calls,
          FileCacheMethod.acknowledgeFolderScanChunk,
          sequence,
        );
        expect(calls.last.arguments, {
          'taskId': args['taskId'],
          'chunkSequence': sequence,
        });
      }
      await messenger.handlePlatformMessage(
        scanEvents.name,
        scanEvents.codec.encodeSuccessEnvelope({
          ...args,
          'eventType': 'completed',
          'complete': true,
        }),
        null,
      );
      expect((await scan).isComplete, isTrue);
      expect(progress, [120, 240]);
      expect(
        handled.map(PathMatcher.normalize),
        ['/music/1.mp3', '/music/2.mp3'].map(PathMatcher.normalize),
      );
    },
  );

  test('invalid chunk sequence stops scanning before processing', () async {
    messenger.setMockStreamHandler(
      scanEvents,
      MockStreamHandler.inline(onListen: (_, _) {}),
    );
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return success(true);
    });
    var handled = false;
    final scan = gateway.scanFolderChunked('/music', (_) {
      handled = true;
      return true;
    });
    await _waitForMethodCall(calls, FileCacheMethod.startFolderScan, 1);
    await messenger.handlePlatformMessage(
      scanEvents.name,
      scanEvents.codec.encodeSuccessEnvelope({
        ...Map<String, Object?>.from(calls.first.arguments as Map),
        'eventType': 'chunk',
        'chunkSequence': 2,
      }),
      null,
    );
    expect((await scan).errorCode, 'scan_protocol_error');
    expect(handled, isFalse);
    expect(
      calls.where(
        (call) => call.method == FileCacheMethod.acknowledgeFolderScanChunk,
      ),
      isEmpty,
    );
  });

  testWidgets('slow chunk processing pauses event inactivity timeout', (
    tester,
  ) async {
    messenger.setMockStreamHandler(
      scanEvents,
      MockStreamHandler.inline(onListen: (_, _) {}),
    );
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return success(true);
    });
    final release = Completer<void>();
    var entered = false;
    final scan = gateway.scanFolderChunked('/music', (_) async {
      entered = true;
      await release.future;
      return true;
    });
    await tester.pump();
    final args = Map<String, Object?>.from(calls.first.arguments as Map);
    await messenger.handlePlatformMessage(
      scanEvents.name,
      scanEvents.codec.encodeSuccessEnvelope({
        ...args,
        'eventType': 'chunk',
        'chunkSequence': 1,
      }),
      null,
    );
    await tester.pump();
    expect(entered, isTrue);
    await tester.pump(const Duration(seconds: 121));
    expect(
      calls.where((call) => call.method == FileCacheMethod.cancelFolderScan),
      isEmpty,
    );
    release.complete();
    await tester.pump();
    await messenger.handlePlatformMessage(
      scanEvents.name,
      scanEvents.codec.encodeSuccessEnvelope({
        ...args,
        'eventType': 'completed',
        'complete': true,
      }),
      null,
    );
    expect((await _pumpFuture(tester, scan)).isComplete, isTrue);
  });

  test(
    'chunked scan fails and releases the active task when events close',
    () async {
      messenger.setMockStreamHandler(
        scanEvents,
        MockStreamHandler.inline(onListen: (_, _) {}),
      );
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return success(true);
      });

      final firstScan = gateway.scanFolderChunked('/music', (_) => true);
      await _waitForMethodCall(calls, FileCacheMethod.startFolderScan, 1);
      await messenger.handlePlatformMessage(scanEvents.name, null, null);
      final firstResult = await firstScan;

      expect(firstResult.errorCode, 'scan_event_closed');
      expect(
        calls.where((call) => call.method == FileCacheMethod.cancelFolderScan),
        hasLength(1),
      );

      final secondScan = gateway.scanFolderChunked('/music', (_) => true);
      await _waitForMethodCall(calls, FileCacheMethod.startFolderScan, 2);
      await messenger.handlePlatformMessage(scanEvents.name, null, null);
      expect((await secondScan).errorCode, 'scan_event_closed');
    },
  );

  test('collected scan fails when its event stream closes', () async {
    messenger.setMockStreamHandler(
      scanEvents,
      MockStreamHandler.inline(onListen: (_, _) {}),
    );
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return success(true);
    });

    final scan = gateway.scanFolder('/music');
    await _waitForMethodCall(calls, FileCacheMethod.startFolderScan, 1);
    await messenger.handlePlatformMessage(scanEvents.name, null, null);

    expect((await scan).errorCode, 'scan_event_closed');
    expect(
      calls.where((call) => call.method == FileCacheMethod.cancelFolderScan),
      hasLength(1),
    );
  });

  testWidgets(
    'chunked scan times out after 120 seconds without a valid event',
    (tester) async {
      messenger.setMockStreamHandler(
        scanEvents,
        MockStreamHandler.inline(onListen: (_, _) {}),
      );
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return success(true);
      });

      final scan = gateway.scanFolderChunked('/music', (_) => true);
      await tester.pump();
      await tester.pump(const Duration(seconds: 121));
      await tester.pump();
      expect(
        calls.where((call) => call.method == FileCacheMethod.cancelFolderScan),
        hasLength(1),
      );
      final result = await _pumpFuture(tester, scan);

      expect(result.errorCode, 'scan_timeout');
      expect(
        calls.where((call) => call.method == FileCacheMethod.cancelFolderScan),
        hasLength(1),
      );
    },
  );
}

Future<void> _waitForMethodCall(
  List<MethodCall> calls,
  String method,
  int count,
) async {
  while (calls.where((call) => call.method == method).length < count) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<T> _pumpFuture<T>(WidgetTester tester, Future<T> future) async {
  T? value;
  Object? error;
  StackTrace? stackTrace;
  var completed = false;
  unawaited(
    future.then(
      (result) {
        value = result;
        completed = true;
      },
      onError: (Object caught, StackTrace caughtStackTrace) {
        error = caught;
        stackTrace = caughtStackTrace;
        completed = true;
      },
    ),
  );
  while (!completed) {
    await tester.pump();
  }
  if (error != null) Error.throwWithStackTrace(error!, stackTrace!);
  return value as T;
}
