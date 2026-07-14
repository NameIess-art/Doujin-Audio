import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/core/errors/native_result.dart';
import 'package:nameless_audio/core/platform/platform_method_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('test.platform_method_client');
  const client = PlatformMethodClient(channel);

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('decodes a successful native envelope', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (_) async => <String, Object?>{'ok': true, 'value': 7},
        );

    final result = await client.invoke<int>(
      'read',
      decode: (value) => value as int,
    );

    expect(result, isA<NativeSuccess<int>>());
    expect(result.valueOrNull, 7);
  });

  test('converts a malformed response to platform failure', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => true);

    final result = await client.invoke<bool>(
      'read',
      decode: (value) => value as bool,
    );

    expect(result, isA<NativeFailure<bool>>());
    expect(result.errorCodeOrNull, NativeErrorCode.platformError);
    expect(result.errorDetailsOrNull, true);
  });

  test('converts MissingPluginException to service unavailable', () async {
    final result = await client.invoke<void>('missing', decode: (_) {});

    expect(result, isA<NativeFailure<void>>());
    expect(result.errorCodeOrNull, NativeErrorCode.serviceUnavailable);
    expect(result.errorDetailsOrNull, containsPair('method', 'missing'));
  });

  test('converts PlatformException and keeps technical details', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (_) => throw PlatformException(
            code: 'invalid_argument',
            message: 'bad input',
            details: <String, Object?>{'field': 'path'},
          ),
        );

    final result = await client.invoke<void>('install', decode: (_) {});

    expect(result, isA<NativeFailure<void>>());
    expect(result.errorCodeOrNull, 'invalid_argument');
    expect(
      result.errorDetailsOrNull,
      containsPair('platformDetails', <String, Object?>{'field': 'path'}),
    );
  });
}
