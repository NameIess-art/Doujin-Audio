import 'dart:io';
import 'dart:async';
import 'package:doujin_audio/features/asmr/application/asmr_library_controller.dart';
import 'package:doujin_audio/features/asmr/application/asmr_account_sync_service.dart';
import 'package:doujin_audio/features/asmr/application/asmr_auth_service.dart';
import 'package:doujin_audio/features/asmr/application/asmr_preferences.dart';

import 'package:doujin_audio/features/asmr/application/asmr_api_service.dart';
import 'package:doujin_audio/features/asmr/application/asmr_remote_catalog_service.dart';
import 'package:doujin_audio/features/asmr/application/japanese_asmr_api_service.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_persistence_repository.dart';
import 'package:flutter_test/flutter_test.dart';

class _UnusedPersistence implements AsmrPersistenceRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _One extends AsmrApiService {
  int calls = 0;
  Future<void> Function()? beforeTree;
  @override
  Future<List<AsmrTrackFile>> fetchTrackTree(
    int id, {
    String? token,
    AsmrRequestCancellationToken? cancellationToken,
  }) async {
    calls++;
    await beforeTree?.call();
    return [
      AsmrTrackFile.fromJson(const {
        'type': 'audio',
        'title': 'one.m4a',
        'mediaStreamUrl': 'https://example.com/one.m4a',
      }),
    ];
  }

  @override
  Future<void> verifyMediaStream(
    String url, {
    AsmrRequestCancellationToken? cancellationToken,
  }) async {}
}

class _Japanese extends JapaneseAsmrApiService {
  Object? error;
  int calls = 0;
  @override
  Future<List<AsmrTrackFile>> fetchTrackTree(
    AsmrWork work, {
    AsmrRequestCancellationToken? cancellationToken,
  }) async {
    calls++;
    if (error != null) throw error!;
    return [
      AsmrTrackFile.fromJson(const {
        'type': 'audio',
        'title': 'japanese.m4a',
        'mediaStreamUrl': 'https://example.com/japanese.m4a',
      }),
    ];
  }
}

void main() {
  late _One one;
  late _Japanese japanese;
  late AsmrRemoteCatalogService catalog;
  final work = AsmrWork.fromJson(const {
    'id': 1,
    'sourceId': 'RJ000001',
    'title': 'Work',
  });
  setUp(() {
    one = _One();
    japanese = _Japanese();
    catalog = AsmrRemoteCatalogService(
      apiService: one,
      japaneseApiService: japanese,
      persistenceRepository: _UnusedPersistence(),
    );
  });
  tearDown(() {
    one.close();
    japanese.close();
  });

  test('ONE remains the default directory source', () async {
    final tree = await catalog.loadTrackTree(work, token: null);
    expect(tree.single.title, 'one.m4a');
    expect(one.calls, 1);
    expect(japanese.calls, 0);
  });

  test(
    'Japanese priority changes directory source and preserves work identity',
    () async {
      catalog.preferredSource = () => AsmrCatalogSource.japaneseAsmr;
      final key = work.workKey;
      final tree = await catalog.loadTrackTree(work, token: null);
      expect(tree.single.title, 'japanese.m4a');
      expect(japanese.calls, 1);
      expect(one.calls, 0);
      expect(work.workKey, key);
    },
  );

  test('Japanese directory failure falls back to ONE', () async {
    catalog.preferredSource = () => AsmrCatalogSource.japaneseAsmr;
    japanese.error = const HttpException('Unavailable');
    final tree = await catalog.loadTrackTree(work, token: null);
    expect(tree.single.title, 'one.m4a');
    expect(japanese.calls, 1);
    expect(one.calls, 1);
  });

  AsmrLibraryController controller() {
    final preferences = AsmrPreferencesStore(repository: _UnusedPersistence());
    final controller = AsmrLibraryController(
      preferencesStore: preferences,
      remoteCatalogService: catalog,
      accountSyncService: AsmrAccountSyncService(
        apiService: one,
        authService: AsmrAuthService(apiService: one),
        preferencesStore: preferences,
      ),
    );
    addTearDown(controller.dispose);
    return controller;
  }

  test(
    'source invalidation drops cached trees and reloads the selected source',
    () async {
      final library = controller();
      final first = await library.ensureTrackTree(work);
      expect(first.single.title, 'one.m4a');
      expect(await library.ensureTrackTree(work), same(first));
      catalog.preferredSource = () => AsmrCatalogSource.japaneseAsmr;
      library.invalidateResourceSource();
      final second = await library.ensureTrackTree(work);
      expect(second.single.title, 'japanese.m4a');
      expect(one.calls, 1);
      expect(japanese.calls, 1);
    },
  );

  test(
    'source invalidation retries a pending tree without publishing stale data',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      one.beforeTree = () async {
        entered.complete();
        await release.future;
      };
      final library = controller();
      final pending = library.ensureTrackTree(work);
      await entered.future;
      catalog.preferredSource = () => AsmrCatalogSource.japaneseAsmr;
      library.invalidateResourceSource();
      final tree = await pending;
      expect(tree.single.title, 'japanese.m4a');
      release.complete();
      await Future<void>.delayed(Duration.zero);
      expect(library.trackTreeFor(work.workKey)!.single.title, 'japanese.m4a');
    },
  );

  test('cancelled preferred source never retries another source', () async {
    catalog.preferredSource = () => AsmrCatalogSource.japaneseAsmr;
    japanese.error = const AsmrRequestCancelled();
    await expectLater(
      catalog.loadTrackTree(work, token: null),
      throwsA(isA<AsmrRequestCancelled>()),
    );
    expect(one.calls, 0);
  });
}
