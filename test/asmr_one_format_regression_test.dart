// ignore_for_file: prefer_const_literals_to_create_immutables, prefer_const_constructors

import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/models/asmr_models.dart';
import 'package:nameless_audio/services/asmr_library_controller.dart';

void main() {
  test(
    'ASMR matches URL-based subtitle extensions even when titles omit suffixes',
    () {
      const work = AsmrWork(
        id: 1,
        title: 'Work',
        circleName: 'Circle',
        sourceId: 'RJ000001',
        sourceType: 'DLSITE',
        sourceUrl: 'https://example.com/work',
        coverUrl: '',
        thumbnailUrl: '',
        mainCoverUrl: '',
        releaseDate: null,
        createDate: null,
        duration: Duration.zero,
        dlCount: 0,
        reviewCount: 0,
        rating: 0,
        voiceActors: <String>[],
        tags: <String>[],
      );
      final controller = AsmrLibraryController();

      for (final extension in <String>['.vtt', '.srt', '.ass', '.ssa']) {
        final folder = AsmrTrackFile(
          hash: '',
          title: '01_mp3',
          type: 'folder',
          streamUrl: null,
          downloadUrl: null,
          lowQualityUrl: null,
          duration: Duration.zero,
          size: 0,
          children: <AsmrTrackFile>[
            AsmrTrackFile(
              hash: extension,
              title: 'scene',
              type: 'other',
              streamUrl: 'https://example.com/scene$extension',
              downloadUrl: 'https://example.com/scene$extension',
              lowQualityUrl: null,
              duration: Duration.zero,
              size: 10,
              children: <AsmrTrackFile>[],
              workId: 1,
              workTitle: 'Work',
              sourceId: 'RJ000001',
              relativePath: '01_mp3/scene',
            ),
            AsmrTrackFile(
              hash: 'mp3',
              title: 'scene.mp3',
              type: 'audio',
              streamUrl: 'https://example.com/scene.mp3',
              downloadUrl: 'https://example.com/scene.mp3',
              lowQualityUrl: null,
              duration: Duration.zero,
              size: 12,
              children: <AsmrTrackFile>[],
              workId: 1,
              workTitle: 'Work',
              sourceId: 'RJ000001',
              relativePath: '01_mp3/scene.mp3',
            ),
          ],
          workId: 1,
          workTitle: 'Work',
          sourceId: 'RJ000001',
          relativePath: '01_mp3',
        );

        final tracks = controller.buildPlayableTracksFromNode(work, folder);

        expect(tracks, hasLength(1));
        expect(tracks.single.displayName, 'scene');
        expect(
          tracks.single.remoteMetadata?['subtitleUrl'],
          contains(extension),
        );
        expect(tracks.single.remoteMetadata?['subtitleExtension'], extension);
      }
    },
  );

  test('ASMR matches double-extension subtitle filenames to audio tracks', () {
    const work = AsmrWork(
      id: 2,
      title: 'Work 2',
      circleName: 'Circle',
      sourceId: 'RJ000002',
      sourceType: 'DLSITE',
      sourceUrl: 'https://example.com/work2',
      coverUrl: '',
      thumbnailUrl: '',
      mainCoverUrl: '',
      releaseDate: null,
      createDate: null,
      duration: Duration.zero,
      dlCount: 0,
      reviewCount: 0,
      rating: 0,
      voiceActors: <String>[],
      tags: <String>[],
    );
    final controller = AsmrLibraryController();

    for (final extension in <String>['.vtt', '.srt', '.ass', '.ssa']) {
      final folder = AsmrTrackFile(
        hash: '',
        title: '01_mp3',
        type: 'folder',
        streamUrl: null,
        downloadUrl: null,
        lowQualityUrl: null,
        duration: Duration.zero,
        size: 0,
        children: <AsmrTrackFile>[
          AsmrTrackFile(
            hash: extension,
            title: 'scene.mp3$extension',
            type: 'other',
            streamUrl: 'https://example.com/scene.mp3$extension',
            downloadUrl: 'https://example.com/scene.mp3$extension',
            lowQualityUrl: null,
            duration: Duration.zero,
            size: 10,
            children: <AsmrTrackFile>[],
            workId: 2,
            workTitle: 'Work 2',
            sourceId: 'RJ000002',
            relativePath: '01_mp3/scene.mp3$extension',
          ),
          AsmrTrackFile(
            hash: 'mp3',
            title: 'scene.mp3',
            type: 'audio',
            streamUrl: 'https://example.com/scene.mp3',
            downloadUrl: 'https://example.com/scene.mp3',
            lowQualityUrl: null,
            duration: Duration.zero,
            size: 12,
            children: <AsmrTrackFile>[],
            workId: 2,
            workTitle: 'Work 2',
            sourceId: 'RJ000002',
            relativePath: '01_mp3/scene.mp3',
          ),
        ],
        workId: 2,
        workTitle: 'Work 2',
        sourceId: 'RJ000002',
        relativePath: '01_mp3',
      );

      final tracks = controller.buildPlayableTracksFromNode(work, folder);

      expect(tracks, hasLength(1));
      expect(tracks.single.remoteMetadata?['subtitleUrl'], contains(extension));
      expect(
        tracks.single.remoteMetadata?['subtitleSourcePath'],
        '01_mp3/scene.mp3$extension',
      );
    }
  });

  test('ASMR only treats whitelisted audio file extensions as playable', () {
    const audioNode = AsmrTrackFile(
      hash: 'mp3',
      title: 'track.mp3',
      type: 'audio',
      streamUrl: 'https://example.com/track.mp3',
      downloadUrl: 'https://example.com/track.mp3',
      lowQualityUrl: null,
      duration: Duration.zero,
      size: 1,
      children: <AsmrTrackFile>[],
      workId: 1,
      workTitle: 'Work',
      sourceId: 'RJ000001',
      relativePath: 'track.mp3',
    );
    const imageNode = AsmrTrackFile(
      hash: 'jpg',
      title: 'cover.jpg',
      type: 'audio',
      streamUrl: 'https://example.com/cover.jpg',
      downloadUrl: 'https://example.com/cover.jpg',
      lowQualityUrl: null,
      duration: Duration.zero,
      size: 1,
      children: <AsmrTrackFile>[],
      workId: 1,
      workTitle: 'Work',
      sourceId: 'RJ000001',
      relativePath: 'cover.jpg',
    );
    const textNode = AsmrTrackFile(
      hash: 'txt',
      title: 'readme.txt',
      type: 'text',
      streamUrl: 'https://example.com/readme.txt',
      downloadUrl: 'https://example.com/readme.txt',
      lowQualityUrl: null,
      duration: Duration.zero,
      size: 1,
      children: <AsmrTrackFile>[],
      workId: 1,
      workTitle: 'Work',
      sourceId: 'RJ000001',
      relativePath: 'readme.txt',
    );

    expect(audioNode.isAudio, isTrue);
    expect(audioNode.displayTitle, 'track');
    expect(imageNode.isAudio, isFalse);
    expect(textNode.isAudio, isFalse);
    expect(textNode.hasBrowsableContent, isFalse);
  });
}
