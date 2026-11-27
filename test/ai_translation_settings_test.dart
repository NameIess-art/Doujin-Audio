import 'dart:async';

import 'package:doujin_audio/core/persistence/app_preferences.dart';
import 'package:doujin_audio/core/translation/text_translation_service.dart';
import 'package:doujin_audio/features/player/application/playback_subtitle_service.dart';
import 'package:doujin_audio/features/player/application/subtitle_ai_engine.dart';
import 'package:doujin_audio/features/player/application/subtitle_model_store.dart';
import 'package:doujin_audio/features/settings/application/settings_repository.dart';
import 'package:doujin_audio/features/settings/presentation/settings_tab.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/app_runtime_test_fixture.dart';

void main() {
  AppRuntimeTestFixture.initialize();
  late Database database;

  setUpAll(
    () async => database = await AppRuntimeTestFixture.installSharedDatabase(),
  );
  tearDownAll(() => AppRuntimeTestFixture.disposeSharedDatabase(database));

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await AppPreferences.init();
  });

  test(
    'SettingsRepository persists translation settings, secures API key, and clears cleanly',
    () async {
      String? storedSecret;
      TranslationServiceSettings? notifiedSettings;
      String? notifiedSecret;

      final repo = SettingsRepository(
        readTranslationApiKey: () async => storedSecret,
        writeTranslationApiKey: (value) async => storedSecret = value,
        onTranslationSettingsChanged: (settings, secret) {
          notifiedSettings = settings;
          notifiedSecret = secret;
        },
      );
      addTearDown(repo.dispose);

      await repo.setTranslationSettings(
        const TranslationServiceSettings(
          provider: TranslationProviderKind.openAiCompatible,
          scope: CustomTranslationScope.all,
          apiBaseUrl: ' http://127.0.0.1:11434/v1 ',
          model: ' qwen2.5:7b ',
          customPrompt: ' 自定义提示词 ',
        ),
        apiKey: ' sk-secret-123 ',
      );

      expect(storedSecret, 'sk-secret-123');
      expect(repo.translationSettings.apiKeyConfigured, isTrue);
      expect(repo.translationSettings.apiBaseUrl, 'http://127.0.0.1:11434/v1');
      expect(repo.translationSettings.model, 'qwen2.5:7b');
      expect(repo.translationSettings.customPrompt, '自定义提示词');
      expect(notifiedSettings, repo.translationSettings);
      expect(notifiedSecret, 'sk-secret-123');

      await repo.setSelectedAsrModelId(SubtitleModelStore.defaultAsrModelId);
      expect(repo.selectedAsrModelId, SubtitleModelStore.defaultAsrModelId);

      // Reload into a fresh repository and verify key resolution.
      final reloaded = SettingsRepository(
        readTranslationApiKey: () async => storedSecret,
        writeTranslationApiKey: (value) async => storedSecret = value,
        onTranslationSettingsChanged: (settings, secret) {
          notifiedSettings = settings;
          notifiedSecret = secret;
        },
      );
      addTearDown(reloaded.dispose);
      await reloaded.loadPersistedState(enforceCacheLimit: false);
      expect(
        reloaded.translationSettings.provider,
        TranslationProviderKind.openAiCompatible,
      );
      expect(reloaded.translationSettings.scope, CustomTranslationScope.all);
      expect(reloaded.translationSettings.apiKeyConfigured, isTrue);
      expect(notifiedSecret, 'sk-secret-123');

      // Clearing key while keeping local Ollama configuration succeeds.
      await reloaded.setTranslationSettings(
        reloaded.translationSettings,
        clearApiKey: true,
      );
      expect(storedSecret, isNull);
      expect(reloaded.translationSettings.apiKeyConfigured, isFalse);
    },
  );

  testWidgets(
    'AI & Translation settings subpage configures LLM API and speech models',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = defaultTargetPlatform == TargetPlatform.windows
          ? const Size(1024, 760)
          : const Size(412, 915);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

        final fakeTranslations = _StubCustomTranslationService();
        final initialAsrCheck = Completer<void>();
        final subtitles = PlaybackSubtitleService(
          trackResolver: (_) => null,
          aiEngine: SubtitleAiEngine(
            models: _TestModelStore(initialAsrCheck.future),
            translations: fakeTranslations,
          ),
        );
        addTearDown(subtitles.dispose);

        final fixture = AppRuntimeWidgetTestFixture(
          configureSettingsRepository: (repo) {
            repo.onTranslationSettingsChanged = fakeTranslations.configure;
          },
        );
        addTearDown(fixture.dispose);
        await tester.pumpWidget(
          fixture.build(const SettingsTab(), subtitleService: subtitles),
        );
        await pumpAndSettleWithAsync(tester);

        final i18n = fixture.languageProvider;
        await tester.ensureVisible(find.text(i18n.tr('section_ai_models')));
        await tester.tap(find.text(i18n.tr('section_ai_models')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));

        final asrTile = find.byKey(const ValueKey('manage_asr_model_tile'));
        final asrDownload = find.descendant(
          of: asrTile,
          matching: find.widgetWithText(
            FilledButton,
            i18n.tr('asmr_download_action'),
          ),
        );
        final asrChecking = find.descendant(
          of: asrTile,
          matching: find.byType(CircularProgressIndicator),
        );
        final asrDelete = find.descendant(
          of: asrTile,
          matching: find.byTooltip(i18n.tr('ai_model_delete_action')),
        );
        expect(asrChecking, findsOneWidget);
        expect(asrDownload, findsNothing);
        expect(asrDelete, findsNothing);

        initialAsrCheck.complete();
        await pumpAndSettleWithAsync(tester);
        expect(asrChecking, findsNothing);
        expect(asrDownload, findsNothing);
        expect(asrDelete, findsOneWidget);

        expect(
          find.text(i18n.tr('settings_group_translation_service')),
          findsWidgets,
        );
        expect(
          find.text(i18n.tr('settings_group_speech_models')),
          findsWidgets,
        );

        expect(
          find.byKey(const ValueKey('translation_provider_tile')),
          findsOneWidget,
        );
        await tester.tap(find.text(i18n.tr('translation_provider_google')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.text(i18n.tr('translation_provider_custom')).last,
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const ValueKey('translation_scope_tile')),
          findsOneWidget,
        );

        expect(
          find.byKey(const ValueKey('translation_fill_ollama_chip')),
          findsNothing,
        );
        final endpoint = find.byKey(
          const ValueKey('translation_endpoint_field'),
        );
        await tester.ensureVisible(endpoint);
        await tester.enterText(endpoint, kDefaultOllamaApiBaseUrl);
        await tester.pump();

        final fetchModels = find.byKey(
          const ValueKey('translation_fetch_models_button'),
        );
        await Scrollable.ensureVisible(
          tester.element(fetchModels),
          alignment: 0.5,
        );
        await tester.pumpAndSettle();
        await tester.tap(fetchModels);
        await pumpAndSettleWithAsync(tester);
        expect(find.text('qwen2.5:7b'), findsOneWidget);
        await tester.tap(find.text('qwen2.5:7b'));
        await tester.pumpAndSettle();

        final testButton = find.byKey(
          const ValueKey('translation_test_button'),
        );
        await tester.ensureVisible(testButton);
        expect(find.text(i18n.tr('translation_test_connection')), findsNothing);
        expect(find.byIcon(Icons.network_check_rounded), findsOneWidget);
        expect(
          tester.getTopLeft(testButton).dx,
          tester
              .getTopLeft(find.byKey(const ValueKey('translation_prompt_field')))
              .dx,
        );
        await tester.tap(testButton);
        await pumpAndSettleWithAsync(tester);
        expect(
          find.byKey(const ValueKey('translation_test_result')),
          findsOneWidget,
        );
        expect(find.textContaining('辛苦了，今天也好好休息吧。'), findsOneWidget);

        final saveButton = find.byKey(
          const ValueKey('translation_save_button'),
        );
        await tester.ensureVisible(saveButton);
        expect(
          tester.getSize(testButton).height,
          tester.getSize(saveButton).height,
        );
        await tester.tap(saveButton);
        await pumpAndSettleWithAsync(tester);

        expect(
          fixture.settings.translationSettings.provider,
          TranslationProviderKind.openAiCompatible,
        );
        expect(
          fixture.settings.translationSettings.apiBaseUrl,
          kDefaultOllamaApiBaseUrl,
        );
        expect(fixture.settings.translationSettings.model, 'qwen2.5:7b');
        expect(
          fakeTranslations.usesCustomBackendFor(TextTranslationScene.subtitle),
          isTrue,
        );
        expect(
          fakeTranslations.usesCustomBackendFor(TextTranslationScene.browse),
          isFalse,
        );

        await tester.ensureVisible(asrTile);
        expect(asrTile, findsOneWidget);
        expect(
          find.descendant(
            of: asrTile,
            matching: find.text(i18n.tr('asr_model_kotoba_whisper_v2_desc')),
          ),
          findsOneWidget,
        );
        expect(
          find.textContaining('Kotoba-Whisper v2.0 (Q5_0)'),
          findsWidgets,
        );
        await tester.tap(find.text('Kotoba-Whisper v2.0 (Q5_0)').first);
        await pumpAndSettleWithAsync(tester);
        expect(
          find.text('Whisper Large-v3-Turbo (Q8_0)'),
          findsOneWidget,
        );
        expect(
          find.text('Whisper Large-v3 完整版 (Q5_0)'),
          findsOneWidget,
        );
        expect(
          find.text('Kotoba-Whisper v2.0 无损版 (FP16)'),
          findsOneWidget,
        );
        expect(
          find.text('Qwen3-ASR 1.7B 动漫声优微调 (Q4_K)'),
          findsOneWidget,
        );
        await tester.tap(find.text('Whisper Large-v3-Turbo (Q8_0)').last);
        await pumpAndSettleWithAsync(tester);
        expect(
          fixture.settings.selectedAsrModelId,
          SubtitleModelStore.whisperLargeV3TurboJa.id,
        );
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('manage_ctc_model_tile')),
            matching: find.text(
              i18n.tr('ai_model_status_not_downloaded', {'size': '366 MiB'}),
            ),
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
      }),
    );
}

class _StubCustomTranslationService extends TextTranslationService {
  @override
  Future<List<String>> fetchAvailableModels({
    required String apiBaseUrl,
    String? apiKey,
    bool useSavedApiKeyIfEmpty = false,
  }) async => const <String>['qwen2.5:7b', 'deepseek-chat'];

  @override
  Future<CustomTranslationTestOutcome> testCustomConfiguration({
    required TranslationServiceSettings settings,
    String? apiKey,
    bool useSavedApiKeyIfEmpty = false,
    String target = 'zh-CN',
  }) async => const CustomTranslationTestOutcome(
    sampleTranslation: '辛苦了，今天也好好休息吧。',
    elapsedMilliseconds: 42,
  );
}

class _TestModelStore extends SubtitleModelStore {
  _TestModelStore(this.initialAsrCheck);

  final Future<void> initialAsrCheck;

  @override
  Future<SubtitleModelStatus> status(SubtitleModelSpec spec) async {
    if (spec == SubtitleModelStore.japaneseAsr) await initialAsrCheck;
    return SubtitleModelStatus(
      ready: SubtitleModelStore.kotobaWhisperJa.bundleSpecs.contains(spec),
      bytes: spec.bytes,
      availableBytes: 4 * 1024 * 1024 * 1024,
    );
  }
}
