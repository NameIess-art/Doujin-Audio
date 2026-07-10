import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/services/system_media_controls_service.dart';
import 'package:smtc_windows/smtc_windows.dart';

void main() {
  test('sync initializes SMTC and publishes state', () async {
    var initializeCalls = 0;
    late _FakeSmtcController controller;
    final service = SystemMediaControlsService(
      isWindows: () => true,
      initialize: () async {
        initializeCalls++;
      },
      controllerFactory: (state) {
        controller = _FakeSmtcController();
        return controller;
      },
    );

    await service.sync(
      const SystemMediaControlState(
        sessionId: 'session-1',
        title: 'Track title',
        artist: 'Artist',
        album: 'Album',
        thumbnail: 'C:/covers/cover.jpg',
        playing: true,
        hasPrevious: true,
        hasNext: false,
        position: Duration(seconds: 5),
        duration: Duration(seconds: 30),
      ),
      _noopCallbacks,
    );

    expect(initializeCalls, 1);
    expect(controller.configs.single.nextEnabled, isFalse);
    expect(controller.configs.single.prevEnabled, isTrue);
    expect(controller.metadata.single.title, 'Track title');
    expect(controller.metadata.single.thumbnail, 'C:/covers/cover.jpg');
    expect(controller.timelines.single.positionMs, 5000);
    expect(controller.timelines.single.endTimeMs, 30000);
    expect(controller.statuses.last, PlaybackStatus.playing);
  });

  test(
    'button events are forwarded to the current session callbacks',
    () async {
      late _FakeSmtcController controller;
      final events = <String>[];
      final service = SystemMediaControlsService(
        isWindows: () => true,
        initialize: () async {},
        controllerFactory: (_) {
          controller = _FakeSmtcController();
          return controller;
        },
      );

      await service.sync(
        const SystemMediaControlState(
          sessionId: 'session-2',
          title: 'Track title',
          playing: true,
          hasPrevious: true,
          hasNext: true,
        ),
        SystemMediaControlsCallbacks(
          onToggle: (sessionId) => events.add('toggle:$sessionId'),
          onPrevious: (sessionId) => events.add('previous:$sessionId'),
          onNext: (sessionId) => events.add('next:$sessionId'),
        ),
      );

      controller.addButton(PressedButton.next);
      controller.addButton(PressedButton.previous);
      controller.addButton(PressedButton.pause);
      controller.addButton(PressedButton.stop);
      await Future<void>.delayed(Duration.zero);

      expect(events, <String>[
        'next:session-2',
        'previous:session-2',
        'toggle:session-2',
        'toggle:session-2',
      ]);
    },
  );

  test('clear disables SMTC and removes metadata', () async {
    late _FakeSmtcController controller;
    final service = SystemMediaControlsService(
      isWindows: () => true,
      initialize: () async {},
      controllerFactory: (_) {
        controller = _FakeSmtcController();
        return controller;
      },
    );

    await service.sync(
      const SystemMediaControlState(
        sessionId: 'session-3',
        title: 'Track title',
        playing: false,
        hasPrevious: false,
        hasNext: false,
      ),
      _noopCallbacks,
    );
    await service.clear();

    expect(controller.statuses.last, PlaybackStatus.stopped);
    expect(controller.clearMetadataCalls, 1);
    expect(controller.disableCalls, 1);
  });
}

const _noopCallbacks = SystemMediaControlsCallbacks(
  onToggle: _noopSessionCallback,
  onPrevious: _noopSessionCallback,
  onNext: _noopSessionCallback,
);

void _noopSessionCallback(String sessionId) {}

class _FakeSmtcController implements SmtcController {
  final StreamController<PressedButton> _buttons =
      StreamController<PressedButton>.broadcast();
  final configs = <SMTCConfig>[];
  final metadata = <MusicMetadata>[];
  final timelines = <PlaybackTimeline>[];
  final statuses = <PlaybackStatus>[];
  var enableCalls = 0;
  var disableCalls = 0;
  var clearMetadataCalls = 0;
  var disposeCalls = 0;

  void addButton(PressedButton button) => _buttons.add(button);

  @override
  Stream<PressedButton> get buttonPressStream => _buttons.stream;

  @override
  Future<void> clearMetadata() async {
    clearMetadataCalls++;
  }

  @override
  Future<void> disableSmtc() async {
    disableCalls++;
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
    await _buttons.close();
  }

  @override
  Future<void> enableSmtc() async {
    enableCalls++;
  }

  @override
  Future<void> setPlaybackStatus(PlaybackStatus status) async {
    statuses.add(status);
  }

  @override
  Future<void> updateConfig(SMTCConfig config) async {
    configs.add(config);
  }

  @override
  Future<void> updateMetadata(MusicMetadata metadata) async {
    this.metadata.add(metadata);
  }

  @override
  Future<void> updateTimeline(PlaybackTimeline timeline) async {
    timelines.add(timeline);
  }
}
