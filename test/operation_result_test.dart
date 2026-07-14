import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/core/errors/app_failure.dart';
import 'package:nameless_audio/core/errors/operation_result.dart';

void main() {
  test('success exposes only its value', () {
    const result = OperationSuccess<int>(7);

    expect(result.isSuccess, isTrue);
    expect(result.isFailure, isFalse);
    expect(result.valueOrNull, 7);
    expect(result.failureOrNull, isNull);
  });

  test('failure keeps typed user and retry metadata', () {
    const failure = AppFailure(
      kind: AppFailureKind.database,
      code: 'database_busy',
      message: 'The database is busy.',
      category: AppFailureCategory.storage,
      retryable: true,
      details: <String, Object?>{'operation': 'save'},
    );
    const result = OperationFailure<int>(failure);

    expect(result.isSuccess, isFalse);
    expect(result.isFailure, isTrue);
    expect(result.valueOrNull, isNull);
    expect(result.failureOrNull, same(failure));
    expect(result.failureOrNull?.category, AppFailureCategory.storage);
    expect(result.failureOrNull?.retryable, isTrue);
  });
}
