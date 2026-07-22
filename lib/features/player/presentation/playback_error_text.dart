import '../../../app/localization/app_language_provider.dart';

String localizedPlaybackErrorText(
  AppLanguageProvider i18n,
  String? error, {
  bool useAsmrOneText = false,
}) {
  final normalized = error?.toLowerCase() ?? '';
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
