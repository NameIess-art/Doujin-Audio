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
    expect(formatDurationWithUnits(const Duration(seconds: -1)), '0 s');
  });

  test('formatDurationWithUnits labels seconds, minutes and hours', () {
    expect(formatDurationWithUnits(Duration.zero), '0 s');
    expect(formatDurationWithUnits(const Duration(milliseconds: 500)), '0 s');
    expect(formatDurationWithUnits(const Duration(seconds: 59)), '59 s');
    expect(formatDurationWithUnits(const Duration(minutes: 1)), '1 min');
    expect(
      formatDurationWithUnits(const Duration(minutes: 3, seconds: 48)),
      '3 min 48 s',
    );
    expect(formatDurationWithUnits(const Duration(hours: 1)), '1 h');
    expect(
      formatDurationWithUnits(const Duration(hours: 1, seconds: 5)),
      '1 h 5 s',
    );
    expect(
      formatDurationWithUnits(const Duration(hours: 25, minutes: 2, seconds: 3)),
      '25 h 2 min 3 s',
    );
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
    expect(parseDateYmd('2026-13-01'), isNull);
    expect(parseDateYmd('2026-02-29'), isNull);
    expect(parseDateYmd('2026-04-31'), isNull);
    expect(parseDateYmd('2024-02-29'), DateTime(2024, 2, 29));
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
