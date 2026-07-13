import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/models/asmr_models.dart';
import 'package:nameless_audio/models/music_track.dart';
import 'package:nameless_audio/models/playback_mode.dart';
import 'package:nameless_audio/services/asmr_playback_coordinator.dart';
import 'package:nameless_audio/services/playback_session_launcher.dart';

void main() {
  const work = AsmrWork(
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
    voiceActors: <String>[],
    tags: <String>[],
  );
  const target = AsmrTrackFile(
    hash: 'track',
    title: 'Track.mp3',
    type: 'audio',
    streamUrl: 'https://example.test/track.mp3',
    downloadUrl: null,
    lowQualityUrl: null,
    duration: Duration(seconds: 10),
    size: 100,
    children: <AsmrTrackFile>[],
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
  List<MusicTrack> tracks = const <MusicTrack>[];
  bool? autoPlay;
  SessionLoopMode? loopMode;

  @override
  Future<void> launchQueue(
    List<MusicTrack> tracks, {
    bool? autoPlay,
    required SessionLoopMode loopMode,
  }) async {
    launchCount += 1;
    this.tracks = tracks;
    this.autoPlay = autoPlay;
    this.loopMode = loopMode;
  }
}
