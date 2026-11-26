import '../../../app/localization/app_language_provider.dart';

final RegExp _httpServerStatusPattern = RegExp(r'\b5\d\d\b');

String localizedPlaybackErrorText(
  AppLanguageProvider i18n,
  String? error, {
  bool useAsmrOneText = false,
}) {
  final normalized = error?.toLowerCase() ?? '';
  final isServerError =
      normalized.contains('server error') ||
      normalized.contains('bad gateway') ||
      normalized.contains('service unavailable') ||
      normalized.contains('gateway timeout') ||
      ((normalized.contains('http') ||
              normalized.contains('status') ||
              normalized.contains('unavailable (')) &&
          _httpServerStatusPattern.hasMatch(normalized));
  if (isServerError) {
    return i18n.tr(
      useAsmrOneText
          ? 'asmr_playback_server_unavailable_retry'
          : 'playback_failed_retry',
    );
  }
  final isNetworkError =
      normalized.contains('network') ||
      normalized.contains('socket') ||
      normalized.contains('connection') ||
      normalized.contains('timeout') ||
      normalized.contains('timed out') ||
      normalized.contains('host') ||
      normalized.contains('http') ||
      normalized.contains('dns') ||
      normalized.contains('tls') ||
      normalized.contains('ssl') ||
      normalized.contains('internet');
  if (useAsmrOneText) {
    return i18n.tr(
      isNetworkError
          ? 'asmr_playback_network_failed_retry'
          : 'asmr_playback_load_failed_retry',
    );
  }
  return i18n.tr(
    isNetworkError ? 'playback_network_failed_retry' : 'playback_failed_retry',
  );
}
