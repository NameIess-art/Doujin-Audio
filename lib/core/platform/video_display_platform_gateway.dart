import '../errors/native_result.dart';

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
