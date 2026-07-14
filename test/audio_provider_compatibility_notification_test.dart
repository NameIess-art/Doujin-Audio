import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/app/state/audio_provider.dart';
import 'package:nameless_audio/features/player/application/playback_notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
  });

  test(
    'one settings command emits at most one compatibility notification',
    () async {
      final provider = AudioProvider.test(
        notificationService: PlaybackNotificationService(),
      );
      addTearDown(provider.dispose);
      var notifications = 0;
      provider.addListener(() => notifications++);

      await provider.setShowPlaybackCard(false);
      await Future<void>.value();

      expect(notifications, 1);
    },
  );

  test(
    'queued compatibility notification is suppressed after dispose',
    () async {
      final provider = AudioProvider.test(
        notificationService: PlaybackNotificationService(),
      );
      var notifications = 0;
      provider.addListener(() => notifications++);

      unawaited(provider.setShowPlaybackCard(false));
      provider.dispose();
      await Future<void>.value();

      expect(notifications, 0);
    },
  );
}
