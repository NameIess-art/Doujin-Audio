import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/localization/app_language_provider.dart';
import '../../../app/state/app_runtime_providers.dart';
import '../../../core/widgets/app_feedback.dart';
import '../../../core/widgets/top_page_header.dart';
import '../application/page_translation_service.dart';
import 'library_providers.dart';

class WorkPageTranslationHost extends ConsumerStatefulWidget {
  const WorkPageTranslationHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<WorkPageTranslationHost> createState() =>
      _WorkPageTranslationHostState();
}

class _WorkPageTranslationHostState
    extends ConsumerState<WorkPageTranslationHost>
    with WidgetsBindingObserver {
  final _listeners = <String, Set<VoidCallback>>{};
  final _translations = <String, String>{};
  final _status = ValueNotifier(0);
  late final AppLanguageProvider _i18n;
  late String _target;
  Timer? _timer;
  PageTranslationRequest? _request;
  bool _enabled = false;
  bool _busy = false;
  bool _failed = false;
  bool _routeVisible = true;
  bool _foreground = true;

  bool get _active => _enabled && _routeVisible && _foreground;
  bool get _loading => _busy || _timer != null;

  String get _languageTarget => switch (_i18n.language) {
    AppLanguage.zh => 'zh-CN',
    AppLanguage.en => 'en',
    AppLanguage.ja => 'ja',
  };

  @override
  void initState() {
    super.initState();
    _i18n = ref.read(appLanguageProviderInstanceProvider);
    _target = _languageTarget;
    _i18n.addListener(_languageChanged);
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = ModalRoute.isCurrentOf(context) ?? true;
    if (visible == _routeVisible) return;
    _routeVisible = visible;
    _updateActivity();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _updateActivity();
  }

  void _languageChanged() {
    final target = _languageTarget;
    if (_target == target) return;
    _stop();
    _target = target;
    _failed = false;
    _translations.clear();
    _notifyTexts();
    _updateActivity();
  }

  void _toggle() {
    _stop();
    _enabled = !_enabled;
    _failed = false;
    _notifyTexts();
    _updateActivity();
  }

  void _updateActivity() {
    if (_active && !_failed) {
      _request ??= ref.read(pageTranslationServiceProvider).newRequest();
      _schedule();
    } else {
      _stop();
    }
    _status.value++;
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
    _request?.cancel();
    _request = null;
    _busy = false;
  }

  void _register(String text, VoidCallback listener) {
    if (!shouldTranslatePageText(text)) return;
    _listeners.putIfAbsent(text, () => {}).add(listener);
    _schedule();
  }

  void _unregister(String text, VoidCallback listener) {
    final listeners = _listeners[text];
    listeners?.remove(listener);
    if (listeners?.isEmpty == true) {
      _listeners.remove(text);
      _translations.remove(text);
    }
  }

  void _notifyTexts([Iterable<String>? texts]) {
    final listeners = <VoidCallback>{};
    for (final text in (texts ?? _listeners.keys).toList()) {
      listeners.addAll(_listeners[text] ?? {});
    }
    for (final listener in listeners) {
      listener();
    }
  }

  void _schedule() {
    if (!_active || _failed || _busy || _timer != null) return;
    if (!_listeners.keys.any((text) => !_translations.containsKey(text))) {
      return;
    }
    _timer = Timer(const Duration(milliseconds: 180), () {
      _timer = null;
      unawaited(_translate());
    });
    // Texts register during build; publish button progress after that frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _status.value++;
    });
  }

  Future<void> _translate() async {
    final request = _request;
    if (!_active || _failed || request == null || request.cancelled) return;
    final service = ref.read(pageTranslationServiceProvider);
    final missing = <String>[];
    final cached = <String>[];
    for (final text in _listeners.keys) {
      if (_translations.containsKey(text)) continue;
      final value = service.cached(text, _target);
      if (value == null) {
        missing.add(text);
      } else {
        _translations[text] = value;
        cached.add(text);
      }
    }
    _notifyTexts(cached);
    if (missing.isEmpty) {
      _status.value++;
      return;
    }
    _busy = true;
    _status.value++;
    final PageTranslationResult result;
    try {
      result = await service.translate(
        missing,
        target: _target,
        request: request,
      );
    } finally {
      if (mounted && request == _request && !request.cancelled) {
        _busy = false;
        _status.value++;
      }
    }
    if (!mounted || request != _request || request.cancelled) return;
    _translations.addEntries(
      result.translations.entries.where(
        (entry) => _listeners.containsKey(entry.key),
      ),
    );
    _notifyTexts(result.translations.keys);
    final failure = result.failure;
    if (failure != null) {
      _failed = true;
      final key = switch (failure) {
        PageTranslationFailure.unavailable => 'work_translation_unavailable',
        PageTranslationFailure.invalidResponse =>
          'work_translation_invalid_response',
        PageTranslationFailure.rateLimited => 'work_translation_rate_limited',
        PageTranslationFailure.unusualTraffic =>
          'work_translation_unusual_traffic',
      };
      showAppSnackBar(context, _i18n.tr(key), tone: AppFeedbackTone.warning);
    }
    _status.value++;
    _schedule();
  }

  @override
  void dispose() {
    _stop();
    WidgetsBinding.instance.removeObserver(this);
    _i18n.removeListener(_languageChanged);
    _status.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _WorkTranslationScope(state: this, child: widget.child);
}

class _WorkTranslationScope extends InheritedWidget {
  const _WorkTranslationScope({required this.state, required super.child});

  final _WorkPageTranslationHostState state;

  @override
  bool updateShouldNotify(_WorkTranslationScope oldWidget) =>
      state != oldWidget.state;
}

class WorkPageTranslationButton extends StatelessWidget {
  const WorkPageTranslationButton({
    super.key,
    this.buttonKey = 'work_detail_translation',
    this.backgroundOpacity = 1,
  });

  final String buttonKey;
  final double backgroundOpacity;

  @override
  Widget build(BuildContext context) {
    final state = context
        .dependOnInheritedWidgetOfExactType<_WorkTranslationScope>()!
        .state;
    return ValueListenableBuilder<int>(
      valueListenable: state._status,
      builder: (context, _, _) => HeaderFloatingButton(
        backgroundOpacity: backgroundOpacity,
        child: IconButton(
          key: ValueKey(buttonKey),
          onPressed: state._toggle,
          tooltip: state._i18n.tr(
            state._loading
                ? 'work_translation_loading'
                : state._enabled
                ? 'work_translation_original'
                : 'work_translation_translate',
          ),
          icon: state._loading
              ? SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(
                    key: ValueKey('${buttonKey}_loading'),
                    strokeWidth: 2,
                  ),
                )
              : Icon(state._enabled ? Icons.restore_rounded : Icons.translate),
        ),
      ),
    );
  }
}

class WorkPageTranslationText extends StatelessWidget {
  const WorkPageTranslationText(
    this.text, {
    super.key,
    this.fileName = false,
    this.prefix = '',
    this.style,
    this.maxLines,
    this.overflow,
  });

  final String text;
  final bool fileName;
  final String prefix;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;

  @override
  Widget build(BuildContext context) {
    final parts = pageTranslationText(text, fileName: fileName);
    return WorkPageTranslationBuilder(
      texts: [parts.source],
      builder: (context, translate, _) => Text(
        '$prefix${translate(parts.source)}${parts.suffix}',
        style: style,
        maxLines: maxLines,
        overflow: overflow,
      ),
    );
  }
}

class WorkPageTranslationBuilder extends StatefulWidget {
  const WorkPageTranslationBuilder({
    super.key,
    required this.texts,
    required this.builder,
  });

  final List<String> texts;
  final Widget Function(BuildContext, String Function(String), bool) builder;

  @override
  State<WorkPageTranslationBuilder> createState() =>
      _WorkPageTranslationBuilderState();
}

class _WorkPageTranslationBuilderState
    extends State<WorkPageTranslationBuilder> {
  _WorkPageTranslationHostState? _host;
  final _parts = <String, List<String>>{};
  Set<String> _sources = {};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bind();
  }

  @override
  void didUpdateWidget(WorkPageTranslationBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!listEquals(widget.texts, oldWidget.texts)) _bind();
  }

  void _bind() {
    final host = context
        .dependOnInheritedWidgetOfExactType<_WorkTranslationScope>()
        ?.state;
    _parts.removeWhere((text, _) => !widget.texts.contains(text));
    for (final text in widget.texts) {
      _parts.putIfAbsent(text, () => pageTranslationSegments(text));
    }
    final sources = _parts.values
        .expand((parts) => parts)
        .where(shouldTranslatePageText)
        .toSet();
    for (final source in _sources) {
      if (host != _host || !sources.contains(source)) {
        _host?._unregister(source, _changed);
      }
    }
    for (final source in sources) {
      if (host != _host || !_sources.contains(source)) {
        host?._register(source, _changed);
      }
    }
    _host = host;
    _sources = sources;
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    for (final source in _sources) {
      _host?._unregister(source, _changed);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = _host?._enabled == true;
    String translate(String text) => !enabled
        ? text
        : (_parts[text] ?? [text])
              .map((part) => _host?._translations[part] ?? part)
              .join();
    return widget.builder(context, translate, enabled);
  }
}
