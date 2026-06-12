import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/services/app_log_service.dart';

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
}
