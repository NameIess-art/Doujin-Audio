String formatDurationHms(Duration value) {
  final normalized = _nonNegative(value);
  final hours = normalized.inHours;
  final minutes = normalized.inMinutes.remainder(60);
  final seconds = normalized.inSeconds.remainder(60);
  return '${_twoDigits(hours)}:${_twoDigits(minutes)}:${_twoDigits(seconds)}';
}

String formatDurationCompact(Duration value) {
  final normalized = _nonNegative(value);
  if (normalized.inHours > 0) return formatDurationHms(normalized);
  final minutes = normalized.inMinutes.remainder(60);
  final seconds = normalized.inSeconds.remainder(60);
  return '${_twoDigits(minutes)}:${_twoDigits(seconds)}';
}

String formatClockTime(int hour, int minute) {
  return '${_twoDigits(hour)}:${_twoDigits(minute)}';
}

String formatDateYmd(DateTime value) {
  return '${value.year.toString().padLeft(4, '0')}-'
      '${_twoDigits(value.month)}-'
      '${_twoDigits(value.day)}';
}

DateTime? parseDateYmd(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  final match = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})$').firstMatch(trimmed);
  if (match == null) return DateTime.tryParse(trimmed);
  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  return DateTime(year, month, day);
}

Duration? parseDurationCompact(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  final parts = trimmed
      .split(':')
      .map((part) => int.tryParse(part.trim()))
      .toList(growable: false);
  if (parts.length < 2 ||
      parts.length > 3 ||
      parts.any((part) => part == null || part < 0)) {
    return null;
  }
  final values = parts.cast<int>();
  if (values.skip(1).any((part) => part >= 60)) {
    return null;
  }
  final seconds = values.length == 3
      ? values[0] * 3600 + values[1] * 60 + values[2]
      : values[0] * 60 + values[1];
  return Duration(seconds: seconds);
}

Duration _nonNegative(Duration value) {
  return value < Duration.zero ? Duration.zero : value;
}

String _twoDigits(int value) => value.toString().padLeft(2, '0');
