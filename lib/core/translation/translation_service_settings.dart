import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';

enum TranslationProviderKind { google, openAiCompatible }

enum CustomTranslationScope { scriptAndSubtitles, all }

enum TextTranslationScene { browse, script, subtitle }

const kDefaultOllamaApiBaseUrl = 'http://127.0.0.1:11434/v1';

const kDefaultAsmrTranslationPrompt =
    '你是专业的同人音声（ASMR）与广播剧台本翻译。请将原文自然、地道地翻译为目标语言：'
    '保留角色的口语语气、情绪起伏、亲密称呼及喘息、拟声词（如耳语、亲吻、呼吸等语气词的自然表达），'
    '结合上下文统一人物人称与语境，忠实还原原意，不要添加任何解释、注释或额外说明。';

@immutable
class TranslationServiceSettings {
  const TranslationServiceSettings({
    this.provider = TranslationProviderKind.google,
    this.scope = CustomTranslationScope.scriptAndSubtitles,
    this.apiBaseUrl = '',
    this.model = '',
    this.apiKeyConfigured = false,
    this.customPrompt = '',
  });

  final TranslationProviderKind provider;
  final CustomTranslationScope scope;
  final String apiBaseUrl;
  final String model;
  final bool apiKeyConfigured;
  final String customPrompt;

  String get effectivePrompt {
    final trimmed = customPrompt.trim();
    return trimmed.isEmpty ? kDefaultAsmrTranslationPrompt : trimmed;
  }

  bool get isCustomReady =>
      provider == TranslationProviderKind.openAiCompatible &&
      resolveChatCompletionsUri(apiBaseUrl) != null &&
      model.trim().isNotEmpty;

  bool usesCustomFor(TextTranslationScene scene) =>
      provider == TranslationProviderKind.openAiCompatible &&
      (scope == CustomTranslationScope.all ||
          scene != TextTranslationScene.browse);

  String backendSignatureFor(TextTranslationScene scene) {
    if (!usesCustomFor(scene)) return 'google';
    final endpoint =
        resolveChatCompletionsUri(apiBaseUrl)?.toString() ?? apiBaseUrl.trim();
    final digest = sha256
        .convert(
          utf8.encode(jsonEncode([endpoint, model.trim(), effectivePrompt])),
        )
        .toString()
        .substring(0, 16);
    return 'llm:$digest';
  }

  static Uri? _parseValidHttpBase(String rawUrl) {
    final trimmed = rawUrl.trim();
    if (trimmed.isEmpty || trimmed.contains(RegExp(r'\s'))) return null;
    final uri = Uri.tryParse(trimmed);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      return null;
    }
    if (uri.hasPort && (uri.port < 1 || uri.port > 65535)) {
      return null;
    }
    return uri;
  }

  static String _trimTrailingSlashes(String rawPath) {
    var result = rawPath;
    while (result.endsWith('/')) {
      result = result.substring(0, result.length - 1);
    }
    return result;
  }

  static Uri? resolveChatCompletionsUri(String rawUrl) {
    final uri = _parseValidHttpBase(rawUrl);
    if (uri == null) return null;
    final cleanPath = _trimTrailingSlashes(uri.path);
    if (cleanPath.endsWith('/chat/completions')) {
      return uri.replace(path: cleanPath);
    }
    if (cleanPath.isEmpty ||
        cleanPath == '/api/chat' ||
        cleanPath == '/api/generate') {
      return uri.replace(path: '/v1/chat/completions');
    }
    return uri.replace(path: '$cleanPath/chat/completions');
  }

  static Uri? resolveModelsUri(String rawUrl) {
    final uri = _parseValidHttpBase(rawUrl);
    if (uri == null) return null;
    final cleanPath = _trimTrailingSlashes(uri.path);
    if (cleanPath.endsWith('/chat/completions')) {
      final prefix = cleanPath.substring(
        0,
        cleanPath.length - '/chat/completions'.length,
      );
      return uri.replace(path: '${prefix.isEmpty ? '/v1' : prefix}/models');
    }
    if (cleanPath.endsWith('/models')) {
      return uri.replace(path: cleanPath);
    }
    if (cleanPath.isEmpty ||
        cleanPath == '/api/chat' ||
        cleanPath == '/api/generate') {
      return uri.replace(path: '/v1/models');
    }
    return uri.replace(path: '$cleanPath/models');
  }

  static Uri? resolveOllamaTagsUri(String rawUrl) {
    final uri = _parseValidHttpBase(rawUrl);
    if (uri == null) return null;
    return Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: '/api/tags',
    );
  }

  void validate() {
    if (provider == TranslationProviderKind.google) return;
    if (resolveChatCompletionsUri(apiBaseUrl) == null) {
      throw const FormatException('Invalid translation API endpoint URL');
    }
    if (model.trim().isEmpty) {
      throw const FormatException('Translation model name is required');
    }
  }

  TranslationServiceSettings copyWith({
    TranslationProviderKind? provider,
    CustomTranslationScope? scope,
    String? apiBaseUrl,
    String? model,
    bool? apiKeyConfigured,
    String? customPrompt,
  }) => TranslationServiceSettings(
    provider: provider ?? this.provider,
    scope: scope ?? this.scope,
    apiBaseUrl: apiBaseUrl ?? this.apiBaseUrl,
    model: model ?? this.model,
    apiKeyConfigured: apiKeyConfigured ?? this.apiKeyConfigured,
    customPrompt: customPrompt ?? this.customPrompt,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'provider': provider.name,
    'scope': scope.name,
    'apiBaseUrl': apiBaseUrl,
    'model': model,
    'apiKeyConfigured': apiKeyConfigured,
    'customPrompt': customPrompt,
  };

  factory TranslationServiceSettings.fromJson(Object? value) {
    if (value is! Map) return const TranslationServiceSettings();
    return TranslationServiceSettings(
      provider:
          TranslationProviderKind.values
              .where((item) => item.name == value['provider'])
              .firstOrNull ??
          TranslationProviderKind.google,
      scope:
          CustomTranslationScope.values
              .where((item) => item.name == value['scope'])
              .firstOrNull ??
          CustomTranslationScope.scriptAndSubtitles,
      apiBaseUrl: (value['apiBaseUrl'] as String? ?? '').trim(),
      model: (value['model'] as String? ?? '').trim(),
      apiKeyConfigured: value['apiKeyConfigured'] as bool? ?? false,
      customPrompt: value['customPrompt'] as String? ?? '',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is TranslationServiceSettings &&
      other.provider == provider &&
      other.scope == scope &&
      other.apiBaseUrl == apiBaseUrl &&
      other.model == model &&
      other.apiKeyConfigured == apiKeyConfigured &&
      other.customPrompt == customPrompt;

  @override
  int get hashCode => Object.hash(
    provider,
    scope,
    apiBaseUrl,
    model,
    apiKeyConfigured,
    customPrompt,
  );
}
