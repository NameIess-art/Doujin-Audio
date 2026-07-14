enum AppFailureKind { scan, database, playback, platform }

enum AppFailureCategory {
  permission,
  invalidInput,
  unavailable,
  conflict,
  storage,
  playback,
  unknown,
}

class AppFailure implements Exception {
  const AppFailure({
    required this.kind,
    required this.code,
    required this.message,
    this.category = AppFailureCategory.unknown,
    this.retryable = false,
    this.cause,
    this.details,
  });

  final AppFailureKind kind;
  final String code;
  final String message;
  final AppFailureCategory category;
  final bool retryable;
  final Object? cause;
  final Object? details;

  @override
  String toString() => 'AppFailure($kind, $code): $message';
}
