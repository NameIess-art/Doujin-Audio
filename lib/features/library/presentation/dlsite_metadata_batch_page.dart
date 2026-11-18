import 'library_providers.dart';
import '../../settings/presentation/settings_providers.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/app_buttons.dart';
import '../../../app/state/app_runtime_providers.dart';
import '../../../app/theme/app_styles.dart';
import '../../../core/media/audio_detail.dart';
import '../../../core/ui/ui_operation_service.dart';
import '../application/dlsite_metadata_batch_session.dart';
import '../domain/audio_library_category.dart';
import '../../../core/widgets/app_transitions.dart';
import '../../../core/widgets/mobile_overlay_inset.dart';
import '../../../core/widgets/page_header_inset.dart';
import '../../../core/widgets/top_page_header.dart';

import 'dlsite_metadata_batch_setup.dart';
import 'dlsite_metadata_work_picker_page.dart';
import 'dlsite_metadata_batch_results_page.dart';

export 'dlsite_metadata_batch_setup.dart' show DlsiteMetadataBatchScope;
export 'dlsite_metadata_work_picker_page.dart'
    show DlsiteMetadataWorkPickerPage;
export 'dlsite_metadata_batch_results_page.dart'
    show DlsiteMetadataBatchResultsPage;
export 'dlsite_metadata_batch_review_page.dart'
    show DlsiteMetadataBatchReviewPage;

class DlsiteMetadataBatchPage extends ConsumerStatefulWidget {
  const DlsiteMetadataBatchPage({
    super.key,
    this.entries,
    this.initialTargets,
    this.initialScope = DlsiteMetadataBatchScope.anyMissing,
  });

  final List<AudioLibraryCategoryEntry>? entries;
  final Set<AudioDetailTarget>? initialTargets;
  final DlsiteMetadataBatchScope initialScope;

  @override
  ConsumerState<DlsiteMetadataBatchPage> createState() =>
      _DlsiteMetadataBatchPageState();
}

class _DlsiteMetadataBatchPageState
    extends ConsumerState<DlsiteMetadataBatchPage> {
  List<AudioLibraryCategoryEntry> _entries =
      const <AudioLibraryCategoryEntry>[];
  List<AudioLibraryCategoryEntry> _specificEntries =
      const <AudioLibraryCategoryEntry>[];
  late DlsiteMetadataBatchScope _scope;
  Object? _error;
  final GlobalKey _headerKey = GlobalKey();
  double _headerHeight = 0;
  bool _headerMeasurementScheduled = false;

  void _scheduleHeaderMeasurement() {
    if (_headerMeasurementScheduled) return;
    _headerMeasurementScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _headerMeasurementScheduled = false;
      if (!mounted) return;
      final box = _headerKey.currentContext?.findRenderObject() as RenderBox?;
      if (box == null) return;
      final h = box.size.height;
      if (h > 0 && (_headerHeight == 0 || (h - _headerHeight).abs() > 0.5)) {
        setState(() => _headerHeight = h);
      }
    });
  }
  bool _loading = false;

  List<AudioLibraryCategoryEntry> get _anyMissingEntries => _entries
      .where((entry) => entry.detail.hasMissingMetadata)
      .toList(growable: false);

  List<AudioLibraryCategoryEntry> get _noMetadataEntries => _entries
      .where((entry) => entry.detail.hasNoMetadata)
      .toList(growable: false);

  List<AudioLibraryCategoryEntry> get _hasRjCodeEntries =>
      _entries.where((entry) => entry.detail.hasRjCode).toList(growable: false);

  List<AudioLibraryCategoryEntry> get _selectedEntries => switch (_scope) {
    DlsiteMetadataBatchScope.anyMissing => _anyMissingEntries,
    DlsiteMetadataBatchScope.noMetadata => _noMetadataEntries,
    DlsiteMetadataBatchScope.hasRjCode => _hasRjCodeEntries,
    DlsiteMetadataBatchScope.all => _entries,
    DlsiteMetadataBatchScope.specific => _specificEntries,
  };

  @override
  void initState() {
    super.initState();
    _scope = widget.initialScope;
    final entries = widget.entries;
    if (entries != null) {
      _entries = entries;
    } else {
      _loading = true;
      final cachedSnapshot = ref.read(libraryFacadeProvider).categorySnapshot;
      if (cachedSnapshot != null) {
        final initialTargets = widget.initialTargets;
        _entries = initialTargets == null
            ? cachedSnapshot.entries
            : cachedSnapshot.entries
                  .where((entry) => initialTargets.contains(entry.target))
                  .toList(growable: false);
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_load());
      });
    }
  }

  Future<void> _pickSpecific() async {
    final result = await Navigator.of(context)
        .push<List<AudioLibraryCategoryEntry>>(
          buildAppPageRoute(
            context: context,
            child: DlsiteMetadataWorkPickerPage(
              entries: _entries,
              initialSelection: _specificEntries,
            ),
          ),
        );
    if (!mounted) return;
    if (result != null) {
      setState(() {
        _specificEntries = result;
        _scope = DlsiteMetadataBatchScope.specific;
      });
    }
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
      _loading = true;
    });
    try {
      final snapshot = await ref
          .read(uiOperationServiceProvider)
          .run<AudioLibraryCategorySnapshot>(
            scope: UiOperationScope.metadataBatch,
            labelKey: 'batch_metadata',
            task: (_) =>
                ref.read(libraryFacadeProvider).audioLibraryCategorySnapshot(),
          );
      if (!mounted) return;
      final initialTargets = widget.initialTargets;
      final loadedEntries = initialTargets == null
          ? snapshot.entries
          : snapshot.entries
                .where((entry) => initialTargets.contains(entry.target))
                .toList(growable: false);
      setState(() {
        _entries = loadedEntries;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  Future<void> _run() async {
    final queue = List<AudioLibraryCategoryEntry>.of(_selectedEntries);
    if (queue.isEmpty) return;
    final language = ref
        .read(settingsRepositoryProvider)
        .slice
        .state
        .dlsiteMetadataLanguage
        .resolve(
          ProviderScope.containerOf(
            context,
            listen: false,
          ).read(appLanguageProviderInstanceProvider).language,
        );
    final session = DlsiteMetadataBatchSession.forLibrary(
      entries: queue,
      library: ref.read(libraryFacadeProvider),
      language: language,
    );
    await Navigator.of(context).push<void>(
      buildAppPageRoute(
        context: context,
        child: DlsiteMetadataBatchResultsPage(session: session),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(appLanguageStateProvider);
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final cs = Theme.of(context).colorScheme;
    final canStart = !_loading && _selectedEntries.isNotEmpty;
    final startForeground = canStart
        ? cs.onPrimary
        : cs.onSurface.withValues(alpha: 0.38);
    _scheduleHeaderMeasurement();
    final effectiveHeaderHeight = _headerHeight > 0
        ? _headerHeight
        : (_error == null
              ? MediaQuery.paddingOf(context).top + 140.0
              : AppPageHeaderMetrics.headerHeight(context));
    final contentTopInset =
        effectiveHeaderHeight + AppPageHeaderMetrics.firstContentSpacing;
    final bottomInset =
        MediaQuery.paddingOf(context).bottom + MobileOverlayInset.of(context);
    return Scaffold(
      backgroundColor: cs.surface,
      body: PageHeaderInset(
        topInset: contentTopInset,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: AppPageContentTransition(
                child: _error != null
                    ? Padding(
                        padding: EdgeInsets.only(top: contentTopInset),
                        child: _BatchMetadataErrorView(onRetry: _load),
                      )
                    : BatchMetadataSetupView(
                        topInset: contentTopInset,
                        scope: _scope,
                        allCount: _entries.length,
                        noMetadataCount: _noMetadataEntries.length,
                        anyMissingCount: _anyMissingEntries.length,
                        hasRjCodeCount: _hasRjCodeEntries.length,
                        specificCount: _specificEntries.length,
                        onScopeChanged: (scope) {
                          setState(() {
                            _scope = scope;
                          });
                          if (scope == DlsiteMetadataBatchScope.specific &&
                              _specificEntries.isEmpty) {
                            _pickSpecific();
                          }
                        },
                        onPickSpecific: _pickSpecific,
                      ),
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: TopPageHeader(
                key: _headerKey,
                icon: Icons.library_add_check_rounded,
                title: i18n.tr('batch_metadata'),
                leading: const AppHeaderBackButton(),
                additionalChild: _error != null
                    ? null
                    : Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                        child: HeaderFloatingSurface(
                          height: null,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 9,
                          ),
                          child: Text(
                            i18n.tr('batch_metadata_hint'),
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(
                                  color: cs.onSurfaceVariant,
                                  height: 1.4,
                                ),
                          ),
                        ),
                      ),
              ),
            ),
            if (_error == null)
              Positioned(
                right: 16,
                bottom: 16 + bottomInset,
                child: AppPageContentTransition(
                  child: HeaderFloatingActionPill(
                    pillKey: const ValueKey<String>('batch_metadata_start'),
                    icon: Icons.play_arrow_rounded,
                    label: i18n.tr('batch_metadata_start'),
                    backgroundColor: canStart
                        ? cs.primary
                        : cs.onSurface.withValues(alpha: 0.12),
                    foregroundColor: startForeground,
                    onTap: canStart ? _run : null,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _BatchMetadataErrorView extends StatelessWidget {
  const _BatchMetadataErrorView({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              i18n.tr('batch_metadata_load_failed'),
              textAlign: TextAlign.center,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            const SizedBox(height: 16),
            AppLabelledButton(
              FilledButton.icon,
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: Text(i18n.tr('retry')),
            ),
          ],
        ),
      ),
    );
  }
}
