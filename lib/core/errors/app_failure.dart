enum AppFailureKind { scan, database, playback, platform }

class AppFailure implements Exception {
  const AppFailure({
    required this.kind,
    required this.code,
    required this.message,
    this.cause,
    this.details,
  });

  final AppFailureKind kind;
  final String code;
  final String message;
  final Object? cause;
  final Object? details;

  @override
  String toString() => 'AppFailure($kind, $code): $message';
}
