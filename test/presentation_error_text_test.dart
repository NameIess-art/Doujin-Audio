import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/app/localization/app_language_provider.dart';
import 'package:doujin_audio/features/asmr/application/asmr_api_service.dart';
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
    },
  );
}
