import 'app_failure.dart';

sealed class OperationResult<T> {
  const OperationResult();

  bool get isSuccess => this is OperationSuccess<T>;
  bool get isFailure => this is OperationFailure<T>;

  T? get valueOrNull => switch (this) {
    OperationSuccess<T>(value: final value) => value,
    OperationFailure<T>() => null,
  };

  AppFailure? get failureOrNull => switch (this) {
    OperationSuccess<T>() => null,
    OperationFailure<T>(failure: final failure) => failure,
  };
}

final class OperationSuccess<T> extends OperationResult<T> {
  const OperationSuccess(this.value);

  final T value;
}

final class OperationFailure<T> extends OperationResult<T> {
  const OperationFailure(this.failure);

  final AppFailure failure;
}
