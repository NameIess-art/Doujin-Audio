import 'package:flutter/services.dart';

import '../errors/native_result.dart';

class PlatformMethodClient {
  const PlatformMethodClient(this.channel);

  final MethodChannel channel;

  Future<NativeResult<T>> invoke<T>(
    String method, {
    Object? arguments,
    required T Function(Object? value) decode,
  }) async {
    try {
      final raw = await channel.invokeMethod<Object?>(method, arguments);
      return decodeNativeEnvelope<T>(raw, decode);
    } on MissingPluginException catch (error) {
      return NativeFailure<T>(
        'Platform method is unavailable.',
        code: NativeErrorCode.serviceUnavailable,
        details: <String, Object?>{'method': method, 'error': error.toString()},
      );
    } on PlatformException catch (error) {
      return NativeFailure<T>(
        error.message ?? 'Platform channel invocation failed.',
        code: error.code.isEmpty ? NativeErrorCode.platformError : error.code,
        details: <String, Object?>{
          'method': method,
          'platformDetails': error.details,
        },
      );
    } catch (error) {
      return NativeFailure<T>(
        'Platform channel invocation failed.',
        code: NativeErrorCode.platformError,
        details: <String, Object?>{'method': method, 'error': error.toString()},
      );
    }
  }
}
