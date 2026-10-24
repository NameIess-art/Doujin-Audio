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
  Object? error;
  Object? mediaError;
  bool empty = false;

  @override
  Future<List<AsmrTrackFile>> fetchTrackTree(
    int id, {
    String? token,
    AsmrRequestCancellationToken? cancellationToken,
  }) async {
    calls++;
    if (error != null) throw error!;
    if (empty) return [];
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
    if (mediaError != null) throw mediaError!;
  }
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
}
