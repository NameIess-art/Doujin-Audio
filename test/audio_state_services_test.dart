import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:nameless_audio/models/music_track.dart';
import 'package:nameless_audio/models/playback_mode.dart';
import 'package:nameless_audio/models/playback_session.dart';
import 'package:nameless_audio/services/audio_state_services.dart';

void main() {
  group('SettingsRepository', () {
    test('syncSlice publishes settings without AudioProvider', () {
      final repository = SettingsRepository();
      addTearDown(repository.dispose);

      repository
        ..converterFormat = 'flac'
        ..converterBitrate = '192k'
        ..multiThreadPlaybackEnabled = true
        ..notificationsEnabled = false
        ..showPlaybackCard = false
        ..autoPlayAddedSessions = false
        ..isPageTransitioning = true;
      repository.syncSlice();

      expect(
        repository.slice.state,
        isA<SettingsState>()
            .having((state) => state.converterFormat, 'format', 'flac')
            .having((state) => state.converterBitrate, 'bitrate', '192k')
            .having(
              (state) => state.multiThreadPlaybackEnabled,
              'multi-thread',
              isTrue,
            )
            .having(
              (state) => state.notificationsEnabled,
              'notifications',
              isFalse,
            )
            .having((state) => state.showPlaybackCard, 'show card', isFalse)
            .having(
              (state) => state.autoPlayAddedSessions,
              'auto play',
              isFalse,
            )
            .having(
              (state) => state.isPageTransitioning,
              'page transition',
              isTrue,
            ),
      );
    });
  });

  group('TimerService', () {
    test('syncSlice includes runtime and draft state', () {
      final service = TimerService();
      addTearDown(service.dispose);

      service
        ..timerMode = TimerMode.trigger
        ..timerDuration = const Duration(minutes: 20)
        ..timerDraftMode = TimerMode.manual
        ..timerDraftDuration = const Duration(minutes: 45)
        ..timerActive = true
        ..timerRemaining = const Duration(minutes: 12)
        ..autoResumeEnabled = true
        ..autoResumeHour = 8
        ..autoResumeMinute = 30
        ..pausedByTimerSessionIds.add('session-a');
      service.syncSlice(isInitialized: true);

      expect(
        service.slice.state,
        isA<TimerStateSliceData>()
            .having((state) => state.mode, 'mode', TimerMode.trigger)
            .having(
              (state) => state.duration,
              'duration',
              const Duration(minutes: 20),
            )
            .having(
              (state) => state.draftDuration,
              'draft duration',
              const Duration(minutes: 45),
            )
            .having((state) => state.active, 'active', isTrue)
            .having(
              (state) => state.remaining,
              'remaining',
              const Duration(minutes: 12),
            )
            .having((state) => state.autoResumeEnabled, 'auto resume', isTrue)
            .having((state) => state.autoResumeHour, 'hour', 8)
            .having((state) => state.autoResumeMinute, 'minute', 30)
            .having(
              (state) => state.pausedByTimerSessionIds,
              'paused session ids',
              orderedEquals(['session-a']),
            ),
      );
    });
  });

  group('PlaybackSessionService', () {
    test('registerSession places newly added sessions first', () {
      final service = PlaybackSessionService();
      addTearDown(service.dispose);

      final first = PlaybackSession(
        id: 's1',
        currentTrackPath: '/tracks/one.mp3',
        loopMode: SessionLoopMode.single,
        nonSingleLoopMode: SessionLoopMode.single,
        volume: 0.9,
        createdAt: DateTime(2026),
        state: PlayerState(false, ProcessingState.ready),
      );
      final second = PlaybackSession(
        id: 's2',
        currentTrackPath: '/tracks/two.mp3',
        loopMode: SessionLoopMode.single,
        nonSingleLoopMode: SessionLoopMode.single,
        volume: 0.8,
        createdAt: DateTime(2026, 1, 2),
        state: PlayerState(false, ProcessingState.ready),
      );
      addTearDown(first.dispose);
      addTearDown(second.dispose);

      service.registerSession(first);
      service.registerSession(second);

      expect(service.sessionOrder, <String>['s2', 's1']);
      expect(service.activeSessions.map((session) => session.id), ['s2', 's1']);
    });

    test('activeSessions respects session order and playingSessionCount', () {
      final service = PlaybackSessionService();
      addTearDown(service.dispose);

      final first = PlaybackSession(
        id: 's1',
        currentTrackPath: '/tracks/one.mp3',
        loopMode: SessionLoopMode.single,
        nonSingleLoopMode: SessionLoopMode.single,
        volume: 0.9,
        createdAt: DateTime(2026),
        state: PlayerState(false, ProcessingState.ready),
      );
      final second = PlaybackSession(
        id: 's2',
        currentTrackPath: '/tracks/two.mp3',
        loopMode: SessionLoopMode.single,
        nonSingleLoopMode: SessionLoopMode.single,
        volume: 0.8,
        createdAt: DateTime(2026, 1, 2),
        state: PlayerState(true, ProcessingState.ready),
      );
      addTearDown(first.dispose);
      addTearDown(second.dispose);

      service.sessions['s1'] = first;
      service.sessions['s2'] = second;
      service.sessionOrder.add('s2');

      final ordered = service.activeSessions;
      expect(ordered.map((session) => session.id), ['s2', 's1']);
      expect(service.playingSessionCount, 1);

      service.markActiveSessionsDirty();
      service.sessionOrder
        ..clear()
        ..add('s1');
      expect(service.activeSessions.map((session) => session.id), ['s1', 's2']);
    });

    test('syncSlice publishes focused session and mode flags', () {
      final service = PlaybackSessionService();
      addTearDown(service.dispose);

      final session = PlaybackSession(
        id: 'focus',
        currentTrackPath: '/tracks/focus.mp3',
        loopMode: SessionLoopMode.single,
        nonSingleLoopMode: SessionLoopMode.single,
        volume: 0.8,
        createdAt: DateTime(2026, 1, 3),
        state: PlayerState(true, ProcessingState.ready),
      );
      addTearDown(session.dispose);

      service.syncSlice(
        activeSessions: [session],
        playingSessionCount: 1,
        focusedSessionId: 'focus',
        multiThreadPlaybackEnabled: true,
        isInitialized: true,
      );

      expect(
        service.slice.state,
        isA<PlaybackStateSliceData>()
            .having(
              (state) => state.activeSessions.single.id,
              'session id',
              'focus',
            )
            .having((state) => state.playingSessionCount, 'count', 1)
            .having((state) => state.focusedSessionId, 'focus', 'focus')
            .having(
              (state) => state.multiThreadPlaybackEnabled,
              'multi-thread',
              isTrue,
            ),
      );
    });
  });

  group('LibraryService', () {
    MusicTrack track(String path, {required String groupKey}) {
      return MusicTrack(
        path: path,
        displayName: path.split('/').last,
        groupKey: groupKey,
        groupTitle: groupKey.split('/').last,
        groupSubtitle: groupKey,
        isSingle: false,
      );
    }

    test('syncLibraryNodeOrder places newly discovered roots first', () {
      final service = LibraryService();
      addTearDown(service.dispose);

      service.library.add(track('/music/old/01.mp3', groupKey: '/music/old'));
      service.syncLibraryNodeOrder();

      expect(service.libraryNodeOrder, <String>['/music/old']);

      service.library.addAll(<MusicTrack>[
        track('/music/new-a/01.mp3', groupKey: '/music/new-a'),
        track('/music/new-b/01.mp3', groupKey: '/music/new-b'),
      ]);
      service.syncLibraryNodeOrder();

      expect(service.libraryNodeOrder, <String>[
        '/music/new-a',
        '/music/new-b',
        '/music/old',
      ]);
    });

    test('watched SAF folders dedupe equivalent tree and document uris', () {
      final service = LibraryService();
      addTearDown(service.dispose);

      const albumTree =
          'content://com.android.externalstorage.documents/tree/primary%3AMusic%2FAlbum';
      const albumDocument =
          'content://com.android.externalstorage.documents/tree/primary%3AMusic/document/primary%3AMusic%2FAlbum';

      expect(service.addWatchedFolder(albumTree), isTrue);
      expect(service.addWatchedFolder(albumDocument), isFalse);
      expect(service.watchedFolders, <String>[albumTree]);
    });

    test('removeLibrary clears SAF child folders and exclusions', () async {
      final service = LibraryService();
      addTearDown(service.dispose);

      const root =
          'content://com.android.externalstorage.documents/tree/primary%3AMusic';
      const albumTree =
          'content://com.android.externalstorage.documents/tree/primary%3AMusic%2FAlbum';
      const albumDocument =
          'content://com.android.externalstorage.documents/tree/primary%3AMusic/document/primary%3AMusic%2FAlbum';

      service
        ..watchedLibraries.add(root)
        ..watchedFolders.add(albumTree)
        ..excludedLibraryFolders[root] = <String>{albumDocument}
        ..excludedLibraryTracks[root] = <String>{
          '$albumDocument/document/primary%3AMusic%2FAlbum%2F01.mp3',
        };

      final removedFolders = <String>[];
      await service.removeLibrary(
        root,
        removeFolder: (folderPath) async => removedFolders.add(folderPath),
      );

      expect(removedFolders, <String>[albumTree]);
      expect(service.watchedLibraries, isEmpty);
      expect(service.excludedLibraryFolders, isEmpty);
      expect(service.excludedLibraryTracks, isEmpty);
    });

    test('syncSlice reflects scan and structure metadata', () {
      final service = LibraryService();
      addTearDown(service.dispose);

      service
        ..library.addAll([])
        ..watchedFolders.add('/music')
        ..watchedLibraries.add('/library')
        ..isScanning = true
        ..isBackgroundScanning = true
        ..scanCurrentFolder = '/music/album'
        ..scanFoundCount = 4
        ..scanDuplicateCount = 1
        ..scanFailureCount = 2;
      service.markStructureChanged();
      service.syncSlice(isInitialized: true);

      expect(
        service.slice.state,
        isA<LibraryState>()
            .having((state) => state.watchedFolderCount, 'folders', 1)
            .having((state) => state.watchedLibraryCount, 'libraries', 1)
            .having((state) => state.isScanning, 'scanning', isTrue)
            .having(
              (state) => state.isBackgroundScanning,
              'background scanning',
              isTrue,
            )
            .having(
              (state) => state.scanCurrentFolder,
              'current folder',
              '/music/album',
            )
            .having((state) => state.scanFoundCount, 'found', 4)
            .having((state) => state.scanDuplicateCount, 'duplicates', 1)
            .having((state) => state.scanFailureCount, 'failures', 2)
            .having((state) => state.structureRevision, 'revision', 1),
      );
    });
  });
}
