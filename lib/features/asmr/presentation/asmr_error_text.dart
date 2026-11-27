import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../../app/localization/app_language_provider.dart';
import '../../../core/widgets/app_feedback.dart';
import '../application/asmr_api_service.dart';
import '../application/asmr_remote_catalog_service.dart';
import '../domain/asmr_models.dart';

final Expando<Set<AsmrCatalogSource>> _acknowledgedUnavailableSources =
    Expando<Set<AsmrCatalogSource>>('asmr_acknowledged_unavailable_sources');

bool shouldShowAsmrUnavailableFeedback(Object? error) =>
    error is AsmrPartialCatalogException ||
    AsmrApiException.isServerUnavailable(error);

Set<AsmrCatalogSource> _unavailableSourcesFor(Object error) {
  if (error is AsmrPartialCatalogException) return error.sources.toSet();
  if (error is AsmrApiException && error.isServerError) {
    return <AsmrCatalogSource>{error.source ?? AsmrCatalogSource.asmrOne};
  }
  return const <AsmrCatalogSource>{};
}

bool consumeAsmrUnavailableNotice(Object scopeOwner, Object error) {
  final sources = _unavailableSourcesFor(error);
  if (sources.isEmpty) return false;
  final acknowledged = _acknowledgedUnavailableSources[scopeOwner] ??=
      <AsmrCatalogSource>{};
  if (sources.every(acknowledged.contains)) {
    return false;
  }
  acknowledged.addAll(sources);
  return true;
}

void clearAsmrUnavailableNotice(Object? scopeOwner) {
  if (scopeOwner == null) return;
  _acknowledgedUnavailableSources[scopeOwner]?.clear();
}

String localizedAsmrUnavailableTitle(
  AppLanguageProvider i18n,
  Object error,
) {
  if (error is AsmrPartialCatalogException) {
    final sources = error.sources;
    if (sources.length == 1 && sources.single == AsmrCatalogSource.asmrOne) {
      return i18n.tr('asmr_one_unavailable_title');
    }
    if (sources.length == 1 &&
        sources.single == AsmrCatalogSource.japaneseAsmr) {
      return i18n.tr('japanese_asmr_unavailable_title');
    }
    return i18n.tr('online_source_unavailable_title');
  }
  if (error is AsmrApiException &&
      error.source == AsmrCatalogSource.japaneseAsmr) {
    return i18n.tr('japanese_asmr_unavailable_title');
  }
  return i18n.tr('asmr_one_unavailable_title');
}

void showAsmrUnavailableFeedback({
  required BuildContext context,
  required AppLanguageProvider i18n,
  required Object error,
  VoidCallback? onRetry,
}) {
  if (!context.mounted) return;
  final isPartial = error is AsmrPartialCatalogException;
  showAppSnackBar(
    context,
    localizedAsmrUnavailableTitle(i18n, error),
    tone: isPartial ? AppFeedbackTone.warning : AppFeedbackTone.destructive,
    icon: Icons.cloud_off_rounded,
    actionIcon: onRetry != null ? Icons.refresh_rounded : null,
    actionLabel: onRetry != null ? i18n.tr('refresh') : null,
    onAction: onRetry,
    duration: const Duration(seconds: 5),
    showCountdown: false,
    replacementGroup: 'asmr-unavailable',
  );
}

String localizedAsmrCatalogErrorText(AppLanguageProvider i18n, Object? error) {
  if (error is AsmrPartialCatalogException) {
    final sources = error.sources;
    if (sources.length == 1 && sources.single == AsmrCatalogSource.asmrOne) {
      final cause = error.causes[AsmrCatalogSource.asmrOne];
      return i18n.tr(
        AsmrApiException.isServerUnavailable(cause)
            ? 'asmr_one_server_unavailable_partial'
            : 'asmr_one_unavailable_partial',
      );
    }
    if (sources.length == 1 &&
        sources.single == AsmrCatalogSource.japaneseAsmr &&
        AsmrApiException.isServerUnavailable(
          error.causes[AsmrCatalogSource.japaneseAsmr],
        )) {
      return i18n.tr('japanese_asmr_server_unavailable_partial');
    }
    return i18n.tr('online_library_partial_failure');
  }
  if (error != null && AsmrApiException.isAuthenticationError(error)) {
    return i18n.tr('asmr_authentication_failed_retry');
  }
  if (error is AsmrApiException && error.isServerError) {
    return i18n.tr(
      error.source == AsmrCatalogSource.japaneseAsmr
          ? 'asmr_server_unavailable_retry'
          : 'asmr_one_server_unavailable_retry',
    );
  }
  if (error is AsmrApiException ||
      error is SocketException ||
      error is HttpException ||
      error is TimeoutException) {
    return i18n.tr('asmr_network_failed_retry');
  }
  return i18n.tr('operation_failed_retry');
}
