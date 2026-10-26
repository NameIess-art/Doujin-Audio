import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:doujin_audio/features/library/application/cover_artwork_store.dart';

void main() {
  late Directory directory;
  late File source;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('cover_batch_');
    source = File(path.join(directory.path, 'source.image'));
    await source.writeAsBytes(List<int>.filled(256 * 1024, 7));
  });
  tearDown(() => directory.delete(recursive: true));

  test(
    'batch publishes durable bindings with one index write and source hash',
    () async {
      const count = 80;
      final sources = [
        for (var i = 0; i < count; i++)
          (logicalKey: 'source-image:$i', sourcePath: source.path),
      ];
      for (final batch in [false, true]) {
        final io = _RecordingIO(source.path);
        await IOOverrides.runWithIOOverrides(() async {
          final support = Directory(
            path.join(directory.path, batch ? 'batch' : 'single'),
          );
          final store = CoverArtworkStore(
            persistentDirectory: () async => support,
            isAndroid: () => false,
          );
          await store.initialize();
          final stopwatch = Stopwatch()..start();
          final results = batch
              ? await store.putFiles(sources)
              : [
                  for (final item in sources)
                    await store.putFile(
                      logicalKey: item.logicalKey,
                      sourcePath: item.sourcePath,
                      namespace: CoverArtworkNamespace.embedded,
                    ),
                ];
          stopwatch.stop();
          expect(results.toSet(), hasLength(1));
          expect(results.first, isNotNull);
          expect(io.indexWrites, batch ? 1 : count);
          // One read copies the artifact; all remaining reads compute its hash.
          expect(io.sourceReads, batch ? 2 : count + 1);
          final index =
              jsonDecode(
                    await File(
                      path.join(
                        store.rootPath!,
                        coverArtworkStoreIndexFileName,
                      ),
                    ).readAsString(),
                  )
                  as Map;
          expect(index['bindings'], hasLength(count));
          final restarted = CoverArtworkStore(
            persistentDirectory: () async => support,
            isAndroid: () => false,
          );
          await restarted.initialize();
          expect(
            await restarted.validatedPath(sources.last.logicalKey),
            results.last,
          );
          // ignore: avoid_print
          print(
            'COVER_BATCH ${jsonEncode({'batch': batch, 'bindings': count, 'indexWrites': io.indexWrites, 'sourceReads': io.sourceReads, 'elapsedUs': stopwatch.elapsedMicroseconds})}',
          );
        }, io);
      }
    },
  );

  test(
    'concurrent single cover calls share bounded durable index commits',
    () async {
      final io = _RecordingIO(source.path);
      await IOOverrides.runWithIOOverrides(() async {
        final store = CoverArtworkStore(
          persistentDirectory: () async => directory,
          isAndroid: () => false,
        );
        await store.initialize();
        final outputs = await Future.wait([
          for (var i = 0; i < 80; i++)
            store.putFile(
              logicalKey: 'single:$i',
              sourcePath: source.path,
              namespace: CoverArtworkNamespace.embedded,
            ),
        ]);
        expect(outputs, everyElement(isNotNull));
        expect(io.indexWrites, 3);
        final restarted = CoverArtworkStore(
          persistentDirectory: () async => directory,
          isAndroid: () => false,
        );
        await restarted.initialize();
        for (var i = 0; i < outputs.length; i++) {
          expect(restarted.resolvedPath('single:$i'), outputs[i]);
        }
      }, io);
    },
  );

  test('large queued bindings remain durable after worker encoding', () async {
    final store = CoverArtworkStore(
      persistentDirectory: () async => directory,
      isAndroid: () => false,
    );
    await Future.wait([
      for (var i = 0; i < 300; i++)
        store.bind('selected:$i', 'content://covers/$i'),
    ]);
    final restarted = CoverArtworkStore(
      persistentDirectory: () async => directory,
      isAndroid: () => false,
    );
    await restarted.initialize();
    for (var i = 0; i < 300; i++) {
      expect(restarted.resolvedPath('selected:$i'), 'content://covers/$i');
    }
  });

  test(
    'small writes and authored pins complete before a slow bulk import',
    () async {
      final io = _RecordingIO(source.path);
      await IOOverrides.runWithIOOverrides(() async {
        final store = CoverArtworkStore(
          persistentDirectory: () async => directory,
          isAndroid: () => false,
        );
        final authored = (await store.putBytes(
          logicalKey: 'user',
          bytes: [1],
        ))!;
        final small = store.putBytes(logicalKey: 'small', bytes: [2]);
        final pin = store.preserveReference(authored);
        final started = io.sourceStatStarted = Completer<void>();
        final gate = io.sourceStatGate = Completer<void>();
        final bulk = store.putFiles([
          (logicalKey: 'bulk', sourcePath: source.path),
        ]);
        try {
          await started.future;
          await small.timeout(const Duration(seconds: 3));
          await pin.timeout(const Duration(seconds: 3));
          final restarted = CoverArtworkStore(
            persistentDirectory: () async => directory,
            isAndroid: () => false,
          );
          await restarted.initialize();
          expect(restarted.resolvedPath('small'), isNotNull);
          final index =
              jsonDecode(
                    await File(
                      path.join(
                        store.rootPath!,
                        coverArtworkStoreIndexFileName,
                      ),
                    ).readAsString(),
                  )
                  as Map;
          expect(
            index['managedArtifacts'][path.relative(
              authored,
              from: store.rootPath,
            )],
            0,
          );
        } finally {
          gate.complete();
          await bulk;
        }
      }, io);
    },
  );

  test(
    'commit failure reaches every waiter and a later call can retry',
    () async {
      final store = CoverArtworkStore(
        persistentDirectory: () async => directory,
        isAndroid: () => false,
      );
      await store.initialize();
      final blocker = Directory(
        path.join(store.rootPath!, '$coverArtworkStoreIndexFileName.part'),
      );
      await blocker.create();
      final first = store.bind('one', 'content://covers/1');
      final second = store.bind('two', 'content://covers/2');
      await Future.wait([
        expectLater(first, throwsA(isA<FileSystemException>())),
        expectLater(second, throwsA(isA<FileSystemException>())),
      ]);
      await blocker.delete();
      await store.bind('one', 'content://covers/1');
      final restarted = CoverArtworkStore(
        persistentDirectory: () async => directory,
        isAndroid: () => false,
      );
      await restarted.initialize();
      expect(restarted.resolvedPath('one'), 'content://covers/1');
      expect(restarted.resolvedPath('two'), 'content://covers/2');
    },
  );

  test(
    'batch cancellation and clear cannot publish later source bindings',
    () async {
      final store = CoverArtworkStore(
        persistentDirectory: () async => directory,
        isAndroid: () => false,
      );
      var checks = 0;
      final results = await store.putFiles([
        for (var i = 0; i < 4; i++)
          (logicalKey: 'source-image:$i', sourcePath: source.path),
      ], shouldCancel: () => ++checks > 2);
      expect(results.first, isNotNull);
      expect(results.skip(1), everyElement(isNull));
      final restarted = CoverArtworkStore(
        persistentDirectory: () async => directory,
        isAndroid: () => false,
      );
      await restarted.initialize();
      expect(restarted.resolvedPath('source-image:0'), isNotNull);
      expect(restarted.resolvedPath('source-image:1'), isNull);
      final pending = store.putFiles([
        (logicalKey: 'source-image:late', sourcePath: source.path),
      ]);
      final clear = store.clear();
      expect(await pending, [null]);
      await clear;
      expect(store.resolvedPath('source-image:late'), isNull);
    },
  );

  test(
    'a failed source does not discard the rest of the batch or authored URI',
    () async {
      final store = CoverArtworkStore(
        persistentDirectory: () async => directory,
        isAndroid: () => false,
      );
      final paths = await store.putFiles([
        (logicalKey: 'missing', sourcePath: '${directory.path}/missing.image'),
        (logicalKey: 'valid', sourcePath: source.path),
        (logicalKey: 'selected', sourcePath: 'content://user/selected.jpg'),
      ]);
      expect(paths[0], isNull);
      expect(paths[1], isNotNull);
      expect(paths[2], 'content://user/selected.jpg');
      final restarted = CoverArtworkStore(
        persistentDirectory: () async => directory,
        isAndroid: () => false,
      );
      await restarted.initialize();
      expect(restarted.resolvedPath('valid'), paths[1]);
      expect(restarted.resolvedPath('selected'), paths[2]);
    },
  );

  test(
    'later batch hashes a changed source instead of reusing an old digest',
    () async {
      final store = CoverArtworkStore(
        persistentDirectory: () async => directory,
        isAndroid: () => false,
      );
      final first = await store.putFiles([
        (logicalKey: 'image', sourcePath: source.path),
      ]);
      await source.writeAsBytes([1, 2, 3]);
      final second = await store.putFiles([
        (logicalKey: 'image', sourcePath: source.path),
      ]);
      expect(second.single, isNot(first.single));
      expect(await File(second.single!).readAsBytes(), [1, 2, 3]);
    },
  );
}

final class _RecordingIO extends IOOverrides {
  _RecordingIO(this.sourcePath);
  final String sourcePath;
  int indexWrites = 0;
  int sourceReads = 0;
  Completer<void>? sourceStatStarted;
  Completer<void>? sourceStatGate;
  @override
  File createFile(String path) => _RecordingFile(super.createFile(path), this);
}

class _RecordingFile implements File {
  _RecordingFile(this.file, this.io);
  final File file;
  final _RecordingIO io;
  @override
  String get path => file.path;
  @override
  Directory get parent => file.parent;
  @override
  Future<bool> exists() => file.exists();
  @override
  Future<int> length() => file.length();
  @override
  Future<FileStat> stat() async {
    if (path == io.sourcePath && io.sourceStatGate != null) {
      if (!(io.sourceStatStarted?.isCompleted ?? true)) {
        io.sourceStatStarted!.complete();
      }
      await io.sourceStatGate!.future;
    }
    return file.stat();
  }

  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) =>
      file.open(mode: mode);
  @override
  Stream<List<int>> openRead([int? start, int? end]) {
    if (path == io.sourcePath) io.sourceReads++;
    return file.openRead(start, end);
  }

  @override
  IOSink openWrite({
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
  }) => file.openWrite(mode: mode, encoding: encoding);
  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) {
    if (path.endsWith('$coverArtworkStoreIndexFileName.part')) io.indexWrites++;
    return file.writeAsString(
      contents,
      mode: mode,
      encoding: encoding,
      flush: flush,
    );
  }

  @override
  Future<File> writeAsBytes(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) => file.writeAsBytes(bytes, mode: mode, flush: flush);

  @override
  Future<File> rename(String newPath) => file.rename(newPath);
  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      file.delete(recursive: recursive);
  @override
  Future<String> readAsString({Encoding encoding = utf8}) =>
      file.readAsString(encoding: encoding);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
