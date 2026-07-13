String formatDurationHms(Duration value) {
  final normalized = _nonNegative(value);
  final hours = normalized.inHours;
  final minutes = normalized.inMinutes.remainder(60);
  final seconds = normalized.inSeconds.remainder(60);
  return '${_twoDigits(hours)}:${_twoDigits(minutes)}:${_twoDigits(seconds)}';
}

String formatDurationCompact(Duration value) {
  final normalized = _nonNegative(value);
  final hours = normalized.inHours;
  final minutes = normalized.inMinutes.remainder(60);
  final seconds = normalized.inSeconds.remainder(60);
  if (hours > 0) {
    return '${_twoDigits(hours)}:${_twoDigits(minutes)}:${_twoDigits(seconds)}';
  }
  return '${_twoDigits(minutes)}:${_twoDigits(seconds)}';
}

String formatClockTime(int hour, int minute) {
  return '${_twoDigits(hour)}:${_twoDigits(minute)}';
}

Duration _nonNegative(Duration value) {
  return value < Duration.zero ? Duration.zero : value;
}

String _twoDigits(int value) => value.toString().padLeft(2, '0');
