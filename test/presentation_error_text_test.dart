import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/app/localization/app_language_provider.dart';
import 'package:doujin_audio/features/asmr/application/asmr_api_service.dart';
import 'package:doujin_audio/features/asmr/application/asmr_remote_catalog_service.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';
import 'package:doujin_audio/features/asmr/presentation/asmr_error_text.dart';
import 'package:doujin_audio/features/player/presentation/playback_error_text.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppLanguageProvider i18n;

  setUp(() {
    i18n = AppLanguageProvider();
  });

  tearDown(() {
    i18n.dispose();
  });

  test('ASMR catalog errors map to localized safe messages', () {
    final cases = <(Object, String)>[
      (
        const AsmrApiException('secret token', statusCode: 401),
        'asmr_authentication_failed_retry',
      ),
      (
        const AsmrApiException(
          'ASMR API server error (502).',
          statusCode: 502,
          source: AsmrCatalogSource.asmrOne,
        ),
        'asmr_one_server_unavailable_retry',
      ),
      (
        const AsmrApiException(
          'Japanese ASMR request failed (503).',
          statusCode: 503,
          source: AsmrCatalogSource.japaneseAsmr,
        ),
        'asmr_server_unavailable_retry',
      ),
      (
        AsmrPartialCatalogException(
          const [AsmrCatalogSource.asmrOne],
          causes: {
            AsmrCatalogSource.asmrOne: const AsmrApiException(
              'ASMR API server error (503).',
              statusCode: 503,
              source: AsmrCatalogSource.asmrOne,
            ),
          },
        ),
        'asmr_one_server_unavailable_partial',
      ),
      (
        AsmrPartialCatalogException(
          const [AsmrCatalogSource.asmrOne],
          causes: {
            AsmrCatalogSource.asmrOne: TimeoutException('request timed out'),
          },
        ),
        'asmr_one_unavailable_partial',
      ),
      (
        const SocketException('host example.invalid'),
        'asmr_network_failed_retry',
      ),
      (
        const HttpException('https://private.invalid'),
        'asmr_network_failed_retry',
      ),
      (TimeoutException('request timed out'), 'asmr_network_failed_retry'),
      (StateError('internal database detail'), 'operation_failed_retry'),
    ];

    for (final (error, key) in cases) {
      final text = localizedAsmrCatalogErrorText(i18n, error);
      expect(text, i18n.tr(key));
      expect(text, isNot(contains(error.toString())));
      expect(text, isNot(contains('private.invalid')));
      expect(text, isNot(contains('secret token')));
    }

    final onePartial = AsmrPartialCatalogException(const [
      AsmrCatalogSource.asmrOne,
    ]);
    expect(shouldShowAsmrUnavailableFeedback(onePartial), isTrue);
    expect(
      localizedAsmrUnavailableTitle(i18n, onePartial),
      i18n.tr('asmr_one_unavailable_title'),
    );
    expect(
      shouldShowAsmrUnavailableFeedback(
        const SocketException('host example.invalid'),
      ),
      isFalse,
    );
  });

  test(
    'playback errors map network and unknown details without rendering raw text',
    () {
      const rawNetworkError = 'SocketException: https://private.invalid/audio';
      const rawUnknownError = 'decoder crashed at internal offset 19';

      final networkText = localizedPlaybackErrorText(i18n, rawNetworkError);
      final unknownText = localizedPlaybackErrorText(i18n, rawUnknownError);

      expect(networkText, i18n.tr('playback_network_failed_retry'));
      expect(unknownText, i18n.tr('playback_failed_retry'));
      expect(networkText, isNot(contains('private.invalid')));
      expect(unknownText, isNot(contains('internal offset')));
      expect(
        localizedPlaybackErrorText(
          i18n,
          'AsmrApiException: Media is unavailable (502).',
          useAsmrOneText: true,
        ),
        i18n.tr('asmr_playback_server_unavailable_retry'),
      );
    },
  );
}
