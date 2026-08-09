import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/platform/file_cache_platform_gateway.dart';
import 'package:doujin_audio/core/platform/platform_channels.dart';

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
    'non-Android scan and listing report unsupported without calls',
    () async {
      final nonAndroidGateway = FileCachePlatformGateway(
        channel: channel,
        isAndroid: () => false,
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
