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
}

class NativeSuccess<T> extends NativeResult<T> {
  const NativeSuccess([this.value]);

  final T? value;
}

class NativeFailure<T> extends NativeResult<T> {
  const NativeFailure(this.message);

  final String message;
}
