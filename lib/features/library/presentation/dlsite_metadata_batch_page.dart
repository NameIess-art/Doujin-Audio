import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/state/app_runtime_providers.dart';
import '../../../app/theme/app_styles.dart';
import '../../../core/media/audio_detail.dart';
import '../../../core/ui/ui_operation_service.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_dialog.dart';
import '../application/dlsite_metadata_batch_session.dart';
import '../domain/audio_library_category.dart';
import 'dlsite_metadata_review_page.dart';
import '../../../core/widgets/app_transitions.dart';
import '../../../core/widgets/operation_feedback.dart';
import '../../../core/widgets/top_page_header.dart';

enum DlsiteMetadataBatchScope {
  anyMissing,
  noMetadata,
  hasRjCode,
  all,
  specific,
}

double _headerContentTopInset(BuildContext context) =>
    MediaQuery.paddingOf(context).top +
    AppPageHeaderMetrics.padding.vertical +
    AppPageHeaderMetrics.contentHeight +
    AppPageHeaderMetrics.bottomSpacing +
    AppPageHeaderMetrics.firstContentSpacing;

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
  bool _loading = true;

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
      _loading = false;
    } else {
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
      _loading = true;
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
        style: AppPageTransitionStyle.sharedAxisZ,
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
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      body: Stack(
        children: [
          Positioned.fill(
            child: _loading
                ? OperationSkeletonList(
                    itemCount: 5,
                    padding: EdgeInsets.fromLTRB(
                      16,
                      _headerContentTopInset(context),
                      16,
                      24,
                    ),
                  )
                : _error != null
                ? _BatchMetadataErrorView(onRetry: _load)
                : _BatchMetadataSetupView(
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
          if (!_loading && _error == null)
            Positioned(
              left: 16,
              right: 16,
              bottom: 16 + MediaQuery.paddingOf(context).bottom,
              child: FilledButton.icon(
                onPressed: _run,
                icon: const Icon(Icons.play_arrow_rounded),
                label: Text(i18n.tr('batch_metadata_start')),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  textStyle: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
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
    );
  }
}

class _BatchMetadataSetupView extends StatelessWidget {
  const _BatchMetadataSetupView({
    required this.scope,
    required this.allCount,
    required this.noMetadataCount,
    required this.anyMissingCount,
    required this.hasRjCodeCount,
    required this.specificCount,
    required this.onScopeChanged,
    required this.onPickSpecific,
  });

  final DlsiteMetadataBatchScope scope;
  final int allCount;
  final int noMetadataCount;
  final int anyMissingCount;
  final int hasRjCodeCount;
  final int specificCount;
  final ValueChanged<DlsiteMetadataBatchScope> onScopeChanged;
  final VoidCallback onPickSpecific;

  @override
  Widget build(BuildContext context) {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    return ListView(
      padding: EdgeInsets.fromLTRB(
        16,
        _headerContentTopInset(context),
        16,
        88 + MediaQuery.paddingOf(context).bottom,
      ),
      children: [
        Text(
          i18n.tr('batch_metadata_hint'),
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 16),
        Card(
          elevation: 0,
          margin: EdgeInsets.zero,
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          clipBehavior: Clip.antiAlias,
          child: RadioGroup<DlsiteMetadataBatchScope>(
            key: const ValueKey('batch_metadata_scope_group'),
            groupValue: scope,
            onChanged: (value) {
              if (value != null) onScopeChanged(value);
            },
            child: Column(
              children: [
                RadioListTile<DlsiteMetadataBatchScope>(
                  value: DlsiteMetadataBatchScope.anyMissing,
                  title: Text(
                    '${i18n.tr('batch_metadata_any_missing')} ($anyMissingCount)',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                RadioListTile<DlsiteMetadataBatchScope>(
                  value: DlsiteMetadataBatchScope.noMetadata,
                  title: Text(
                    '${i18n.tr('batch_metadata_no_metadata')} ($noMetadataCount)',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                RadioListTile<DlsiteMetadataBatchScope>(
                  value: DlsiteMetadataBatchScope.hasRjCode,
                  title: Text(
                    '${i18n.tr('batch_metadata_has_rj_code')} ($hasRjCodeCount)',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                RadioListTile<DlsiteMetadataBatchScope>(
                  value: DlsiteMetadataBatchScope.specific,
                  title: Text(
                    '${i18n.tr('batch_metadata_specific')} ($specificCount)',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  secondary: scope == DlsiteMetadataBatchScope.specific
                      ? IconButton(
                          icon: const Icon(Icons.edit_rounded),
                          onPressed: onPickSpecific,
                        )
                      : null,
                ),
                RadioListTile<DlsiteMetadataBatchScope>(
                  value: DlsiteMetadataBatchScope.all,
                  title: Text(
                    '${i18n.tr('batch_metadata_all')} ($allCount)',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class DlsiteMetadataWorkPickerPage extends StatefulWidget {
  const DlsiteMetadataWorkPickerPage({
    super.key,
    required this.entries,
    required this.initialSelection,
  });

  final List<AudioLibraryCategoryEntry> entries;
  final List<AudioLibraryCategoryEntry> initialSelection;

  @override
  State<DlsiteMetadataWorkPickerPage> createState() =>
      _DlsiteMetadataWorkPickerPageState();
}

class _DlsiteMetadataWorkPickerPageState
    extends State<DlsiteMetadataWorkPickerPage> {
  late final Set<String> _selectedIds;
  String _searchQuery = '';
  late final TextEditingController _searchController;

  @override
  void initState() {
    super.initState();
    _selectedIds = widget.initialSelection
        .map((e) => AudioLibraryCategorySnapshot.targetKey(e.target))
        .toSet();
    _searchController = TextEditingController();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _toggleSelection(String id, bool? selected) {
    setState(() {
      if (selected == true) {
        _selectedIds.add(id);
      } else {
        _selectedIds.remove(id);
      }
    });
  }

  List<AudioLibraryCategoryEntry> get _filteredEntries {
    if (_searchQuery.trim().isEmpty) return widget.entries;
    final query = _searchQuery.trim().toLowerCase();
    return widget.entries
        .where((e) {
          final title =
              (e.detail.workTitle.isNotEmpty ? e.detail.workTitle : e.title)
                  .toLowerCase();
          final rjCode = e.detail.rjCode.toLowerCase();
          return title.contains(query) || rjCode.contains(query);
        })
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final filtered = _filteredEntries;
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      body: Stack(
        children: [
          Positioned.fill(
            child: ListView.builder(
              padding: EdgeInsets.only(
                top: _headerContentTopInset(context),
                bottom: 78 + MediaQuery.paddingOf(context).bottom,
              ),
              itemCount: filtered.length,
              itemBuilder: (context, index) {
                final entry = filtered[index];
                final id = AudioLibraryCategorySnapshot.targetKey(entry.target);
                final selected = _selectedIds.contains(id);
                return CheckboxListTile(
                  value: selected,
                  onChanged: (val) => _toggleSelection(id, val),
                  title: Text(
                    entry.detail.workTitle.isNotEmpty
                        ? entry.detail.workTitle
                        : entry.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: entry.detail.rjCode.isNotEmpty
                      ? Text(entry.detail.rjCode)
                      : null,
                );
              },
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: TopPageHeader(
              key: const ValueKey<String>('batch_metadata_picker_header'),
              leading: const BackButton(),
              titleWidget: HeaderFloatingSurface(
                key: const ValueKey<String>('batch_metadata_picker_search'),
                child: TextSelectionTheme(
                  data: TextSelectionThemeData(
                    cursorColor: cs.primary,
                    selectionColor: cs.primary.withValues(alpha: 0.24),
                    selectionHandleColor: cs.primary,
                  ),
                  child: TextField(
                    controller: _searchController,
                    cursorColor: cs.primary,
                    textInputAction: TextInputAction.search,
                    textAlignVertical: TextAlignVertical.center,
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(fontSize: 14),
                    decoration: InputDecoration(
                      filled: false,
                      fillColor: Colors.transparent,
                      prefixIcon: Icon(
                        Icons.search_rounded,
                        color: cs.onSurfaceVariant,
                        size: 20,
                      ),
                      prefixIconConstraints: const BoxConstraints.tightFor(
                        width: 38,
                        height: 38,
                      ),
                      hintText: i18n.tr('batch_metadata_picker_search'),
                      hintStyle: Theme.of(context).textTheme.bodyMedium
                          ?.copyWith(color: cs.onSurfaceVariant, fontSize: 14),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding: const EdgeInsets.only(right: 10),
                      suffixIcon: _searchQuery.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.clear_rounded, size: 18),
                              color: cs.onSurfaceVariant,
                              onPressed: () {
                                _searchController.clear();
                                setState(() {
                                  _searchQuery = '';
                                });
                              },
                            ),
                      suffixIconConstraints: const BoxConstraints.tightFor(
                        width: 38,
                        height: 38,
                      ),
                      isDense: true,
                    ),
                    onChanged: (val) {
                      setState(() {
                        _searchQuery = val;
                      });
                    },
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            right: 16,
            bottom: 16 + MediaQuery.paddingOf(context).bottom,
            child: HeaderFloatingSurface(
              key: const ValueKey<String>('batch_metadata_picker_done'),
              height: 46,
              radius: 23,
              padding: EdgeInsets.zero,
              child: Material(
                color: cs.primary,
                borderRadius: BorderRadius.circular(23),
                child: InkWell(
                  borderRadius: BorderRadius.circular(23),
                  onTap: () {
                    final result = widget.entries
                        .where(
                          (e) => _selectedIds.contains(
                            AudioLibraryCategorySnapshot.targetKey(e.target),
                          ),
                        )
                        .toList(growable: false);
                    Navigator.of(context).pop(result);
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.check_rounded,
                          size: 18,
                          color: cs.onPrimary,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          i18n.tr('batch_metadata_picker_done', {
                            'count': _selectedIds.length,
                          }),
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
        ],
      ),
    );
  }
}

class DlsiteMetadataBatchResultsPage extends StatefulWidget {
  const DlsiteMetadataBatchResultsPage({super.key, required this.session});

  final DlsiteMetadataBatchSession session;

  @override
  State<DlsiteMetadataBatchResultsPage> createState() =>
      _DlsiteMetadataBatchResultsPageState();
}

class _DlsiteMetadataBatchResultsPageState
    extends State<DlsiteMetadataBatchResultsPage> {
  bool _savingAll = false;
  final List<Timer> _pendingTimers = <Timer>[];

  @override
  void initState() {
    super.initState();
    widget.session.start();
  }

  @override
  void dispose() {
    for (final timer in _pendingTimers) {
      timer.cancel();
    }
    _pendingTimers.clear();
    widget.session.dispose();
    super.dispose();
  }

  Future<void> _handleItemTap(int index) async {
    final item = widget.session.items[index];
    if (item.isExcluded) return;
    if (item.isReviewable) {
      await Navigator.of(context).push<void>(
        buildAppPageRoute(
          context: context,
          style: AppPageTransitionStyle.sharedAxisZ,
          child: DlsiteMetadataBatchReviewPage(
            session: widget.session,
            initialIndex: index,
          ),
        ),
      );
      return;
    }
    if (item.status != DlsiteMetadataBatchLookupStatus.searching) {
      widget.session.retry(index);
    }
  }

  Future<void> _saveAll() async {
    if (_savingAll || widget.session.hasPendingLookups) return;
    setState(() {
      _savingAll = true;
    });
    final result = await widget.session.applyConfirmed();
    if (!mounted) return;
    setState(() {
      _savingAll = false;
    });
    await showAppDialog<void>(
      context: context,
      builder: (_) => _BatchMetadataCompletionDialog(result: result),
    );
    if (!mounted || result.failedCount > 0) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      body: Stack(
        children: [
          Positioned.fill(
            child: AnimatedBuilder(
              animation: widget.session,
              builder: (context, _) {
                final items = widget.session.items;
                return ListView.builder(
                  key: const ValueKey<String>('batch_metadata_results_list'),
                  padding: EdgeInsets.fromLTRB(
                    16,
                    _headerContentTopInset(context),
                    16,
                    78 + MediaQuery.paddingOf(context).bottom,
                  ),
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final item = items[index];
                    final entry = item.entry;
                    final title = entry.detail.workTitle.isNotEmpty
                        ? entry.detail.workTitle
                        : entry.title;
                    final isExcluded = item.isExcluded;
                    final cs = Theme.of(context).colorScheme;
                    return Dismissible(
                      key: ValueKey<String>(
                        'batch_metadata_dismissible_${AudioLibraryCategorySnapshot.targetKey(entry.target)}',
                      ),
                      direction: DismissDirection.endToStart,
                      confirmDismiss: (direction) async {
                        if (direction == DismissDirection.endToStart) {
                          late final Timer timer;
                          timer = Timer(const Duration(milliseconds: 220), () {
                            _pendingTimers.remove(timer);
                            if (mounted) {
                              widget.session.toggleExcluded(index);
                            }
                          });
                          _pendingTimers.add(timer);
                        }
                        return false;
                      },
                      background: const SizedBox.shrink(),
                      secondaryBackground: Container(
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 20),
                        margin: const EdgeInsets.symmetric(vertical: 2),
                        decoration: BoxDecoration(
                          color: isExcluded
                              ? cs.surfaceContainerHighest
                              : cs.errorContainer.withValues(alpha: 0.6),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              isExcluded
                                  ? Icons.undo_rounded
                                  : Icons.block_rounded,
                              color: isExcluded
                                  ? cs.onSurface
                                  : cs.onErrorContainer,
                              size: 20,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              isExcluded
                                  ? i18n.tr('batch_metadata_action_restore')
                                  : i18n.tr('batch_metadata_action_exclude'),
                              style: TextStyle(
                                color: isExcluded
                                    ? cs.onSurface
                                    : cs.onErrorContainer,
                                fontWeight: FontWeight.w600,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                      child: ColorFiltered(
                        colorFilter: isExcluded
                            ? const ColorFilter.matrix(<double>[
                                0.2126,
                                0.7152,
                                0.0722,
                                0,
                                0,
                                0.2126,
                                0.7152,
                                0.0722,
                                0,
                                0,
                                0.2126,
                                0.7152,
                                0.0722,
                                0,
                                0,
                                0,
                                0,
                                0,
                                1,
                                0,
                              ])
                            : const ColorFilter.mode(
                                Colors.transparent,
                                BlendMode.dst,
                              ),
                        child: Opacity(
                          opacity: isExcluded ? 0.38 : 1.0,
                          child: ListTile(
                            key: ValueKey<String>(
                              'batch_metadata_result_$index',
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 8,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            title: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: isExcluded
                                  ? TextStyle(
                                      color: cs.onSurface.withValues(
                                        alpha: 0.38,
                                      ),
                                    )
                                  : null,
                            ),
                            subtitle: entry.detail.rjCode.isEmpty
                                ? null
                                : Text(
                                    entry.detail.rjCode,
                                    style: isExcluded
                                        ? TextStyle(
                                            color: cs.onSurfaceVariant
                                                .withValues(alpha: 0.38),
                                          )
                                        : null,
                                  ),
                            trailing: _BatchMetadataStatusIcon(
                              key: ValueKey<String>(
                                'batch_metadata_status_$index',
                              ),
                              status: item.status,
                              isExcluded: isExcluded,
                            ),
                            onTap: isExcluded
                                ? null
                                : () => _handleItemTap(index),
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: TopPageHeader(
              key: const ValueKey<String>('batch_metadata_results_header'),
              icon: Icons.library_add_check_rounded,
              title: i18n.tr('batch_metadata'),
              leading: const BackButton(),
            ),
          ),
          Positioned(
            right: 16,
            bottom: 16 + MediaQuery.paddingOf(context).bottom,
            child: AnimatedBuilder(
              animation: widget.session,
              builder: (context, _) => HeaderFloatingSurface(
                key: const ValueKey<String>('batch_metadata_results_done'),
                height: 46,
                radius: 23,
                padding: EdgeInsets.zero,
                child: Material(
                  color: Theme.of(context).colorScheme.primary,
                  borderRadius: BorderRadius.circular(23),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(23),
                    onTap: _savingAll || widget.session.hasPendingLookups
                        ? null
                        : _saveAll,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _savingAll
                              ? SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onPrimary,
                                  ),
                                )
                              : Icon(
                                  Icons.check_rounded,
                                  size: 18,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onPrimary,
                                ),
                          const SizedBox(width: 6),
                          Text(
                            i18n.tr('confirm'),
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onPrimary,
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
        ],
      ),
    );
  }
}

class _BatchMetadataCompletionDialog extends StatelessWidget {
  const _BatchMetadataCompletionDialog({required this.result});

  final DlsiteMetadataBatchApplyResult result;

  @override
  Widget build(BuildContext context) {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    return AppDialog(
      key: const ValueKey<String>('batch_metadata_completion_dialog'),
      title: i18n.tr('batch_metadata_completion_title'),
      icon: Icons.task_alt_rounded,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            i18n.tr('batch_metadata_completion_saved', {
              'count': result.savedCount.toString(),
            }),
            key: const ValueKey<String>('batch_metadata_completion_saved'),
          ),
          const SizedBox(height: 8),
          Text(
            i18n.tr('batch_metadata_completion_skipped', {
              'count': result.skippedCount.toString(),
            }),
            key: const ValueKey<String>('batch_metadata_completion_skipped'),
          ),
          const SizedBox(height: 8),
          Text(
            i18n.tr('batch_metadata_completion_failed', {
              'count': result.failedCount.toString(),
            }),
            key: const ValueKey<String>('batch_metadata_completion_failed'),
          ),
        ],
      ),
      actions: AppDialogActions(
        children: [
          AppPrimaryButton(
            key: const ValueKey<String>('batch_metadata_completion_confirm'),
            onPressed: () => Navigator.of(context).pop(),
            label: i18n.tr('confirm'),
          ),
        ],
      ),
    );
  }
}

class DlsiteMetadataBatchReviewPage extends StatefulWidget {
  const DlsiteMetadataBatchReviewPage({
    super.key,
    required this.session,
    required this.initialIndex,
  });

  final DlsiteMetadataBatchSession session;
  final int initialIndex;

  @override
  State<DlsiteMetadataBatchReviewPage> createState() =>
      _DlsiteMetadataBatchReviewPageState();
}

class _DlsiteMetadataBatchReviewPageState
    extends State<DlsiteMetadataBatchReviewPage> {
  late int _currentIndex = widget.initialIndex;
  bool _saveCover = true;

  DlsiteMetadataBatchItem get _currentItem =>
      widget.session.items[_currentIndex];

  void _navigate(int offset) {
    final nextIndex = widget.session.reviewableIndexFrom(_currentIndex, offset);
    if (nextIndex == null) return;
    setState(() {
      _currentIndex = nextIndex;
    });
  }

  void _complete(DlsiteMetadataReviewResult result) {
    if (result.saveCover != null) _saveCover = result.saveCover!;
    final metadata = result.metadata;
    if (result.isConfirmed && metadata != null) {
      widget.session.confirm(
        _currentIndex,
        metadata: metadata,
        saveCover: result.saveCover ?? false,
      );
    }
    final nextIndex = widget.session.reviewableIndexFrom(_currentIndex, 1);
    if (nextIndex == null) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _currentIndex = nextIndex;
    });
  }

  @override
  Widget build(BuildContext context) {
    final item = _currentItem;
    return DlsiteMetadataReviewPage(
      key: ValueKey<String>(
        AudioLibraryCategorySnapshot.targetKey(item.entry.target),
      ),
      detail: item.entry.detail,
      batchIndex: _currentIndex + 1,
      batchTotal: widget.session.items.length,
      allowSkip: true,
      initialSaveCover: _saveCover,
      initialCandidates: item.reviewCandidates,
      canNavigatePrevious:
          widget.session.reviewableIndexFrom(_currentIndex, -1) != null,
      canNavigateNext:
          widget.session.reviewableIndexFrom(_currentIndex, 1) != null,
      onBatchNavigate: _navigate,
      onCompleted: _complete,
    );
  }
}

class _BatchMetadataStatusIcon extends StatelessWidget {
  const _BatchMetadataStatusIcon({
    super.key,
    required this.status,
    this.isExcluded = false,
  });

  final DlsiteMetadataBatchLookupStatus status;
  final bool isExcluded;

  @override
  Widget build(BuildContext context) {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final cs = Theme.of(context).colorScheme;
    if (isExcluded) {
      final label = i18n.tr('batch_metadata_status_excluded');
      return Tooltip(
        message: label,
        child: Semantics(
          label: label,
          child: Icon(Icons.block_rounded, color: cs.outline, size: 22),
        ),
      );
    }
    if (status == DlsiteMetadataBatchLookupStatus.searching) {
      final label = i18n.tr('batch_metadata_status_searching');
      return Tooltip(
        message: label,
        child: Semantics(
          label: label,
          child: _RotatingBatchMetadataStatusIcon(color: cs.primary),
        ),
      );
    }
    final (IconData icon, Color color, String label) = switch (status) {
      DlsiteMetadataBatchLookupStatus.found => (
        Icons.pending_actions_rounded,
        Colors.orange,
        i18n.tr('batch_metadata_status_found'),
      ),
      DlsiteMetadataBatchLookupStatus.confirmed => (
        Icons.check_circle_rounded,
        Colors.green,
        i18n.tr('batch_metadata_status_confirmed'),
      ),
      DlsiteMetadataBatchLookupStatus.notFound => (
        Icons.search_off_rounded,
        cs.onSurfaceVariant,
        i18n.tr('batch_metadata_status_not_found'),
      ),
      DlsiteMetadataBatchLookupStatus.failed => (
        Icons.error_outline_rounded,
        cs.error,
        i18n.tr('batch_metadata_status_failed'),
      ),
      DlsiteMetadataBatchLookupStatus.searching => throw StateError(
        'Searching status is handled above.',
      ),
    };
    return Tooltip(
      message: label,
      child: Semantics(
        label: label,
        child: Icon(icon, color: color, size: 22),
      ),
    );
  }
}

class _RotatingBatchMetadataStatusIcon extends StatefulWidget {
  const _RotatingBatchMetadataStatusIcon({required this.color});

  final Color color;

  @override
  State<_RotatingBatchMetadataStatusIcon> createState() =>
      _RotatingBatchMetadataStatusIconState();
}

class _RotatingBatchMetadataStatusIconState
    extends State<_RotatingBatchMetadataStatusIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RotationTransition(
    turns: _controller,
    child: Icon(Icons.autorenew_rounded, color: widget.color, size: 22),
  );
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
          top: _headerContentTopInset(context),
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
