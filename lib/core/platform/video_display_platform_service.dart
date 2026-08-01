import 'package:flutter/services.dart';

import '../errors/native_result.dart';
import 'platform_channels.dart';
import 'platform_method_client.dart';

class PlatformBrightnessLease {
  const PlatformBrightnessLease({
    required this.token,
    required this.brightness,
  });

  final String token;
  final double brightness;
}

abstract interface class VideoDisplayPlatformGateway {
  Future<NativeResult<PlatformBrightnessLease>> beginBrightnessControl();

  Future<NativeResult<void>> setBrightness(String token, double brightness);

  Future<NativeResult<void>> endBrightnessControl(String token);
}

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
