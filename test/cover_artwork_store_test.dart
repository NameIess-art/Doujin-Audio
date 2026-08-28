import 'dart:async';
import 'dart:io';

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
}
