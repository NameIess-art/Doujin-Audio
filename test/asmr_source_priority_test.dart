import 'dart:async';
import 'dart:io';

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
  int searchCalls = 0;
  int mediaProbeCalls = 0;
  Object? error;
  List<AsmrWork> searchResults = const [];
  Object? mediaError;
  bool empty = false;
  List<AsmrTrackFile>? customTree;
  Future<void> Function(
    String url,
    AsmrRequestCancellationToken? cancellationToken,
  )?
  onVerifyMediaStream;

  @override
  Future<AsmrWorkPage> searchWorks({
    required String keyword,
    required String order,
    required String sort,
    int page = 1,
    int pageSize = 40,
    String? token,
    AsmrContentLanguage language = AsmrContentLanguage.zh,
    AsmrRequestCancellationToken? cancellationToken,
  }) async {
    searchCalls++;
    if (error case final failure?) throw failure;
    return AsmrWorkPage(
      works: searchResults,
      currentPage: page,
      pageSize: pageSize,
      totalCount: searchResults.length,
    );
  }

  @override
  Future<List<AsmrTrackFile>> fetchTrackTree(
    int id, {
    String? token,
    AsmrRequestCancellationToken? cancellationToken,
  }) async {
    calls++;
    if (error != null) throw error!;
    if (empty) return [];
    if (customTree != null) return customTree!;
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
  }) async {
    mediaProbeCalls++;
    if (onVerifyMediaStream != null) {
      await onVerifyMediaStream!(url, cancellationToken);
      return;
    }
    if (mediaError != null) throw mediaError!;
  }
}

class _Japanese extends JapaneseAsmrApiService {
  Object? error;
  int calls = 0;
  int searchCalls = 0;
  List<AsmrWork> searchResults = const [];

  @override
  Future<AsmrWorkPage> searchWorks({
    required String keyword,
    int page = 1,
    int pageSize = 40,
    AsmrRequestCancellationToken? cancellationToken,
  }) async {
    searchCalls++;
    if (error case final failure?) throw failure;
    return AsmrWorkPage(
      works: searchResults,
      currentPage: page,
      pageSize: pageSize,
      totalCount: searchResults.length,
    );
  }

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

  test('RJ lookup retries ONE if Japanese fails during ONE cooldown', () async {
    Future<AsmrWork?> lookup() => catalog.findWorkByRjCode(
      work.rjCode,
      language: AsmrContentLanguage.zh,
      token: null,
    );
    final japaneseWork = AsmrWork.fromJson(const {
      'id': 1,
      'sourceId': 'RJ000001',
      'title': 'Japanese work',
    });
    japanese.searchResults = [japaneseWork];
    one.error = const SocketException('ONE temporarily unavailable');
    expect(await lookup(), same(japaneseWork));

    one.error = null;
    one.searchResults = [work];
    japanese.error = const SocketException('Japanese unavailable');
    expect(await lookup(), same(work));
    expect(one.searchCalls, 2);
    expect(japanese.searchCalls, 2);
  });

  test('ONE always supplies an available directory first', () async {
    final tree = await catalog.loadTrackTree(work, token: null);
    expect(tree.single.title, 'one.m4a');
    expect(one.calls, 1);
    expect(japanese.calls, 0);
  });

  test(
    'ONE directory failure falls back to Japanese and preserves identity',
    () async {
      one.error = const HttpException('Unavailable');
      final key = work.workKey;
      final tree = await catalog.loadTrackTree(work, token: null);
      expect(tree.single.title, 'japanese.m4a');
      expect(one.calls, 1);
      expect(japanese.calls, 1);
      expect(work.workKey, key);
    },
  );

  test('an empty ONE directory falls back to Japanese', () async {
    one.empty = true;
    final tree = await catalog.loadTrackTree(work, token: null);
    expect(tree.single.title, 'japanese.m4a');
    expect(one.calls, 1);
    expect(japanese.calls, 1);
  });

  test('unavailable ONE media falls back to Japanese', () async {
    one.mediaError = const HttpException('Media unavailable');
    final tree = await catalog.loadTrackTree(work, token: null);
    expect(tree.single.title, 'japanese.m4a');
    expect(one.calls, 1);
    expect(japanese.calls, 1);
  });

  test('cancelled ONE request never starts the fallback source', () async {
    one.error = const AsmrRequestCancelled();
    await expectLater(
      catalog.loadTrackTree(work, token: null),
      throwsA(isA<AsmrRequestCancelled>()),
    );
    expect(one.calls, 1);
    expect(japanese.calls, 0);
  });

  test('failure of both sources preserves the initial ONE error', () async {
    const error = HttpException('ONE unavailable');
    one.error = error;
    japanese.error = const HttpException('Japanese unavailable');
    await expectLater(
      catalog.loadTrackTree(work, token: null),
      throwsA(same(error)),
    );
    expect(one.calls, 1);
    expect(japanese.calls, 1);
  });

  test(
    'media host health cache skips redundant probes within TTL and refreshes after expiry',
    () async {
      var now = DateTime.utc(2026, 11, 22, 12);
      final cachedCatalog = AsmrRemoteCatalogService(
        apiService: one,
        japaneseApiService: japanese,
        persistenceRepository: _UnusedPersistence(),
        now: () => now,
      );

      // Healthy host is cached for 60 seconds.
      await cachedCatalog.loadTrackTree(work, token: null);
      await cachedCatalog.loadTrackTree(work, token: null);
      expect(one.mediaProbeCalls, 1);
      expect(japanese.calls, 0);

      // After 61 seconds, host health expires and probes again.
      now = now.add(const Duration(seconds: 61));
      one.mediaError = const HttpException('Media unavailable');
      final fallback1 = await cachedCatalog.loadTrackTree(work, token: null);
      expect(fallback1.single.title, 'japanese.m4a');
      expect(one.mediaProbeCalls, 2);
      expect(japanese.calls, 1);

      // Unhealthy host skips probe within TTL and falls back immediately.
      final fallback2 = await cachedCatalog.loadTrackTree(work, token: null);
      expect(fallback2.single.title, 'japanese.m4a');
      expect(one.mediaProbeCalls, 2);
      expect(japanese.calls, 2);
    },
  );

  test(
    'media probe races multiple candidates concurrently and cancels slower losers',
    () async {
      final slowCancelled = Completer<void>();
      final fastReady = Completer<void>();
      one.customTree = [
        AsmrTrackFile.fromJson(const {
          'type': 'audio',
          'title': 'one.m4a',
          'mediaStreamUrl': 'https://slow.example/one.m4a',
          'mediaDownloadUrl': 'https://fast.example/one.m4a',
        }),
      ];
      one.onVerifyMediaStream = (url, token) async {
        if (url.contains('slow.example')) {
          token?.addListener(() {
            if (!slowCancelled.isCompleted) slowCancelled.complete();
          });
          if (!fastReady.isCompleted) fastReady.complete();
          final blocker = Completer<void>();
          await token?.waitFor(blocker.future);
          return;
        }
        await fastReady.future;
      };

      final tree = await catalog.loadTrackTree(work, token: null);
      expect(tree.single.title, 'one.m4a');
      expect(one.mediaProbeCalls, 2);
      await slowCancelled.future.timeout(const Duration(seconds: 1));
    },
  );
}
