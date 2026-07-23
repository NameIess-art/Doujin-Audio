import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/core/logging/app_log_service.dart';

void main() {
  test('sanitizes credentials and authorization headers', () {
    final sanitized = AppLogService.sanitize(
      'token=secret password: hunter2 Authorization: Bearer abc.def.ghi',
    );

    expect(sanitized, isNot(contains('secret')));
    expect(sanitized, isNot(contains('hunter2')));
    expect(sanitized, isNot(contains('abc.def.ghi')));
    expect(sanitized, contains('[REDACTED]'));
  });

  test('removes URL query parameters while retaining endpoint path', () {
    final sanitized = AppLogService.sanitize(
      'request=https://example.com/api/search?q=private&token=secret',
    );

    expect(sanitized, contains('https://example.com/api/search'));
    expect(sanitized, isNot(contains('private')));
    expect(sanitized, isNot(contains('secret')));
  });

  test('redacts quoted and multi-word credential values', () {
    final sanitized = AppLogService.sanitize(
      'password="correct horse battery staple" '
      "refresh_token='first second' token=plain value; status=failed",
    );

    expect(sanitized, isNot(contains('correct horse battery staple')));
    expect(sanitized, isNot(contains('first second')));
    expect(sanitized, isNot(contains('plain value')));
    expect(sanitized, contains('status=failed'));
  });

  test('redacts escaped JSON secrets and multiple values on one line', () {
    final sanitized = AppLogService.sanitize(
      r'{"password":"two words with \"quotes\"","token":"abc def"} '
      'Authorization: Bearer header.secret',
    );

    expect(sanitized, isNot(contains('two words')));
    expect(sanitized, isNot(contains('abc def')));
    expect(sanitized, isNot(contains('header.secret')));
  });

  test('sanitizing an already redacted message is idempotent', () {
    const input = 'token=[REDACTED] password: [REDACTED]';

    expect(AppLogService.sanitize(AppLogService.sanitize(input)), input);
  });

  test('redacts apostrophes inside unquoted multi-word values', () {
    final sanitized = AppLogService.sanitize(
      "password=don't share this; token=visible-secret",
    );

    expect(sanitized, isNot(contains("don't share this")));
    expect(sanitized, isNot(contains('visible-secret')));
    expect(sanitized, 'password=[REDACTED]; token=[REDACTED]');
  });
}
