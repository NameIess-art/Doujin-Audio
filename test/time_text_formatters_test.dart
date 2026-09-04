import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/media/time_text_formatters.dart';

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

  test('formatDateYmd formats ISO date with padding', () {
    expect(formatDateYmd(DateTime(2026, 9, 4)), '2026-09-04');
    expect(formatDateYmd(DateTime(2026, 11, 23)), '2026-11-23');
  });

  test('parseDateYmd parses ISO date strings', () {
    expect(parseDateYmd('2026-09-04'), DateTime(2026, 9, 4));
    expect(parseDateYmd('2026-9-4'), DateTime(2026, 9, 4));
    expect(parseDateYmd(''), isNull);
    expect(parseDateYmd('invalid'), isNull);
  });

  test('parseDurationCompact parses mm:ss and hh:mm:ss strings', () {
    expect(
      parseDurationCompact('05:30'),
      const Duration(minutes: 5, seconds: 30),
    );
    expect(
      parseDurationCompact('01:05:30'),
      const Duration(hours: 1, minutes: 5, seconds: 30),
    );
    expect(parseDurationCompact('00:00'), Duration.zero);
    expect(parseDurationCompact(''), isNull);
    expect(parseDurationCompact('invalid'), isNull);
    expect(parseDurationCompact('05:60'), isNull);
  });
}
