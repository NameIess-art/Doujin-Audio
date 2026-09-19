import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/features/player/domain/playback_mode.dart';
import 'package:doujin_audio/features/asmr/application/asmr_playback_coordinator.dart';
import 'package:doujin_audio/features/player/application/playback_session_launcher.dart';

void main() {
  final work = AsmrWork(
    id: 7,
    title: 'Work',
    circleName: 'Circle',
    sourceId: 'RJ000007',
    sourceType: 'asmr-one',
    sourceUrl: '',
    coverUrl: '',
    thumbnailUrl: '',
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
  final target = AsmrTrackFile(
    hash: 'track',
    title: 'Track.mp3',
    type: 'audio',
    streamUrl: 'https://example.test/track.mp3',
    downloadUrl: null,
    lowQualityUrl: null,
    duration: const Duration(seconds: 10),
    size: 100,
    children: const <AsmrTrackFile>[],
    workId: 7,
    workTitle: 'Work',
    sourceId: 'RJ000007',
    relativePath: 'Track.mp3',
  );

  test(
    'work playback launches an ordered folder queue and records history',
    () async {
      final source = _FakeAsmrPlaybackSource(
        workTracks: <MusicTrack>[_track('one'), _track('two')],
      );
      final launcher = _RecordingPlaybackSessionLauncher();
      final coordinator = AsmrPlaybackCoordinator(
        source: source,
        launcher: launcher,
      );

      await coordinator.playWork(work, autoPlay: false);

      expect(source.recordedWorks, <AsmrWork>[work]);
      expect(launcher.tracks.map((track) => track.path), <String>[
        'one',
        'two',
      ]);
      expect(launcher.autoPlay, isFalse);
      expect(launcher.loopMode, SessionLoopMode.folderSequential);
    },
  );

  test('single track playback uses a single-track loop session', () async {
    final source = _FakeAsmrPlaybackSource(
      trackQueue: <MusicTrack>[_track('selected')],
    );
    final launcher = _RecordingPlaybackSessionLauncher();
    final coordinator = AsmrPlaybackCoordinator(
      source: source,
      launcher: launcher,
    );

    await coordinator.playTrack(work, target);

    expect(source.requestedTarget, same(target));
    expect(source.recordedWorks, <AsmrWork>[work]);
    expect(launcher.tracks.single.path, 'selected');
    expect(launcher.loopMode, SessionLoopMode.single);
  });

  test('prebuilt folder tracks use the same history and launch path', () async {
    final source = _FakeAsmrPlaybackSource();
    final launcher = _RecordingPlaybackSessionLauncher();
    final coordinator = AsmrPlaybackCoordinator(
      source: source,
      launcher: launcher,
    );

    await coordinator.playTracks(work, <MusicTrack>[
      _track('folder-one'),
      _track('folder-two'),
    ]);

    expect(source.recordedWorks, <AsmrWork>[work]);
    expect(launcher.tracks.map((track) => track.path), <String>[
      'folder-one',
      'folder-two',
    ]);
    expect(launcher.loopMode, SessionLoopMode.folderSequential);
  });

  test(
    'direct track playback passes the pending work queue to the launcher',
    () async {
      final source = _FakeAsmrPlaybackSource(
        trackQueue: [_track('selected'), _track('next')],
      );
      final launcher = _RecordingPlaybackSessionLauncher();
      final coordinator = AsmrPlaybackCoordinator(
        source: source,
        launcher: launcher,
      );

      expect(await coordinator.playDirectTrack(work, target), isTrue);

      expect(launcher.directCount, 1);
      expect(launcher.launchCount, 0);
      expect(launcher.tracks.map((track) => track.path), ['selected', 'next']);
      expect(source.recordedWorks, [work]);
    },
  );

  test(
    'adding one track only registers that item without playing or recording history',
    () async {
      final source = _FakeAsmrPlaybackSource(
        trackQueue: [_track('selected'), _track('next')],
      );
      final launcher = _RecordingPlaybackSessionLauncher();
      final coordinator = AsmrPlaybackCoordinator(
        source: source,
        launcher: launcher,
      );

      expect(await coordinator.addTrackToPlaylist(work, target), isTrue);

      expect(launcher.addedTrack?.path, 'selected');
      expect(launcher.launchCount, 0);
      expect(launcher.directCount, 0);
      expect(source.recordedWorks, isEmpty);
    },
  );

  test(
    'empty playable result does not update history or launch playback',
    () async {
      final source = _FakeAsmrPlaybackSource();
      final launcher = _RecordingPlaybackSessionLauncher();
      final coordinator = AsmrPlaybackCoordinator(
        source: source,
        launcher: launcher,
      );

      await coordinator.playWork(work);

      expect(source.recordedWorks, isEmpty);
      expect(launcher.launchCount, 0);
    },
  );
}

MusicTrack _track(String path) => MusicTrack(
  path: path,
  displayName: path,
  groupKey: 'group',
  groupTitle: 'Work',
  groupSubtitle: '',
  isSingle: false,
);

class _FakeAsmrPlaybackSource implements AsmrPlaybackSource {
  _FakeAsmrPlaybackSource({
    this.workTracks = const <MusicTrack>[],
    this.trackQueue = const <MusicTrack>[],
  });

  final List<MusicTrack> workTracks;
  final List<MusicTrack> trackQueue;
  final List<AsmrWork> recordedWorks = <AsmrWork>[];
  AsmrTrackFile? requestedTarget;

  @override
  Future<MusicTrack?> loadPlayableTrack(
    AsmrWork work,
    AsmrTrackFile target,
  ) async => trackQueue.firstOrNull;

  @override
  Future<List<MusicTrack>> loadPlayableTracks(AsmrWork work) async =>
      workTracks;

  @override
  Future<List<MusicTrack>> loadPlayableTracksStartingAt(
    AsmrWork work,
    AsmrTrackFile target,
  ) async {
    requestedTarget = target;
    return trackQueue;
  }

  @override
  Future<void> recordHistory(AsmrWork work) async {
    recordedWorks.add(work);
  }
}

class _RecordingPlaybackSessionLauncher implements PlaybackSessionLauncher {
  int launchCount = 0;
  int directCount = 0;
  MusicTrack? addedTrack;
  List<MusicTrack> tracks = const <MusicTrack>[];
  bool? autoPlay;
  SessionLoopMode? loopMode;

  @override
  Future<bool> playDirect(
    FutureOr<List<MusicTrack>> tracks, {
    int startIndex = 0,
    SessionLoopMode loopMode = SessionLoopMode.folderSequential,
  }) async {
    directCount++;
    this.tracks = await tracks;
    this.loopMode = loopMode;
    return this.tracks.isNotEmpty;
  }

  @override
  Future<bool> addTrackToPlaylist(MusicTrack track) async {
    addedTrack = track;
    return true;
  }

  @override
  Future<bool> launchQueue(
    List<MusicTrack> tracks, {
    bool? autoPlay,
    required SessionLoopMode loopMode,
  }) async {
    launchCount += 1;
    this.tracks = tracks;
    this.autoPlay = autoPlay;
    this.loopMode = loopMode;
    return true;
  }
}
