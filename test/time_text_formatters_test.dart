import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/core/media/time_text_formatters.dart';

void main() {
  test('formatDurationHms always includes hours', () {
    expect(
      formatDurationHms(const Duration(hours: 2, minutes: 3, seconds: 4)),
      '02:03:04',
    );
    expect(
      formatDurationHms(const Duration(minutes: 3, seconds: 4)),
      '00:03:04',
    );
  });

  test('formatDurationCompact omits hours when zero', () {
    expect(
      formatDurationCompact(const Duration(minutes: 3, seconds: 4)),
      '03:04',
    );
    expect(
      formatDurationCompact(const Duration(hours: 2, minutes: 3, seconds: 4)),
      '02:03:04',
    );
  });

  test('formatters clamp negative durations to zero', () {
    expect(formatDurationHms(const Duration(seconds: -1)), '00:00:00');
    expect(formatDurationCompact(const Duration(seconds: -1)), '00:00');
  });

  test('formatClockTime pads hour and minute', () {
    expect(formatClockTime(7, 5), '07:05');
  });
}
