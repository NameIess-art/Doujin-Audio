import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nameless_audio/core/errors/native_result.dart';
import 'package:nameless_audio/core/platform/platform_channels.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Windows subtitle channel validates its argument contract', (
    tester,
  ) async {
    if (!Platform.isWindows) return;
    const channel = MethodChannel(SubtitleOverlayChannel.name);

    Future<void> expectInvalidCall(String method, Object? arguments) async {
      await expectLater(
        channel.invokeMethod<Object?>(method, arguments),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            NativeErrorCode.invalidArgument,
          ),
        ),
      );
    }

    await expectInvalidCall(SubtitleOverlayMethod.updateSubtitle, null);
    await expectInvalidCall(
      SubtitleOverlayMethod.updateSubtitle,
      const <String, Object?>{},
    );
    await expectInvalidCall(
      SubtitleOverlayMethod.updateSubtitle,
      const <String, Object?>{'text': 7},
    );
    final emptySubtitleResult = await channel
        .invokeMethod<Map<Object?, Object?>>(
          SubtitleOverlayMethod.updateSubtitle,
          const <String, Object?>{'text': ''},
        );
    expect(emptySubtitleResult?['ok'], isTrue);
    await expectInvalidCall(
      SubtitleOverlayMethod.updateStyle,
      const <String, Object?>{'fontSize': 'large'},
    );
  });
}
