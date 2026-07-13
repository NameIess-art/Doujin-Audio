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
