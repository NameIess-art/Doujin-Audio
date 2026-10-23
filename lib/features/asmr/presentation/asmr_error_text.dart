import 'dart:async';
import 'dart:io';

import '../../../app/localization/app_language_provider.dart';
import '../application/asmr_api_service.dart';
import '../application/asmr_remote_catalog_service.dart';

String localizedAsmrCatalogErrorText(AppLanguageProvider i18n, Object? error) {
  if (error is AsmrPartialCatalogException) {
    return i18n.tr('online_library_partial_failure');
  }
  if (error != null && AsmrApiException.isAuthenticationError(error)) {
    return i18n.tr('asmr_authentication_failed_retry');
  }
  if (error is AsmrApiException ||
      error is SocketException ||
      error is HttpException ||
      error is TimeoutException) {
    return i18n.tr('asmr_network_failed_retry');
  }
  return i18n.tr('operation_failed_retry');
}
