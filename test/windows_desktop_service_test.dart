import 'package:doujin_audio/core/platform/windows_desktop_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/windows_desktop');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final service = WindowsDesktopService(channel: channel);

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'reports each registration result including a conflicting shortcut',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'getHotkeyStatus');
        return {
          'toggle': true,
          'previous': false,
          'next': true,
          'showWindow': true,
        };
      });
      expect(await service.getHotkeyStatus(), {
        'toggle': true,
        'previous': false,
        'next': true,
        'showWindow': true,
      });
    },
  );

  test(
    'does not present missing native results as successful registration',
    () async {
      messenger.setMockMethodCallHandler(channel, (_) async => null);
      await expectLater(service.getHotkeyStatus(), throwsFormatException);
    },
  );
}
