import 'library_providers.dart';
import '../../settings/presentation/settings_providers.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/state/app_runtime_providers.dart';
import '../../../app/theme/app_styles.dart';
import '../../../core/media/audio_detail.dart';
import '../../../core/ui/ui_operation_service.dart';
import '../application/dlsite_metadata_batch_session.dart';
import '../domain/audio_library_category.dart';
import '../../../core/widgets/app_transitions.dart';
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
            fadeHeader: false,
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
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
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
        fadeHeader: false,
        child: DlsiteMetadataBatchResultsPage(session: session),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final topInset = AppPageHeaderMetrics.contentTopInset(context);
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: cs.surface,
      body: PageHeaderInset(
        topInset: topInset,
        child: Stack(
          children: [
            Positioned.fill(
              child: AppPageContentTransition(
                child: _error != null
                    ? _BatchMetadataErrorView(onRetry: _load)
                    : BatchMetadataSetupView(
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
            if (_error == null)
              Positioned(
                right: 16,
                bottom: 16 + MediaQuery.paddingOf(context).bottom,
                child: AppPageContentTransition(
                  child: HeaderFloatingSurface(
                    key: const ValueKey<String>('batch_metadata_start'),
                    height: 46,
                    radius: 23,
                    padding: EdgeInsets.zero,
                    child: Material(
                      color: cs.primary,
                      borderRadius: BorderRadius.circular(23),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(23),
                        onTap: _run,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 18),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.play_arrow_rounded,
                                size: 18,
                                color: cs.onPrimary,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                i18n.tr('batch_metadata_start'),
                                style: TextStyle(
                                  color: cs.onPrimary,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: TopPageHeader(
                icon: Icons.library_add_check_rounded,
                title: i18n.tr('batch_metadata'),
                leading: const BackButton(),
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
        padding: EdgeInsets.only(
          top: AppPageHeaderMetrics.contentTopInset(context),
          left: 24,
          right: 24,
          bottom: 24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              i18n.tr('batch_metadata_load_failed'),
              textAlign: TextAlign.center,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
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
