import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/errors/native_result.dart';

void main() {
  test('strict envelope decoder accepts success and stable failure fields', () {
    final success = decodeNativeEnvelope<int>(<String, Object?>{
      'ok': true,
      'value': 7,
    }, (value) => value as int);
    final failure = decodeNativeEnvelope<int>(<String, Object?>{
      'ok': false,
      'errorCode': 'copy_failed',
      'error': 'copy failed',
      'details': <String, Object?>{'path': 'source'},
    }, (value) => value as int);

    expect(success.valueOrNull, 7);
    expect(failure.errorCodeOrNull, 'copy_failed');
    expect(failure.errorOrNull, 'copy failed');
    expect(failure.errorDetailsOrNull, <String, Object?>{'path': 'source'});
  });

  test(
    'strict envelope decoder rejects malformed responses as platform error',
    () {
      final missingOk = decodeNativeEnvelope<String>(<String, Object?>{
        'value': 'legacy',
      }, (value) => value as String);
      final wrongValue = decodeNativeEnvelope<String>(<String, Object?>{
        'ok': true,
        'value': 1,
      }, (value) => value as String);
      final missingFailureFields = decodeNativeEnvelope<String>(
        <String, Object?>{'ok': false, 'error': 'failed'},
        (value) => value as String,
      );

      expect(missingOk.errorCodeOrNull, NativeErrorCode.platformError);
      expect(wrongValue.errorCodeOrNull, NativeErrorCode.platformError);
      expect(
        missingFailureFields.errorCodeOrNull,
        NativeErrorCode.platformError,
      );
    },
  );
}
