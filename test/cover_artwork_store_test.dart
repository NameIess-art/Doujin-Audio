import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:doujin_audio/features/library/application/cover_artwork_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

void main() {
  late Directory supportDirectory;
  late Directory temporaryDirectory;

  setUp(() async {
    supportDirectory = await Directory.systemTemp.createTemp(
      'cover_store_support_',
    );
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'cover_store_temp_',
    );
  });

  tearDown(() async {
    if (await supportDirectory.exists()) {
      await supportDirectory.delete(recursive: true);
    }
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  CoverArtworkStore createStore() => CoverArtworkStore(
    persistentDirectory: () async => supportDirectory,
    temporaryDirectory: () async => temporaryDirectory,
  );

  for (final android in [false, true]) {
    for (final version in [1, 2]) {
      test(
        'cold restore retires old Android automatic artwork ($android, index $version)',
        () async {
          final root = Directory(
            path.join(supportDirectory.path, coverArtworkStoreDirectoryName),
          );
          const videoKey = 'video:/work/video.mp4:100:v3';
          final old = File(
            path.join(
              root.path,
              'generated',
              '${sha256.convert(utf8.encode(videoKey))}.image',
            ),
          );
          await old.parent.create(recursive: true);
          await old.writeAsBytes([1]);
          final selected = File(
            path.join(root.path, 'embedded', 'selected.image'),
          );
          await selected.parent.create(recursive: true);
          await selected.writeAsBytes([2]);
          final remote = File(path.join(root.path, 'remote', 'remote.image'));
          await remote.parent.create(recursive: true);
          await remote.writeAsBytes([3]);
          final portable = File(
            path.join(
              supportDirectory.path,
              'portable_card_covers',
              'cover.jpg',
            ),
          );
          await portable.parent.create(recursive: true);
          await portable.writeAsBytes([4]);
          final keys = [
            videoKey,
            'native:/work/audio.mp3|1|2',
            'track:/work/audio.mp3|1|2|false',
            'folder:/work',
            'source-image:content://images/cover',
          ];
          final index = File(
            path.join(root.path, coverArtworkStoreIndexFileName),
          );
          await index.writeAsString(
            jsonEncode({
              'version': version,
              'bindings': {
                for (final key in keys)
                  key: path.relative(old.path, from: root.path),
                'selected-image:/chosen': path.relative(
                  selected.path,
                  from: root.path,
                ),
                'selected-image:/other': path.relative(
                  old.path,
                  from: root.path,
                ),
                'folder:/chosen': path.relative(selected.path, from: root.path),
                'folder:/portable': portable.path,
                'remote-cover:https://example.com/cover': path.relative(
                  remote.path,
                  from: root.path,
                ),
              },
              'legacyAliases': <String, String>{},
            }),
          );
          final store = CoverArtworkStore(
            persistentDirectory: () async => supportDirectory,
            temporaryDirectory: () async => temporaryDirectory,
            isAndroid: () => android,
          );
          await store.initialize();
          for (final key in keys) {
            expect(await store.validatedPath(key), android ? isNull : old.path);
          }
          expect(
            await store.validatedPath('folder:/chosen'),
            android ? isNull : selected.path,
          );
          expect(await store.validatedPath('selected-image:/other'), old.path);
          expect(
            await store.validatedPath('selected-image:/chosen'),
            selected.path,
          );
          expect(await store.validatedPath('folder:/portable'), portable.path);
          expect(
            await store.validatedPath('remote-cover:https://example.com/cover'),
            remote.path,
          );
          expect(store.isObsoleteAndroidAutomaticPath(old.path), android);
          final source = File(path.join(supportDirectory.path, 'fresh.jpg'));
          await source.writeAsBytes([9]);
          final rebuilt = await store.putFile(
            logicalKey: videoKey,
            sourcePath: source.path,
          );
          expect(await File(rebuilt!).readAsBytes(), android ? [9] : [1]);
          expect(await old.readAsBytes(), [1]);
          final restarted = CoverArtworkStore(
            persistentDirectory: () async => supportDirectory,
            temporaryDirectory: () async => temporaryDirectory,
            isAndroid: () => android,
          );
          await restarted.initialize();
          expect(await restarted.validatedPath(videoKey), rebuilt);
        },
      );
    }
  }

  test(
    'old Android native artifacts are recognized only within the application cache',
    () async {
      final store = CoverArtworkStore(
        persistentDirectory: () async => supportDirectory,
        temporaryDirectory: () async => temporaryDirectory,
        isAndroid: () => true,
      );
      await store.initialize();
      final old = File(
        path.join(
          temporaryDirectory.path,
          'doujin_audio_covers',
          'cover_123.jpg',
        ),
      );
      await old.parent.create(recursive: true);
      await old.writeAsBytes([1]);
      expect(await store.migrateLegacyCaches(), 0);
      expect(await old.readAsBytes(), [1]);
      for (final name in [
        'cover_-2147483648.jpg',
        'video_frame_-2147483648.jpg',
      ]) {
        expect(
          store.isObsoleteAndroidAutomaticPath(
            path.join(temporaryDirectory.path, 'doujin_audio_covers', name),
          ),
          isTrue,
        );
      }
      expect(
        store.isObsoleteAndroidAutomaticPath(
          path.join(
            temporaryDirectory.path,
            'doujin_audio_covers',
            'cover_123.jpg',
          ),
        ),
        isTrue,
      );
      expect(
        store.isObsoleteAndroidAutomaticPath(
          path.join(
            supportDirectory.path,
            'user',
            'doujin_audio_covers',
            'cover_123.jpg',
          ),
        ),
        isFalse,
      );
      expect(
        store.isObsoleteAndroidAutomaticPath(
          path.join(
            temporaryDirectory.path,
            'doujin_audio_covers',
            'video_frame_${'a' * 64}.jpg',
          ),
        ),
        isFalse,
      );
    },
  );

  test(
    'legacy path bindings migrate to equivalent Windows and SAF identities',
    () async {
      final root = Directory(
        path.join(supportDirectory.path, coverArtworkStoreDirectoryName),
      );
      await root.create();
      final index = File(path.join(root.path, coverArtworkStoreIndexFileName));
      await index.writeAsString(
        jsonEncode({
          'version': 1,
          'bindings': {
            r'folder:C:\作品\Cover Folder': 'content://covers/windows',
            'native:content://provider/tree/root/document/root%2Fvoice.flac|10|20':
                'content://covers/saf',
          },
          'legacyAliases': <String, String>{},
        }),
      );
      final store = createStore();
      await store.initialize();
      expect(
        store.resolvedPath('folder:c:/作品/cover folder'),
        'content://covers/windows',
      );
      expect(
        store.resolvedPath(
          'native:content://provider/document/root%2Fvoice.flac|10|20',
        ),
        'content://covers/saf',
      );
      final restarted = createStore();
      await restarted.initialize();
      expect(
        restarted.resolvedPath('folder:c:/作品/cover folder'),
        'content://covers/windows',
      );
      expect((jsonDecode(await index.readAsString()) as Map)['version'], 2);
    },
  );

  test(
    'unchanged bindings and content do not rewrite the index or artifact',
    () async {
      final store = createStore();
      final saved = await store.putBytes(
        logicalKey: 'folder:/work',
        bytes: [1, 2, 3],
      );
      final index = File(
        path.join(store.rootPath!, coverArtworkStoreIndexFileName),
      );
      final marker = DateTime(2000);
      await index.setLastModified(marker);
      await File(saved!).setLastModified(marker);
      await store.bind('folder:/work', saved);
      await store.putBytes(logicalKey: 'folder:/work', bytes: [1, 2, 3]);
      expect(await index.lastModified(), marker);
      expect(await File(saved).lastModified(), marker);
    },
  );

  test('saved artwork is synchronously restored by a new store', () async {
    final first = createStore();
    await first.initialize();

    final saved = await first.putBytes(
      logicalKey: 'remote:https://example.com/cover',
      bytes: const <int>[1, 2, 3, 4],
      namespace: CoverArtworkNamespace.remote,
      fileStem: 'remote-cover',
    );

    final restored = createStore();
    await restored.initialize();

    expect(saved, isNotNull);
    expect(restored.resolvedPath('remote:https://example.com/cover'), saved);
  });

  test('corrupt index is ignored without exposing stale paths', () async {
    final index = File(
      path.join(
        supportDirectory.path,
        coverArtworkStoreDirectoryName,
        coverArtworkStoreIndexFileName,
      ),
    );
    await index.parent.create(recursive: true);
    await index.writeAsString('{invalid');

    final store = createStore();
    await store.initialize();

    expect(store.resolvedPath('missing'), isNull);
  });

  test(
    'old remote validation metadata cannot discard bindings or legacy aliases',
    () async {
      final store = createStore();
      const key = 'remote-cover:https://example.com/cover.png';
      final saved = await store.putBytes(
        logicalKey: key,
        bytes: base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
          '+A8AAQUBAScY42YAAAAASUVORK5CYII=',
        ),
        namespace: CoverArtworkNamespace.remote,
      );
      final index = File(
        path.join(store.rootPath!, coverArtworkStoreIndexFileName),
      );
      final legacyPath = path.join(temporaryDirectory.path, 'old-cover.image');
      final original = jsonDecode(await index.readAsString()) as Map;
      original['legacyAliases'] = {
        sha256.convert(utf8.encode(path.normalize(legacyPath))).toString(): path
            .relative(saved!, from: store.rootPath!),
      };
      for (final validation in <Object>[
        {
          key: {
            'checkedAt': '2026-10-02T00:00:00.000Z',
            'etag': '"old-cover"',
            'lastModified': 'Fri, 02 Oct 2026 00:00:00 GMT',
          },
        },
        {
          key: {'checkedAt': '2026-10-02T00:00:00.000Z', 'etag': 123},
        },
        'malformed metadata',
      ]) {
        await index.writeAsString(
          jsonEncode({...original, 'remoteValidation': validation}),
        );
        final restored = createStore();
        await restored.initialize();
        expect(await restored.validatedPath(key), saved);
        expect(restored.resolveStoredPath(legacyPath), saved);
        await restored.bind('folder:additional', 'content://covers/additional');
        final rewritten = jsonDecode(await index.readAsString()) as Map;
        expect(rewritten['version'], 2);
        expect(rewritten.containsKey('remoteValidation'), isFalse);
        expect(rewritten['bindings'][key], original['bindings'][key]);
        expect(rewritten['legacyAliases'], original['legacyAliases']);
      }
    },
  );

  test('restored synchronous lookups never query the filesystem', () async {
    final store = createStore();
    final saved = await store.putBytes(
      logicalKey: 'track:cold',
      bytes: <int>[1, 2, 3],
    );
    final restored = createStore();
    await restored.initialize();

    IOOverrides.runZoned(() {
      expect(restored.resolvedPath('track:cold'), saved);
      expect(restored.resolveStoredPath(saved), saved);
    }, createFile: (_) => throw StateError('Synchronous cover I/O'));
  });

  test('asynchronous validation retires a missing persisted binding', () async {
    final store = createStore();
    final saved = await store.putBytes(
      logicalKey: 'track:missing',
      bytes: <int>[1, 2, 3],
    );
    await File(saved!).delete();

    expect(store.resolvedPath('track:missing'), saved);
    expect(await store.validatedPath('track:missing'), isNull);
    expect(store.resolvedPath('track:missing'), isNull);
    final restored = createStore();
    await restored.initialize();
    expect(restored.resolvedPath('track:missing'), isNull);
  });

  test('old validation cannot remove a replacement binding', () async {
    final store = createStore();
    await store.initialize();
    final missing = File(path.join(supportDirectory.path, 'missing.jpg'));
    final missingStat = await missing.stat();
    await store.bind('track:rebound', missing.path);
    final stat = Completer<FileStat>();
    final validation = IOOverrides.runZoned(
      () => store.validatedPath('track:rebound'),
      createFile: (value) => _DelayedStatFile(value, stat.future),
    );
    await store.invalidate(<String>['track:rebound']);
    const replacement = 'content://covers/replacement';
    await store.bind('track:rebound', replacement);
    stat.complete(missingStat);

    expect(await validation, isNull);
    expect(store.resolvedPath('track:rebound'), replacement);
    final restored = createStore();
    await restored.initialize();
    expect(restored.resolvedPath('track:rebound'), replacement);
  });

  test(
    'legacy cache files are migrated and old paths remain resolvable',
    () async {
      final legacyDirectory = Directory(
        path.join(temporaryDirectory.path, 'embedded_covers'),
      );
      await legacyDirectory.create(recursive: true);
      final legacy = File(path.join(legacyDirectory.path, 'cover.image'));
      await legacy.writeAsBytes(const <int>[5, 6, 7]);
      final store = createStore();
      await store.initialize();

      final migrated = await store.migrateLegacyCaches();

      expect(migrated, 1);
      final resolved = store.resolveStoredPath(legacy.path);
      expect(resolved, isNotNull);
      expect(resolved, isNot(legacy.path));
      expect(await File(resolved!).readAsBytes(), const <int>[5, 6, 7]);
      expect(await store.migrateLegacyCaches(), 0);
    },
  );

  test('explicit clear removes artifacts and in-memory bindings', () async {
    final store = createStore();
    await store.initialize();
    final saved = await store.putBytes(
      logicalKey: 'track:a',
      bytes: const <int>[9, 8, 7],
    );

    final deleted = await store.clear();

    expect(deleted, 3);
    expect(store.resolvedPath('track:a'), isNull);
    expect(await File(saved!).exists(), isFalse);
  });

  test('clear wins against a write waiting for initialization', () async {
    final support = await Directory.systemTemp.createTemp('cover_store_race_');
    final temporary = await Directory.systemTemp.createTemp(
      'cover_store_race_temp_',
    );
    final source = File('${temporary.path}${Platform.pathSeparator}cover.jpg');
    await source.writeAsBytes(<int>[1, 2, 3]);
    final directoryReady = Completer<Directory>();
    final store = CoverArtworkStore(
      persistentDirectory: () => directoryReady.future,
      temporaryDirectory: () async => temporary,
    );
    addTearDown(() async {
      if (await support.exists()) await support.delete(recursive: true);
      if (await temporary.exists()) await temporary.delete(recursive: true);
    });

    final write = store.putFile(
      logicalKey: 'track:race',
      sourcePath: source.path,
    );
    final clear = store.clear();
    directoryReady.complete(support);

    expect(await write, isNull);
    expect(await clear, 0);
    expect(store.resolvedPath('track:race'), isNull);
  });

  test('identical embedded bytes share one durable artifact', () async {
    final first = File(path.join(temporaryDirectory.path, 'first.jpg'));
    final second = File(path.join(temporaryDirectory.path, 'second.jpg'));
    await first.writeAsBytes(<int>[7, 8, 9]);
    await second.writeAsBytes(<int>[7, 8, 9]);
    final store = CoverArtworkStore(
      persistentDirectory: () async => supportDirectory,
      temporaryDirectory: () async => temporaryDirectory,
    );

    final firstPath = await store.putFile(
      logicalKey: 'embedded:first',
      sourcePath: first.path,
      namespace: CoverArtworkNamespace.embedded,
    );
    final secondPath = await store.putFile(
      logicalKey: 'embedded:second',
      sourcePath: second.path,
      namespace: CoverArtworkNamespace.embedded,
    );

    expect(secondPath, firstPath);
    expect(
      Directory(path.dirname(firstPath!)).listSync().whereType<File>().where(
        (file) => file.path.endsWith('.image'),
      ),
      hasLength(1),
    );
  });

  test('content URI bindings remain synchronous platform paths', () async {
    final store = CoverArtworkStore(
      persistentDirectory: () async => supportDirectory,
      temporaryDirectory: () async => temporaryDirectory,
    );
    await store.initialize();
    await store.bind('folder:saf', 'content://tree/library/cover.jpg');

    expect(
      store.resolvedPath('folder:saf'),
      'content://tree/library/cover.jpg',
    );
  });

  test(
    'invalidation removes binding without deleting reusable bytes',
    () async {
      final store = CoverArtworkStore(
        persistentDirectory: () async => supportDirectory,
        temporaryDirectory: () async => temporaryDirectory,
      );
      final saved = await store.putBytes(
        logicalKey: 'folder:old',
        bytes: <int>[4, 5, 6],
      );

      await store.invalidate(const <String>['folder:old']);

      expect(store.resolvedPath('folder:old'), isNull);
      expect(await File(saved!).exists(), isTrue);
    },
  );

  test('generated artifact ignores temporary bridge touch time', () async {
    final bridge = File(
      path.join(temporaryDirectory.path, 'video-frame.image'),
    );
    await bridge.writeAsBytes(<int>[1, 2, 3]);
    final store = CoverArtworkStore(
      persistentDirectory: () async => supportDirectory,
      temporaryDirectory: () async => temporaryDirectory,
    );

    final first = await store.putFile(
      logicalKey: 'video:/media/work.mp4:100:v3',
      sourcePath: bridge.path,
    );
    await bridge.setLastModified(DateTime(2030));
    final second = await store.putFile(
      logicalKey: 'video:/media/work.mp4:100:v3',
      sourcePath: bridge.path,
    );

    expect(second, first);
  });
}

class _DelayedStatFile implements File {
  _DelayedStatFile(this.path, this._stat);

  @override
  final String path;
  final Future<FileStat> _stat;

  @override
  Future<FileStat> stat() => _stat;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
