part of 'settings_tab.dart';

class _AiSettingsControls extends ConsumerStatefulWidget {
  const _AiSettingsControls({required this.buildSections});

  final Widget Function(List<Widget>) buildSections;

  @override
  ConsumerState<_AiSettingsControls> createState() =>
      _AiSettingsControlsState();
}

class _AiSettingsControlsState extends ConsumerState<_AiSettingsControls> {
  late TranslationProviderKind _provider;
  late CustomTranslationScope _scope;
  late final TextEditingController _endpoint;
  final TextEditingController _apiKey = TextEditingController();
  late final TextEditingController _model;
  late final TextEditingController _prompt;
  bool _obscureApiKey = true;
  bool _clearStoredApiKey = false;
  bool _saving = false;
  bool _validateCustom = false;
  bool _fetchingModels = false;
  bool _testing = false;
  CustomTranslationTestOutcome? _testOutcome;

  SettingsRepository get _settings => ref.read(settingsRepositoryProvider);

  @override
  void initState() {
    super.initState();
    final initial = _settings.translationSettings;
    _provider = initial.provider;
    _scope = initial.scope;
    _endpoint = TextEditingController(text: initial.apiBaseUrl);
    _model = TextEditingController(text: initial.model);
    _prompt = TextEditingController(text: initial.customPrompt);
  }

  @override
  void dispose() {
    for (final controller in [_endpoint, _apiKey, _model, _prompt]) {
      controller.dispose();
    }
    super.dispose();
  }

  String _languageTarget(AppLanguage language) => switch (language) {
    AppLanguage.zh => 'zh-CN',
    AppLanguage.en => 'en',
    AppLanguage.ja => 'ja',
  };

  TranslationServiceSettings _draftSettings(TranslationServiceSettings saved) =>
      saved.copyWith(
        provider: _provider,
        scope: _scope,
        apiBaseUrl: _endpoint.text.trim(),
        model: _model.text.trim(),
        customPrompt: _prompt.text.trim(),
      );

  String _failureKey(TextTranslationFailure failure) => switch (failure) {
    TextTranslationFailure.unavailable => 'work_translation_unavailable',
    TextTranslationFailure.invalidResponse =>
      'work_translation_invalid_response',
    TextTranslationFailure.rateLimited => 'work_translation_rate_limited',
    TextTranslationFailure.unusualTraffic => 'work_translation_unusual_traffic',
    TextTranslationFailure.unauthorized => 'work_translation_unauthorized',
    TextTranslationFailure.misconfigured => 'work_translation_misconfigured',
  };

  Future<void> _selectProvider(
    TranslationProviderKind provider,
    TranslationServiceSettings saved,
  ) async {
    if (_saving || _provider == provider) return;
    if (provider == TranslationProviderKind.google) {
      setState(() {
        _saving = true;
        _testOutcome = null;
      });
      try {
        final ok = await saveSettingsWithFeedback(
          context,
          () => _settings.setTranslationSettings(
            saved.copyWith(provider: TranslationProviderKind.google),
          ),
        );
        if (ok && mounted) {
          setState(() => _provider = TranslationProviderKind.google);
        }
      } finally {
        if (mounted) setState(() => _saving = false);
      }
      return;
    }
    setState(() {
      _provider = provider;
      _validateCustom = false;
      _testOutcome = null;
    });
  }

  Future<void> _applyCustomSettings(TranslationServiceSettings saved) async {
    if (_saving) return;
    setState(() {
      _validateCustom = true;
      _testOutcome = null;
    });
    final candidate = _draftSettings(
      saved,
    ).copyWith(provider: TranslationProviderKind.openAiCompatible);
    try {
      candidate.validate();
    } on FormatException {
      return;
    }
    setState(() => _saving = true);
    try {
      final ok = await saveSettingsWithFeedback(
        context,
        () => _settings.setTranslationSettings(
          candidate,
          apiKey: _apiKey.text,
          clearApiKey: _clearStoredApiKey && _apiKey.text.trim().isEmpty,
        ),
      );
      if (ok && mounted) {
        setState(() {
          _apiKey.clear();
          _clearStoredApiKey = false;
          _validateCustom = false;
        });
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _fetchModels() async {
    if (_fetchingModels || _saving) return;
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final url = _endpoint.text.trim();
    if (TranslationServiceSettings.resolveModelsUri(url) == null) {
      setState(() => _validateCustom = true);
      return;
    }
    setState(() => _fetchingModels = true);
    final List<String> models;
    try {
      models = await ref
          .read(textTranslationServiceProvider)
          .fetchAvailableModels(
            apiBaseUrl: url,
            apiKey: _apiKey.text,
            useSavedApiKeyIfEmpty: !_clearStoredApiKey,
          );
    } on TextTranslationFailure catch (failure) {
      if (!mounted) return;
      setState(() => _fetchingModels = false);
      showAppSnackBar(
        context,
        i18n.tr(_failureKey(failure)),
        tone: AppFeedbackTone.warning,
      );
      return;
    } finally {
      if (mounted && _fetchingModels) {
        setState(() => _fetchingModels = false);
      }
    }
    if (!mounted) return;
    if (models.isEmpty) {
      showAppSnackBar(
        context,
        i18n.tr('translation_models_empty'),
        tone: AppFeedbackTone.warning,
      );
      return;
    }
    final selected = await showAppDialog<String>(
      context: context,
      builder: (dialogContext) => AppDialog(
        title: i18n.tr('translation_select_model_title'),
        icon: Icons.auto_awesome_outlined,
        scrollable: true,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final item in models)
              ListTile(
                dense: true,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                title: Text(item),
                trailing: item == _model.text.trim()
                    ? Icon(
                        Icons.check_rounded,
                        color: Theme.of(dialogContext).colorScheme.primary,
                      )
                    : null,
                onTap: () => Navigator.pop(dialogContext, item),
              ),
          ],
        ),
        actions: AppDialogActions(
          children: [
            AppSecondaryButton(
              onPressed: () => Navigator.pop(dialogContext),
              label: i18n.tr('cancel'),
            ),
          ],
        ),
      ),
    );
    if (mounted && selected != null) {
      setState(() {
        _model.text = selected;
        _testOutcome = null;
      });
    }
  }

  Future<void> _testTranslation(TranslationServiceSettings saved) async {
    if (_testing || _saving) return;
    setState(() {
      _validateCustom = true;
      _testing = true;
      _testOutcome = null;
    });
    final candidate = _draftSettings(
      saved,
    ).copyWith(provider: TranslationProviderKind.openAiCompatible);
    if (!candidate.isCustomReady) {
      setState(() => _testing = false);
      return;
    }
    try {
      final i18n = ref.read(appLanguageProviderInstanceProvider);
      final outcome = await ref
          .read(textTranslationServiceProvider)
          .testCustomConfiguration(
            settings: candidate,
            apiKey: _apiKey.text,
            useSavedApiKeyIfEmpty: !_clearStoredApiKey,
            target: _languageTarget(i18n.language),
          );
      if (mounted) {
        setState(() => _testOutcome = outcome);
      }
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final (savedTranslation, selectedAsrId) = ref.watch(
      settingsStateProvider.select(
        (state) => (
          state.value?.translationSettings ?? _settings.translationSettings,
          state.value?.selectedAsrModelId ?? _settings.selectedAsrModelId,
        ),
      ),
    );
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final tokens = AppDesignTokens.of(context);
    final subtitles = ref.watch(playbackSubtitleServiceProvider);
    final activeAsr = SubtitleModelStore.resolveAsrModel(selectedAsrId);
    final unavailableReason = subtitleGenerationUnavailableReason;
    final isCustom = _provider == TranslationProviderKind.openAiCompatible;
    final providerLabels = <TranslationProviderKind, String>{
      TranslationProviderKind.google: i18n.tr('translation_provider_google'),
      TranslationProviderKind.openAiCompatible: i18n.tr(
        'translation_provider_custom',
      ),
    };
    final scopeLabels = <CustomTranslationScope, String>{
      CustomTranslationScope.scriptAndSubtitles: i18n.tr(
        'translation_scope_script_subtitles',
      ),
      CustomTranslationScope.all: i18n.tr('translation_scope_all'),
    };
    final inlineActionStyle = appTextButtonStyle(
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: const Size(0, 32),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
        textStyle: theme.textTheme.labelMedium?.copyWith(
          fontWeight: FontWeight.w600,
        ),
      ),
    );
    Widget cardBlock(
      Widget child, {
      EdgeInsets padding = const EdgeInsets.all(16),
    }) => ColoredBox(
      color: cs.surfaceContainerLow,
      child: Padding(padding: padding, child: child),
    );

    bool isEndpointInvalid() =>
        TranslationServiceSettings.resolveChatCompletionsUri(_endpoint.text) ==
        null;
    bool isModelInvalid() => _model.text.trim().isEmpty;

    return widget.buildSections([
      _SettingsSectionCard(
        title: i18n.tr('settings_group_translation_service'),
        children: [
          ListTile(
            key: const ValueKey('translation_provider_tile'),
            leading: _settingsIcon(Icons.translate_rounded, cs.primary),
            title: LayoutBuilder(
              builder: (context, constraints) => Row(
                children: [
                  Expanded(
                    child: _settingsTitle(
                      i18n.tr('settings_group_translation_service'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  _settingsDropdown<TranslationProviderKind>(
                    context,
                    value: _provider,
                    maxWidth: constraints.maxWidth * 0.58,
                    onChanged: _saving
                        ? null
                        : (value) {
                            if (value != null) {
                              unawaited(
                                _selectProvider(value, savedTranslation),
                              );
                            }
                          },
                    items: [
                      for (final provider in TranslationProviderKind.values)
                        DropdownMenuItem<TranslationProviderKind>(
                          value: provider,
                          child: _settingsDropdownText(
                            providerLabels[provider]!,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            contentPadding: const EdgeInsets.symmetric(horizontal: 8),
          ),
          if (isCustom) ...[
            ListTile(
              key: const ValueKey('translation_scope_tile'),
              leading: _settingsIcon(Icons.layers_outlined, cs.primary),
              title: LayoutBuilder(
                builder: (context, constraints) => Row(
                  children: [
                    Expanded(
                      child: _settingsTitle(i18n.tr('translation_scope_label')),
                    ),
                    const SizedBox(width: 12),
                    _settingsDropdown<CustomTranslationScope>(
                      context,
                      value: _scope,
                      maxWidth: constraints.maxWidth * 0.58,
                      onChanged: _saving
                          ? null
                          : (value) {
                              if (value != null) {
                                setState(() => _scope = value);
                              }
                            },
                      items: [
                        for (final scope in CustomTranslationScope.values)
                          DropdownMenuItem<CustomTranslationScope>(
                            value: scope,
                            child: _settingsDropdownText(scopeLabels[scope]!),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            cardBlock(
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ListenableBuilder(
                    listenable: _endpoint,
                    builder: (context, _) => TextField(
                      key: const ValueKey('translation_endpoint_field'),
                      contextMenuBuilder: buildAppEditableTextMenu,
                      controller: _endpoint,
                      enabled: !_saving,
                      autocorrect: false,
                      decoration: InputDecoration(
                        labelText: i18n.tr('translation_api_endpoint'),
                        hintText: kDefaultOllamaApiBaseUrl,
                        errorText: _validateCustom && isEndpointInvalid()
                            ? i18n.tr('network_invalid_value')
                            : null,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _apiKey,
                    builder: (context, keyVal, _) {
                      final hasStoredKey =
                          savedTranslation.apiKeyConfigured &&
                          !_clearStoredApiKey;
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          TextField(
                            key: const ValueKey('translation_api_key_field'),
                            contextMenuBuilder: buildAppEditableTextMenu,
                            controller: _apiKey,
                            enabled: !_saving,
                            obscureText: _obscureApiKey,
                            enableSuggestions: false,
                            autocorrect: false,
                            decoration: InputDecoration(
                              labelText: i18n.tr('translation_api_key'),
                              hintText: i18n.tr(
                                hasStoredKey
                                    ? 'translation_api_key_keep'
                                    : 'translation_api_key_optional_hint',
                              ),
                              suffixIcon: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (hasStoredKey && keyVal.text.isEmpty)
                                    IconButton(
                                      key: const ValueKey(
                                        'translation_clear_api_key',
                                      ),
                                      tooltip: i18n.tr(
                                        'translation_api_key_clear',
                                      ),
                                      onPressed: _saving
                                          ? null
                                          : () => setState(
                                              () => _clearStoredApiKey = true,
                                            ),
                                      icon: const Icon(Icons.clear_rounded),
                                    ),
                                  IconButton(
                                    tooltip: i18n.tr(
                                      _obscureApiKey
                                          ? 'show_password'
                                          : 'hide_password',
                                    ),
                                    onPressed: _saving
                                        ? null
                                        : () => setState(
                                            () => _obscureApiKey =
                                                !_obscureApiKey,
                                          ),
                                    icon: Icon(
                                      _obscureApiKey
                                          ? Icons.visibility_outlined
                                          : Icons.visibility_off_outlined,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          if (_clearStoredApiKey && keyVal.text.isEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              i18n.tr('translation_api_key_will_clear'),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: tokens.warning,
                              ),
                            ),
                          ],
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 12),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: ValueListenableBuilder<TextEditingValue>(
                          valueListenable: _model,
                          builder: (context, _, _) => TextField(
                            key: const ValueKey('translation_model_field'),
                            contextMenuBuilder: buildAppEditableTextMenu,
                            controller: _model,
                            enabled: !_saving,
                            autocorrect: false,
                            decoration: InputDecoration(
                              labelText: i18n.tr('translation_model_name'),
                              hintText: 'qwen2.5:7b / gpt-4o-mini',
                              errorText: _validateCustom && isModelInvalid()
                                  ? i18n.tr('network_invalid_value')
                                  : null,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Padding(
                        padding: EdgeInsets.zero,
                        child: FilledButton.tonal(
                          key: const ValueKey(
                            'translation_fetch_models_button',
                          ),
                          style: _aiCompactTonalButtonStyle(
                            context,
                            height: 44,
                          ),
                          onPressed: _saving || _fetchingModels
                              ? null
                              : _fetchModels,
                          child: _fetchingModels
                              ? const SizedBox.square(
                                  dimension: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Text(i18n.tr('translation_fetch_models')),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            cardBlock(
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _prompt,
                    builder: (context, promptVal, _) => Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TextField(
                          key: const ValueKey('translation_prompt_field'),
                          contextMenuBuilder: buildAppEditableTextMenu,
                          controller: _prompt,
                          enabled: !_saving,
                          minLines: 3,
                          maxLines: 5,
                          decoration: InputDecoration(
                            labelText: i18n.tr('translation_custom_prompt'),
                            hintText: i18n.tr(
                              'translation_prompt_default_hint',
                            ),
                            alignLabelWithHint: true,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Wrap(
                          alignment: WrapAlignment.end,
                          spacing: 4,
                          children: [
                            TextButton(
                              key: const ValueKey(
                                'translation_prompt_fill_default',
                              ),
                              style: inlineActionStyle,
                              onPressed: _saving
                                  ? null
                                  : () => setState(() {
                                      _prompt.text =
                                          kDefaultAsmrTranslationPrompt;
                                      _testOutcome = null;
                                    }),
                              child: Text(
                                i18n.tr('translation_prompt_fill_default'),
                              ),
                            ),
                            if (promptVal.text.trim().isNotEmpty)
                              TextButton(
                                key: const ValueKey('translation_prompt_reset'),
                                style: inlineActionStyle,
                                onPressed: _saving
                                    ? null
                                    : () => setState(() {
                                        _prompt.clear();
                                        _testOutcome = null;
                                      }),
                                child: Text(i18n.tr('restore_default')),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  ListenableBuilder(
                    listenable: Listenable.merge([
                      _endpoint,
                      _apiKey,
                      _model,
                      _prompt,
                    ]),
                    builder: (context, _) {
                      final hasUnsaved =
                          _provider != savedTranslation.provider ||
                          _scope != savedTranslation.scope ||
                          _endpoint.text.trim() !=
                              savedTranslation.apiBaseUrl ||
                          _model.text.trim() != savedTranslation.model ||
                          _prompt.text.trim() !=
                              savedTranslation.customPrompt ||
                          _apiKey.text.trim().isNotEmpty ||
                          _clearStoredApiKey;
                      return AnimatedSectionReveal(
                        visible: hasUnsaved,
                        builder: (context) => Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Row(
                            children: [
                              Icon(
                                Icons.info_outline_rounded,
                                size: 16,
                                color: tokens.warning,
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  i18n.tr('translation_unsaved_changes'),
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: tokens.warning,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: AppConnectionTestButton(
                            key: const ValueKey('translation_test_button'),
                            tooltip: i18n.tr('translation_test_connection'),
                            isTesting: _testing,
                            onPressed: _saving
                                ? null
                                : () => _testTranslation(savedTranslation),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: AppPrimaryButton(
                          key: const ValueKey('translation_save_button'),
                          label: i18n.tr('translation_apply_settings'),
                          isLoading: _saving,
                          onPressed: _saving
                              ? null
                              : () => _applyCustomSettings(savedTranslation),
                        ),
                      ),
                    ],
                  ),
                  if (_testOutcome case final outcome?) ...[
                    const SizedBox(height: 12),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: (outcome.isSuccess ? tokens.success : cs.error)
                            .withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(
                          tokens.radiusControl,
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(top: 1),
                              child: Icon(
                                outcome.isSuccess
                                    ? Icons.check_circle_outline_rounded
                                    : Icons.error_outline_rounded,
                                size: 16,
                                color: outcome.isSuccess
                                    ? tokens.success
                                    : cs.error,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: SelectableText(
                                key: const ValueKey('translation_test_result'),
                                contextMenuBuilder: buildAppEditableTextMenu,
                                outcome.isSuccess
                                    ? i18n.tr('translation_test_success', {
                                        'ms':
                                            '${outcome.elapsedMilliseconds ?? 0}',
                                        'sample': outcome.sampleTranslation!,
                                      })
                                    : i18n.tr(_failureKey(outcome.failure!)),
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: outcome.isSuccess
                                      ? tokens.success
                                      : cs.error,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
      _SettingsSectionCard(
        title: i18n.tr('settings_group_speech_models'),
        children: [
          if (unavailableReason != null)
            cardBlock(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              Text(
                i18n.tr(unavailableReason),
                style: theme.textTheme.bodySmall?.copyWith(color: cs.error),
              ),
            ),
          ListTile(
            leading: _settingsIcon(Icons.graphic_eq_rounded, cs.primary),
            title: LayoutBuilder(
              builder: (context, constraints) => Row(
                children: [
                  Expanded(
                    child: _settingsTitle(i18n.tr('asr_active_model_label')),
                  ),
                  const SizedBox(width: 12),
                  _settingsDropdown<String>(
                    context,
                    value: activeAsr.id,
                    maxWidth: constraints.maxWidth * 0.58,
                    onChanged: unavailableReason != null
                        ? null
                        : (value) {
                            if (value != null) {
                              unawaited(
                                saveSettingsWithFeedback(
                                  context,
                                  () => _settings.setSelectedAsrModelId(value),
                                ),
                              );
                            }
                          },
                    items: [
                      for (final item in SubtitleModelStore.builtInAsrModels)
                        DropdownMenuItem<String>(
                          value: item.id,
                          child: _settingsDropdownText(i18n.tr(item.titleKey)),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            contentPadding: const EdgeInsets.symmetric(horizontal: 8),
          ),
          _LocalSubtitleModelManageTile(
            tileKey: const ValueKey('manage_asr_model_tile'),
            icon: Icons.record_voice_over_outlined,
            title: i18n.tr(activeAsr.titleKey),
            description: activeAsr.descriptionKey == null
                ? null
                : i18n.tr(activeAsr.descriptionKey!),
            specs: activeAsr.bundleSpecs,
            subtitles: subtitles,
            taskKind: SubtitleDraftKind.transcription,
            unavailable: unavailableReason != null,
            onDelete: () => subtitles.modelStore.deleteAsrModel(activeAsr),
          ),
          _LocalSubtitleModelManageTile(
            tileKey: const ValueKey('manage_ctc_model_tile'),
            icon: Icons.subtitles_outlined,
            title: i18n.tr('subtitle_ctc_model_title'),
            specs: const <SubtitleModelSpec>[SubtitleModelStore.japaneseCtc],
            subtitles: subtitles,
            taskKind: SubtitleDraftKind.script,
            unavailable: unavailableReason != null,
            onDelete: () => subtitles.modelStore.deleteBundle(
              const <SubtitleModelSpec>[SubtitleModelStore.japaneseCtc],
            ),
          ),
        ],
      ),
    ]);
  }
}

class _LocalSubtitleModelManageTile extends ConsumerStatefulWidget {
  const _LocalSubtitleModelManageTile({
    required this.tileKey,
    required this.icon,
    required this.title,
    this.description,
    required this.specs,
    required this.subtitles,
    required this.taskKind,
    required this.unavailable,
    required this.onDelete,
  });

  final Key tileKey;
  final IconData icon;
  final String title;
  final String? description;
  final List<SubtitleModelSpec> specs;
  final PlaybackSubtitleService subtitles;
  final SubtitleDraftKind taskKind;
  final bool unavailable;
  final Future<int> Function() onDelete;

  @override
  ConsumerState<_LocalSubtitleModelManageTile> createState() =>
      _LocalSubtitleModelManageTileState();
}

class _LocalSubtitleModelManageTileState
    extends ConsumerState<_LocalSubtitleModelManageTile> {
  Future<SubtitleModelStatus>? _statusFuture;
  bool _deleting = false;
  late Listenable _mergedListenable;

  SubtitleModelStore get _store => widget.subtitles.modelStore;

  @override
  void initState() {
    super.initState();
    _mergedListenable = Listenable.merge([widget.subtitles, _store]);
    _mergedListenable.addListener(_handleStoreChanged);
    _refreshStatus();
  }

  @override
  void didUpdateWidget(covariant _LocalSubtitleModelManageTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.subtitles, widget.subtitles) ||
        !listEquals(oldWidget.specs, widget.specs)) {
      _mergedListenable.removeListener(_handleStoreChanged);
      _mergedListenable = Listenable.merge([widget.subtitles, _store]);
      _mergedListenable.addListener(_handleStoreChanged);
      _refreshStatus();
    }
  }

  @override
  void dispose() {
    _mergedListenable.removeListener(_handleStoreChanged);
    super.dispose();
  }

  void _handleStoreChanged() {
    if (!mounted) return;
    final active = _store.bundleSnapshot(widget.specs).active;
    if (!active) {
      _statusFuture = _store.bundleStatus(widget.specs);
    }
    setState(() {});
  }

  void _refreshStatus() {
    _statusFuture = _store.bundleStatus(widget.specs);
  }

  Future<void> _startDownload() async {
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    try {
      await _store.ensureBundle(widget.specs);
      if (mounted) {
        setState(_refreshStatus);
      }
    } on SubtitleModelDownloadCancelled {
      if (mounted) {
        setState(_refreshStatus);
      }
    } catch (_) {
      if (!mounted) return;
      setState(_refreshStatus);
      showAppSnackBar(
        context,
        i18n.tr('subtitle_model_download_failed'),
        tone: AppFeedbackTone.warning,
      );
    }
  }

  Future<void> _confirmDelete() async {
    if (_deleting) return;
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final confirmed = await showConfirmActionDialog(
      context: context,
      title: i18n.tr('ai_model_delete_title'),
      message: i18n.tr('ai_model_delete_message', {'name': widget.title}),
      cancelLabel: i18n.tr('cancel'),
      confirmLabel: i18n.tr('ai_model_delete_action'),
      icon: Icons.delete_outline_rounded,
      confirmColor: Theme.of(context).colorScheme.error,
    );
    if (!confirmed || !mounted) return;
    setState(() => _deleting = true);
    try {
      await widget.onDelete();
      if (!mounted) return;
      setState(_refreshStatus);
      showAppSnackBar(
        context,
        i18n.tr('ai_model_deleted'),
        tone: AppFeedbackTone.success,
      );
    } catch (_) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        i18n.tr('operation_failed_retry'),
        tone: AppFeedbackTone.destructive,
      );
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final cs = Theme.of(context).colorScheme;
    final totalBytes = widget.specs.fold<int>(
      0,
      (sum, spec) => sum + spec.bytes,
    );
    final sizeMiB = (totalBytes / 1048576).ceil();
    final progress = _store.bundleSnapshot(widget.specs);
    final inUse = widget.subtitles.isModelTaskRunningFor(widget.taskKind);

    return FutureBuilder<SubtitleModelStatus>(
      future: _statusFuture,
      builder: (context, snapshot) {
        final ready = snapshot.data?.ready ?? false;
        final downloading = progress.active;

        final Widget statusSubtitle;
        if (downloading) {
          statusSubtitle = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 6),
              LinearProgressIndicator(value: progress.fraction),
              const SizedBox(height: 4),
              Text(
                i18n.tr('subtitle_model_download_progress', {
                  'received': (progress.received / 1048576).toStringAsFixed(1),
                  'total': (progress.total / 1048576).toStringAsFixed(1),
                }),
              ),
            ],
          );
        } else {
          final baseStatus = inUse
              ? i18n.tr('ai_model_status_in_use')
              : ready
              ? i18n.tr('ai_model_status_ready', {'size': '$sizeMiB MiB'})
              : i18n.tr('ai_model_status_not_downloaded', {
                  'size': '$sizeMiB MiB',
                });
          final desc = widget.description?.trim() ?? '';
          statusSubtitle = Text(
            desc.isEmpty || inUse ? baseStatus : '$baseStatus · $desc',
          );
        }

        final Widget trailing;
        if (downloading) {
          trailing = TextButton(
            key: ValueKey('${widget.tileKey}_cancel'),
            onPressed: () => _store.cancelBundleDownload(widget.specs),
            child: Text(i18n.tr('cancel')),
          );
        } else if (ready) {
          trailing = IconButton(
            key: ValueKey('${widget.tileKey}_delete'),
            tooltip: i18n.tr('ai_model_delete_action'),
            onPressed: inUse || _deleting || widget.unavailable
                ? null
                : _confirmDelete,
            icon: Icon(
              Icons.delete_outline_rounded,
              color: inUse ? cs.onSurfaceVariant : cs.error,
            ),
          );
        } else {
          trailing = FilledButton.tonal(
            key: ValueKey('${widget.tileKey}_download'),
            style: _aiCompactTonalButtonStyle(context, height: 40),
            onPressed: widget.unavailable || _deleting ? null : _startDownload,
            child: Text(i18n.tr('asmr_download_action')),
          );
        }

        return ListTile(
          key: widget.tileKey,
          leading: _settingsIcon(widget.icon, cs.primary),
          title: _SettingsTitleBlock(
            title: widget.title,
            subtitle: statusSubtitle,
          ),
          trailing: trailing,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 8,
            vertical: 4,
          ),
        );
      },
    );
  }
}

ButtonStyle _aiCompactTonalButtonStyle(
  BuildContext context, {
  required double height,
}) {
  final theme = Theme.of(context);
  final cs = theme.colorScheme;
  return appSurfaceButtonStyle(
    style: FilledButton.styleFrom(
      minimumSize: Size(64, height),
      padding: const EdgeInsets.symmetric(horizontal: 14),
    ),
    colorScheme: cs,
    platform: theme.platform,
    defaultBackgroundColor: cs.secondaryContainer,
    animationDuration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 130),
  );
}
