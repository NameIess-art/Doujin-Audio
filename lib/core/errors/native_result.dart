sealed class NativeResult<T> {
  const NativeResult();

  bool get isOk => this is NativeSuccess<T>;
  bool get isFailure => this is NativeFailure<T>;
  T? get valueOrNull => switch (this) {
    NativeSuccess<T>(value: final value) => value,
    NativeFailure<T>() => null,
  };
  String? get errorOrNull => switch (this) {
    NativeSuccess<T>() => null,
    NativeFailure<T>(message: final message) => message,
  };
  String? get errorCodeOrNull => switch (this) {
    NativeSuccess<T>() => null,
    NativeFailure<T>(code: final code) => code,
  };
  Object? get errorDetailsOrNull => switch (this) {
    NativeSuccess<T>() => null,
    NativeFailure<T>(details: final details) => details,
  };
}

NativeResult<T> decodeNativeEnvelope<T>(
  Object? raw,
  T Function(Object? value) decodeValue,
) {
  if (raw is! Map) {
    return NativeFailure<T>(
      'Malformed platform response: expected an envelope map.',
      code: NativeErrorCode.platformError,
      details: raw,
    );
  }
  final envelope = raw.cast<Object?, Object?>();
  final ok = envelope['ok'];
  if (ok is! bool) {
    return NativeFailure<T>(
      'Malformed platform response: missing boolean ok field.',
      code: NativeErrorCode.platformError,
      details: envelope,
    );
  }
  if (ok) {
    try {
      return NativeSuccess<T>(decodeValue(envelope['value']));
    } catch (error) {
      return NativeFailure<T>(
        'Malformed platform success value: $error',
        code: NativeErrorCode.platformError,
        details: envelope,
      );
    }
  }
  final code = envelope['errorCode'];
  final message = envelope['error'];
  if (code is! String ||
      code.isEmpty ||
      message is! String ||
      message.isEmpty) {
    return NativeFailure<T>(
      'Malformed platform failure response.',
      code: NativeErrorCode.platformError,
      details: envelope,
    );
  }
  return NativeFailure<T>(message, code: code, details: envelope['details']);
}

abstract final class NativeErrorCode {
  static const String invalidArgument = 'invalid_argument';
  static const String serviceUnavailable = 'service_unavailable';
  static const String playerError = 'player_error';
  static const String platformError = 'platform_error';
  static const String unexpected = 'unexpected';
}

class NativeSuccess<T> extends NativeResult<T> {
  const NativeSuccess([this.value]);

  final T? value;
}

class NativeFailure<T> extends NativeResult<T> {
  const NativeFailure(
    this.message, {
    this.code = NativeErrorCode.unexpected,
    this.details,
  });

  final String message;
  final String code;
  final Object? details;
}
