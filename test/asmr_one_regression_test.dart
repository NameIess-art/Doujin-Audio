import 'support/asmr_controller_test_fixture.dart';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';
import 'package:doujin_audio/core/persistence/app_database.dart';
import 'package:doujin_audio/features/asmr/application/asmr_preferences.dart';
import 'package:doujin_audio/infrastructure/sqlite/sqlite_asmr_repository.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/features/player/application/playback_subtitle_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('ASMR work persists and restores card fields', () {
    final original = AsmrWork.fromJson(const <String, dynamic>{
      'id': 416816,
      'title': '二人的安眠诱导',
      'name': 'Circle Demo',
      'source_id': 'RJ416816',
      'source_type': 'DLSITE',
      'source_url':
          'https://www.dlsite.com/home/work/=/product_id/RJ416816.html',
      'samCoverUrl': 'https://example.com/sam.jpg',
      'thumbnailCoverUrl': 'https://example.com/thumb.jpg',
      'mainCoverUrl': 'https://example.com/main.jpg',
      'release': '2022-09-26T00:00:00.000Z',
      'create_date': '2022-09-26T01:00:00.000Z',
      'duration': 560.811,
      'dl_count': 1234,
      'review_count': 56,
      'rate_average_2dp': 4.8,
      'vas': <Map<String, String>>[
        <String, String>{'name': 'Voice A'},
      ],
      'tags': <Map<String, String>>[
        <String, String>{'name': '催眠'},
        <String, String>{'name': '双耳'},
      ],
      'has_subtitle': true,
      'isFavorite': true,
    });

    final restored = AsmrWork.fromJson(
      Map<String, dynamic>.from(original.toJson()),
    );

    expect(restored.title, original.title);
    expect(restored.circleName, original.circleName);
    expect(restored.sourceId, original.sourceId);
    expect(restored.coverUrl, original.coverUrl);
    expect(restored.thumbnailUrl, original.thumbnailUrl);
    expect(restored.mainCoverUrl, original.mainCoverUrl);
    expect(restored.duration, original.duration);
    expect(restored.dlCount, original.dlCount);
    expect(restored.reviewCount, original.reviewCount);
    expect(restored.rating, original.rating);
    expect(restored.voiceActors, original.voiceActors);
    expect(restored.tags, original.tags);
    expect(restored.hasSubtitle, isTrue);
    expect(restored.isFavorite, isTrue);
  });

  test(
    'ASMR work preferred cover uses main cover then cover then thumbnail',
    () {
      final withMain = AsmrWork(
        id: 1,
        title: 'Work',
        circleName: 'Circle',
        sourceId: 'RJ1',
        sourceType: 'DLSITE',
        sourceUrl: 'https://example.com/work',
        coverUrl: 'https://example.com/cover.jpg',
        thumbnailUrl: 'https://example.com/thumb.jpg',
        mainCoverUrl: ' https://example.com/main.jpg ',
        releaseDate: null,
        createDate: null,
        duration: Duration.zero,
        dlCount: 0,
        reviewCount: 0,
        rating: 0,
        voiceActors: const <String>[],
        tags: const <String>[],
      );
      final withCover = AsmrWork(
        id: 2,
        title: 'Work',
        circleName: 'Circle',
        sourceId: 'RJ2',
        sourceType: 'DLSITE',
        sourceUrl: 'https://example.com/work',
        coverUrl: ' https://example.com/cover.jpg ',
        thumbnailUrl: 'https://example.com/thumb.jpg',
        mainCoverUrl: '',
        releaseDate: null,
        createDate: null,
        duration: Duration.zero,
        dlCount: 0,
        reviewCount: 0,
        rating: 0,
        voiceActors: const <String>[],
        tags: const <String>[],
      );
      final withThumb = AsmrWork(
        id: 3,
        title: 'Work',
        circleName: 'Circle',
        sourceId: 'RJ3',
        sourceType: 'DLSITE',
        sourceUrl: 'https://example.com/work',
        coverUrl: '',
        thumbnailUrl: ' https://example.com/thumb.jpg ',
        mainCoverUrl: '',
        releaseDate: null,
        createDate: null,
        duration: Duration.zero,
        dlCount: 0,
        reviewCount: 0,
        rating: 0,
        voiceActors: const <String>[],
        tags: const <String>[],
      );

      expect(withMain.preferredCoverUrl, 'https://example.com/main.jpg');
      expect(withCover.preferredCoverUrl, 'https://example.com/cover.jpg');
      expect(withThumb.preferredCoverUrl, 'https://example.com/thumb.jpg');
    },
  );

  test('ASMR playable tracks inherit matched subtitle metadata', () {
    final work = AsmrWork(
      id: 416816,
      title: '二人的安眠诱导',
      circleName: 'Circle Demo',
      sourceId: 'RJ416816',
      sourceType: 'DLSITE',
      sourceUrl: 'https://example.com/work',
      coverUrl: 'https://example.com/cover.jpg',
      thumbnailUrl: 'https://example.com/thumb.jpg',
      mainCoverUrl: 'https://example.com/main.jpg',
      releaseDate: null,
      createDate: null,
      duration: Duration.zero,
      dlCount: 0,
      reviewCount: 0,
      rating: 0,
      voiceActors: const <String>[],
      tags: const <String>[],
      hasSubtitle: true,
    );
    final folder = AsmrTrackFile(
      hash: '',
      title: '01_mp3',
      type: 'folder',
      streamUrl: null,
      downloadUrl: null,
      lowQualityUrl: null,
      duration: Duration.zero,
      size: 0,
      workId: 416816,
      workTitle: '二人的安眠诱导',
      sourceId: 'RJ416816',
      relativePath: '01_mp3',
      children: <AsmrTrackFile>[
        AsmrTrackFile(
          hash: 'subtitle',
          title: 'track.lrc',
          type: 'text',
          streamUrl: 'http://127.0.0.1/subtitle',
          downloadUrl: 'http://127.0.0.1/subtitle',
          lowQualityUrl: null,
          duration: Duration.zero,
          size: 10,
          workId: 416816,
          workTitle: '二人的安眠诱导',
          sourceId: 'RJ416816',
          relativePath: '01_mp3/track.lrc',
          children: const <AsmrTrackFile>[],
        ),
        AsmrTrackFile(
          hash: 'audio',
          title: 'track.mp3',
          type: 'audio',
          streamUrl: 'http://127.0.0.1/track.mp3',
          downloadUrl: 'http://127.0.0.1/track.mp3',
          lowQualityUrl: null,
          duration: const Duration(seconds: 10),
          size: 100,
          workId: 416816,
          workTitle: '二人的安眠诱导',
          sourceId: 'RJ416816',
          relativePath: '01_mp3/track.mp3',
          children: const <AsmrTrackFile>[],
        ),
      ],
    );

    final controller = createTestAsmrController(
      preferencesStore: AsmrPreferencesStore(
        repository: SqliteAsmrRepository(database: AppDatabase.instance),
      ),
      persistenceRepository: SqliteAsmrRepository(
        database: AppDatabase.instance,
      ),
    );
    final tracks = controller.buildPlayableTracksFromNode(work, folder);

    expect(tracks, hasLength(1));
    expect(tracks.single.remoteMetadataKind, 'asmr.one');
    expect(tracks.single.remoteCoverUrl, 'https://example.com/main.jpg');
    expect(
      tracks.single.remoteMetadata?['subtitleUrl'],
      'http://127.0.0.1/subtitle',
    );
    expect(tracks.single.remoteMetadata?['subtitleExtension'], '.lrc');
    expect(
      tracks.single.remoteMetadata?['subtitleSourcePath'],
      '01_mp3/track.lrc',
    );
  });

  test('ASMR playable tracks match double-extension subtitle files', () {
    final work = AsmrWork(
      id: 416816,
      title: '浜屼汉鐨勫畨鐪犺瀵?',
      circleName: 'Circle Demo',
      sourceId: 'RJ416816',
      sourceType: 'DLSITE',
      sourceUrl: 'https://example.com/work',
      coverUrl: 'https://example.com/cover.jpg',
      thumbnailUrl: 'https://example.com/thumb.jpg',
      mainCoverUrl: 'https://example.com/main.jpg',
      releaseDate: null,
      createDate: null,
      duration: Duration.zero,
      dlCount: 0,
      reviewCount: 0,
      rating: 0,
      voiceActors: const <String>[],
      tags: const <String>[],
      hasSubtitle: true,
    );
    final folder = AsmrTrackFile(
      hash: '',
      title: '01_mp3',
      type: 'folder',
      streamUrl: null,
      downloadUrl: null,
      lowQualityUrl: null,
      duration: Duration.zero,
      size: 0,
      workId: 416816,
      workTitle: '浜屼汉鐨勫畨鐪犺瀵?',
      sourceId: 'RJ416816',
      relativePath: '01_mp3',
      children: <AsmrTrackFile>[
        AsmrTrackFile(
          hash: 'subtitle',
          title: 'track.mp3.vtt',
          type: 'text',
          streamUrl: 'http://127.0.0.1/subtitle',
          downloadUrl: 'http://127.0.0.1/subtitle',
          lowQualityUrl: null,
          duration: Duration.zero,
          size: 10,
          workId: 416816,
          workTitle: '浜屼汉鐨勫畨鐪犺瀵?',
          sourceId: 'RJ416816',
          relativePath: '01_mp3/track.mp3.vtt',
          children: const <AsmrTrackFile>[],
        ),
        AsmrTrackFile(
          hash: 'audio',
          title: 'track.mp3',
          type: 'audio',
          streamUrl: 'http://127.0.0.1/track.mp3',
          downloadUrl: 'http://127.0.0.1/track.mp3',
          lowQualityUrl: null,
          duration: const Duration(seconds: 10),
          size: 100,
          workId: 416816,
          workTitle: '浜屼汉鐨勫畨鐪犺瀵?',
          sourceId: 'RJ416816',
          relativePath: '01_mp3/track.mp3',
          children: const <AsmrTrackFile>[],
        ),
      ],
    );

    final controller = createTestAsmrController(
      preferencesStore: AsmrPreferencesStore(
        repository: SqliteAsmrRepository(database: AppDatabase.instance),
      ),
      persistenceRepository: SqliteAsmrRepository(
        database: AppDatabase.instance,
      ),
    );
    final tracks = controller.buildPlayableTracksFromNode(work, folder);

    expect(tracks, hasLength(1));
    expect(tracks.single.remoteMetadataKind, 'asmr.one');
    expect(tracks.single.remoteMetadata?['subtitleUrl'], isNotNull);
    expect(tracks.single.remoteMetadata?['subtitleExtension'], '.vtt');
    expect(
      tracks.single.remoteMetadata?['subtitleSourcePath'],
      '01_mp3/track.mp3.vtt',
    );
  });

  test(
    'remote ASMR subtitles are cached and reloaded from local files',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      HttpOverrides.global = null;
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final directory = await Directory.systemTemp.createTemp(
        'asmr_subtitles_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });
      server.listen((request) async {
        request.response.headers.contentType = ContentType.text;
        request.response.write('[00:01.00]第一句\n[00:02.00]第二句');
        await request.response.close();
      });

      final audioPath =
          'http://${server.address.host}:${server.port}/audio.mp3';
      final track = MusicTrack(
        path: audioPath,
        displayName: 'audio.mp3',
        groupKey: 'asmr-work-1',
        groupTitle: 'Work',
        groupSubtitle: '',
        isSingle: false,
        remoteMetadataKind: 'asmr.one',
        remoteMetadata: {
          'subtitleUrl':
              'http://${server.address.host}:${server.port}/track-subtitle',
          'subtitleExtension': '.lrc',
        },
      );
      PlaybackSubtitleService createService() => PlaybackSubtitleService(
        trackResolver: (_) => track,
        subtitlesDirectoryResolver: () async => directory,
      );
      final subtitleTrack = await createService().load(audioPath);

      expect(subtitleTrack, isNotNull);
      expect(subtitleTrack!.cues, hasLength(2));
      expect(subtitleTrack.cues.first.text, '第一句');
      expect(subtitleTrack.cues.last.text, '第二句');
      expect(await File(subtitleTrack.sourcePath).exists(), isTrue);
      await server.close(force: true);
      final offline = await createService().load(audioPath);
      expect(offline?.sourcePath, subtitleTrack.sourcePath);
      expect(offline?.cues.last.text, '第二句');
    },
  );
}
