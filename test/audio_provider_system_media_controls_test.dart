import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/app/state/audio_provider.dart';
import 'package:nameless_audio/core/persistence/app_database.dart';
import 'package:nameless_audio/core/persistence/audio_database_repository.dart';
import 'package:nameless_audio/features/player/application/playback_notification_service.dart';
import 'package:nameless_audio/core/platform/platform_channels.dart';
import 'package:nameless_audio/features/player/application/system_media_controls_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues(const <String, Object>{});

  const nativePlaybackChannel = MethodChannel(NativePlaybackChannel.name);
  late Database db;
  late AudioProvider provider;
  late _FakeSystemMediaControlsService systemMediaControlsService;
  late List<Map<dynamic, dynamic>> prepareCalls;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await AppDatabase.createSchemaForTest(db);
    prepareCalls = <Map<dynamic, dynamic>>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nativePlaybackChannel, (call) async {
          if (call.method == NativePlaybackMethod.prepareSession) {
            prepareCalls.add(call.arguments as Map<dynamic, dynamic>);
          }
          return <String, Object?>{'ok': true, 'value': null};
        });
    systemMediaControlsService = _FakeSystemMediaControlsService();
    provider = AudioProvider.test(
      notificationService: PlaybackNotificationService(),
      audioDatabaseRepository: AudioDatabaseRepository(
        database: AppDatabase.test(db),
      ),
      systemMediaControlsService: systemMediaControlsService,
    );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nativePlaybackChannel, null);
    provider.dispose();
    await db.close();
  });

  test('system next callback reuses provider queue advancement', () async {
    const first = MusicTrack(
      path: '/music/work/01.mp3',
      displayName: '01',
      groupKey: '/music/work',
      groupTitle: 'work',
      groupSubtitle: '/music/work',
      isSingle: false,
    );
    const second = MusicTrack(
      path: '/music/work/02.mp3',
      displayName: '02',
      groupKey: '/music/work',
      groupTitle: 'work',
      groupSubtitle: '/music/work',
      isSingle: false,
    );
    provider.addTracks(const <MusicTrack>[first, second], persist: false);

    await provider.playbackFacade.spawnSessionWithQueue(const <MusicTrack>[
      first,
      second,
    ], autoPlay: false);
    await _waitFor(() => systemMediaControlsService.states.isNotEmpty);
    await _waitFor(() => prepareCalls.isNotEmpty);

    final state = systemMediaControlsService.states.last;
    expect(state.title, '01');
    expect(state.hasNext, isTrue);

    await systemMediaControlsService.callbacks!.onNext(state.sessionId);
    await _waitFor(() => prepareCalls.length >= 2);

    expect(
      prepareCalls.last['path'].toString().replaceAll(r'\', '/'),
      second.path,
    );
  });
}

Future<void> _waitFor(bool Function() condition) async {
  for (var i = 0; i < 50; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Timed out waiting for condition.');
}

class _FakeSystemMediaControlsService extends SystemMediaControlsService {
  _FakeSystemMediaControlsService() : super(isWindows: () => false);

  final states = <SystemMediaControlState>[];
  SystemMediaControlsCallbacks? callbacks;

  @override
  Future<void> sync(
    SystemMediaControlState? state,
    SystemMediaControlsCallbacks callbacks,
  ) async {
    this.callbacks = callbacks;
    if (state != null) states.add(state);
  }
}
