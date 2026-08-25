import 'package:flutter/services.dart';

import '../errors/native_result.dart';
import 'platform_channels.dart';
import 'platform_method_client.dart';
import 'video_display_platform_gateway.dart';

class VideoDisplayPlatformService implements VideoDisplayPlatformGateway {
  VideoDisplayPlatformService({MethodChannel? channel})
    : _client = PlatformMethodClient(
        channel ?? const MethodChannel(VideoDisplayChannel.name),
      );

  final PlatformMethodClient _client;

  @override
  Future<NativeResult<PlatformBrightnessLease>> beginBrightnessControl() {
    return _client.invoke<PlatformBrightnessLease>(
      VideoDisplayMethod.beginBrightnessControl,
      decode: (value) {
        final map = Map<Object?, Object?>.from(value as Map);
        return PlatformBrightnessLease(
          token: map['token'] as String,
          brightness: (map['brightness'] as num).toDouble(),
        );
      },
    );
  }

  @override
  Future<NativeResult<void>> setBrightness(String token, double brightness) {
    return _client.invoke<void>(
      VideoDisplayMethod.setBrightness,
      arguments: <String, Object?>{'token': token, 'brightness': brightness},
      decode: (_) {},
    );
  }

  @override
  Future<NativeResult<void>> endBrightnessControl(String token) {
    return _client.invoke<void>(
      VideoDisplayMethod.endBrightnessControl,
      arguments: <String, Object?>{'token': token},
      decode: (_) {},
    );
  }
}
