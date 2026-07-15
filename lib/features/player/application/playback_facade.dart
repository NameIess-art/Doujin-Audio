import 'dart:async';

import '../../../core/media/music_track.dart';
import '../../../core/persistence/audio_database_repository.dart';
import '../../asmr/application/asmr_playback_cache_service.dart';
import '../domain/playback_mode.dart';
import 'playback_session.dart';
import 'audio_state_services.dart';
import 'native_playback_repository.dart';
import 'playback_command_runner.dart';
import 'system_media_controls_service.dart';

/// Owns playback sessions and the platform playback runtime.
final class PlaybackFacade {
  PlaybackFacade({
    required this.databaseRepository,
    required this.nativeRepository,
    required this.commandRunner,
    required this.playbackCacheService,
    required this.service,
    required this.systemMediaControlsService,
  });

  factory PlaybackFacade.create({
    required AudioDatabaseRepository databaseRepository,
    NativePlaybackRepository? nativeRepository,
    PlaybackCommandRunner commandRunner = const PlaybackCommandRunner(),
    AsmrPlaybackCacheService playbackCacheService =
        const AsmrPlaybackCacheService(),
    PlaybackSessionService? service,
    SystemMediaControlsService? systemMediaControlsService,
  }) {
    return PlaybackFacade(
      databaseRepository: databaseRepository,
      nativeRepository: nativeRepository ?? NativePlaybackRepository(),
      commandRunner: commandRunner,
      playbackCacheService: playbackCacheService,
      service: service ?? PlaybackSessionService(),
      systemMediaControlsService:
          systemMediaControlsService ?? SystemMediaControlsService(),
    );
  }

  final AudioDatabaseRepository databaseRepository;
  final NativePlaybackRepository nativeRepository;
  final PlaybackCommandRunner commandRunner;
  final AsmrPlaybackCacheService playbackCacheService;
  final PlaybackSessionService service;
  final SystemMediaControlsService systemMediaControlsService;
  final StreamController<String> _sessionActivations =
      StreamController<String>.broadcast(sync: true);
  Future<void> Function(
    List<MusicTrack> tracks, {
    bool? autoPlay,
    required SessionLoopMode loopMode,
  })?
  _launchQueue;

  Stream<String> get sessionActivations => _sessionActivations.stream;
  PlaybackStateSliceData get state => service.slice.state;
  Stream<PlaybackStateSliceData> get states => service.slice.stream;
  PlaybackSession? sessionById(String sessionId) =>
      service.sessionById(sessionId);

  void publishSessionActivated(String sessionId) {
    if (sessionId.isEmpty || _sessionActivations.isClosed) return;
    _sessionActivations.add(sessionId);
  }

  void attachSessionLauncher(
    Future<void> Function(
      List<MusicTrack> tracks, {
      bool? autoPlay,
      required SessionLoopMode loopMode,
    })
    launchQueue,
  ) {
    _launchQueue ??= launchQueue;
  }

  Future<void> launchQueue(
    List<MusicTrack> tracks, {
    bool? autoPlay,
    required SessionLoopMode loopMode,
  }) {
    final launch = _launchQueue;
    if (launch == null) {
      throw StateError('PlaybackFacade session launcher is not attached.');
    }
    return launch(tracks, autoPlay: autoPlay, loopMode: loopMode);
  }

  Future<void> dispose() async {
    await _sessionActivations.close();
    await nativeRepository.dispose();
    await service.dispose();
    await systemMediaControlsService.dispose();
  }
}
