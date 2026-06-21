import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../i18n/app_language_provider.dart';
import '../providers/audio_provider.dart';
import 'dlsite_metadata_review_page.dart';
import '../widgets/app_transitions.dart';

enum _BatchMetadataScope { anyMissing, noMetadata, hasRjCode, all, specific }

class DlsiteMetadataBatchPage extends StatefulWidget {
  const DlsiteMetadataBatchPage({super.key, @visibleForTesting this.entries});

  @visibleForTesting
  final List<AudioLibraryCategoryEntry>? entries;

  @override
  State<DlsiteMetadataBatchPage> createState() =>
      _DlsiteMetadataBatchPageState();
}

class _DlsiteMetadataBatchPageState extends State<DlsiteMetadataBatchPage> {
  List<AudioLibraryCategoryEntry> _entries =
      const <AudioLibraryCategoryEntry>[];
  List<AudioLibraryCategoryEntry> _specificEntries =
      const <AudioLibraryCategoryEntry>[];
  _BatchMetadataScope _scope = _BatchMetadataScope.anyMissing;
  _BatchMetadataSummary? _summary;
  Object? _error;
  bool _loading = true;
  bool _running = false;
  int _currentIndex = 0;
  int _activeTotal = 0;

  List<AudioLibraryCategoryEntry> get _anyMissingEntries => _entries
      .where((entry) => entry.detail.hasMissingMetadata)
      .toList(growable: false);

  List<AudioLibraryCategoryEntry> get _noMetadataEntries => _entries
      .where((entry) => entry.detail.hasNoMetadata)
      .toList(growable: false);

  List<AudioLibraryCategoryEntry> get _hasRjCodeEntries =>
      _entries.where((entry) => entry.detail.hasRjCode).toList(growable: false);

  List<AudioLibraryCategoryEntry> get _selectedEntries => switch (_scope) {
    _BatchMetadataScope.anyMissing => _anyMissingEntries,
    _BatchMetadataScope.noMetadata => _noMetadataEntries,
    _BatchMetadataScope.hasRjCode => _hasRjCodeEntries,
    _BatchMetadataScope.all => _entries,
    _BatchMetadataScope.specific => _specificEntries,
  };

  @override
  void initState() {
    super.initState();
    final entries = widget.entries;
    if (entries != null) {
      _entries = entries;
      _loading = false;
    } else {
      unawaited(_load());
    }
  }

  Future<void> _pickSpecific() async {
    final result = await Navigator.of(context).push<List<AudioLibraryCategoryEntry>>(
      buildAppPageRoute(child: DlsiteMetadataWorkPickerPage(
          entries: _entries,
          initialSelection: _specificEntries,
        ),
      ),
    );
    if (result != null) {
      setState(() {
        _specificEntries = result;
        _scope = _BatchMetadataScope.specific;
      });
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final snapshot = await context
          .read<AudioProvider>()
          .audioLibraryCategorySnapshot();
      if (!mounted) return;
      setState(() {
        _entries = snapshot.entries;
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
    if (_running) return;
    final queue = List<AudioLibraryCategoryEntry>.of(_selectedEntries);
    var applied = 0;
    var skipped = 0;
    setState(() {
      _running = true;
      _summary = null;
      _currentIndex = 0;
      _activeTotal = queue.length;
    });

    for (var index = 0; index < queue.length; index++) {
      if (!mounted) return;
      setState(() {
        _currentIndex = index + 1;
      });
      final entry = queue[index];
      final provider = context.read<AudioProvider>();
      final query = provider.buildDlsiteMetadataQuery(entry.detail);
      if (!query.hasQuery) {
        skipped++;
        continue;
      }
      final result = await Navigator.of(context)
          .push<DlsiteMetadataReviewResult>(
            buildAppPageRoute(child: DlsiteMetadataReviewPage(
                detail: entry.detail,
                rjCode: query.rjCode,
                searchTitles: query.searchTitles,
                batchIndex: index + 1,
                batchTotal: queue.length,
                allowSkip: true,
              ),
            ),
          );
      if (!mounted) return;
      if (result == null) {
        setState(() {
          _running = false;
          _summary = _BatchMetadataSummary(
            total: queue.length,
            applied: applied,
            skipped: skipped,
            unprocessed: queue.length - index,
          );
        });
        return;
      }
      if (result.isApplied) {
        applied++;
      } else {
        skipped++;
      }
      await Future<void>.delayed(Duration.zero);
    }

    if (!mounted) return;
    setState(() {
      _running = false;
      _summary = _BatchMetadataSummary(
        total: queue.length,
        applied: applied,
        skipped: skipped,
        unprocessed: 0,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final i18n = context.watch<AppLanguageProvider>();
    return Scaffold(
      appBar: AppBar(title: Text(i18n.tr('batch_metadata'))),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
            ? _BatchMetadataErrorView(onRetry: _load)
            : _summary != null
            ? _BatchMetadataSummaryView(
                summary: _summary!,
                onDone: () => Navigator.of(context).maybePop(),
              )
            : _BatchMetadataSetupView(
                scope: _scope,
                allCount: _entries.length,
                noMetadataCount: _noMetadataEntries.length,
                anyMissingCount: _anyMissingEntries.length,
                hasRjCodeCount: _hasRjCodeEntries.length,
                specificCount: _specificEntries.length,
                running: _running,
                currentIndex: _currentIndex,
                activeTotal: _activeTotal,
                onScopeChanged: (scope) {
                  setState(() {
                    _scope = scope;
                  });
                  if (scope == _BatchMetadataScope.specific && _specificEntries.isEmpty) {
                    _pickSpecific();
                  }
                },
                onPickSpecific: _pickSpecific,
                onStart: _run,
              ),
      ),
    );
  }
}

class _BatchMetadataSummary {
  const _BatchMetadataSummary({
    required this.total,
    required this.applied,
    required this.skipped,
    required this.unprocessed,
  });

  final int total;
  final int applied;
  final int skipped;
  final int unprocessed;
}

class _BatchMetadataSetupView extends StatelessWidget {
  const _BatchMetadataSetupView({
    required this.scope,
    required this.allCount,
    required this.noMetadataCount,
    required this.anyMissingCount,
    required this.hasRjCodeCount,
    required this.specificCount,
    required this.running,
    required this.currentIndex,
    required this.activeTotal,
    required this.onScopeChanged,
    required this.onPickSpecific,
    required this.onStart,
  });

  final _BatchMetadataScope scope;
  final int allCount;
  final int noMetadataCount;
  final int anyMissingCount;
  final int hasRjCodeCount;
  final int specificCount;
  final bool running;
  final int currentIndex;
  final int activeTotal;
  final ValueChanged<_BatchMetadataScope> onScopeChanged;
  final VoidCallback onPickSpecific;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    final i18n = context.watch<AppLanguageProvider>();
    if (running) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(
              i18n.tr('batch_metadata_progress', {
                'current': currentIndex,
                'total': activeTotal,
              }),
            ),
          ],
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
      children: [
        Text(
          i18n.tr('batch_metadata_hint'),
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 16),
        RadioGroup<_BatchMetadataScope>(
          key: const ValueKey('batch_metadata_scope_group'),
          groupValue: scope,
          onChanged: (value) {
            if (value != null) onScopeChanged(value);
          },
          child: Column(
            children: [
              RadioListTile<_BatchMetadataScope>(
                value: _BatchMetadataScope.anyMissing,
                title: Text(
                  '${i18n.tr('batch_metadata_any_missing')} ($anyMissingCount)',
                ),
              ),
              RadioListTile<_BatchMetadataScope>(
                value: _BatchMetadataScope.noMetadata,
                title: Text(
                  '${i18n.tr('batch_metadata_no_metadata')} ($noMetadataCount)',
                ),
              ),
              RadioListTile<_BatchMetadataScope>(
                value: _BatchMetadataScope.hasRjCode,
                title: Text(
                  '${i18n.tr('batch_metadata_has_rj_code')} ($hasRjCodeCount)',
                ),
              ),
              RadioListTile<_BatchMetadataScope>(
                value: _BatchMetadataScope.specific,
                title: Text('${i18n.tr('batch_metadata_specific')} ($specificCount)'),
                secondary: scope == _BatchMetadataScope.specific ? IconButton(
                  icon: const Icon(Icons.edit),
                  onPressed: onPickSpecific,
                ) : null,
              ),
              RadioListTile<_BatchMetadataScope>(
                value: _BatchMetadataScope.all,
                title: Text('${i18n.tr('batch_metadata_all')} ($allCount)'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: onStart,
          icon: const Icon(Icons.play_arrow_rounded),
          label: Text(i18n.tr('batch_metadata_start')),
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
    _selectedIds = widget.initialSelection.map((e) => AudioLibraryCategorySnapshot.targetKey(e.target)).toSet();
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
    return widget.entries.where((e) {
      final title = (e.detail.workTitle.isNotEmpty ? e.detail.workTitle : e.title).toLowerCase();
      final rjCode = e.detail.rjCode.toLowerCase();
      return title.contains(query) || rjCode.contains(query);
    }).toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final i18n = context.watch<AppLanguageProvider>();
    final filtered = _filteredEntries;
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _searchController,
          autofocus: false,
          decoration: InputDecoration(
            hintText: i18n.tr('batch_metadata_picker_search'),
            border: InputBorder.none,
            hintStyle: TextStyle(color: cs.onSurfaceVariant),
          ),
          onChanged: (val) {
            setState(() {
              _searchQuery = val;
            });
          },
        ),
        actions: [
          if (_searchQuery.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.clear),
              onPressed: () {
                _searchController.clear();
                setState(() {
                  _searchQuery = '';
                });
              },
            ),
        ],
      ),
      body: ListView.builder(
        itemCount: filtered.length,
        itemBuilder: (context, index) {
          final entry = filtered[index];
          final id = AudioLibraryCategorySnapshot.targetKey(entry.target);
          final selected = _selectedIds.contains(id);
          return CheckboxListTile(
            value: selected,
            onChanged: (val) => _toggleSelection(id, val),
            title: Text(
              entry.detail.workTitle.isNotEmpty ? entry.detail.workTitle : entry.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: entry.detail.rjCode.isNotEmpty
                ? Text(entry.detail.rjCode)
                : null,
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          final result = widget.entries
              .where((e) => _selectedIds.contains(AudioLibraryCategorySnapshot.targetKey(e.target)))
              .toList(growable: false);
          Navigator.of(context).pop(result);
        },
        icon: const Icon(Icons.check),
        label: Text(
          i18n.tr('batch_metadata_picker_done', {
            'count': _selectedIds.length,
          }),
        ),
      ),
    );
  }
}


class _BatchMetadataSummaryView extends StatelessWidget {
  const _BatchMetadataSummaryView({
    required this.summary,
    required this.onDone,
  });

  final _BatchMetadataSummary summary;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final i18n = context.watch<AppLanguageProvider>();
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 24),
      children: [
        Text(
          i18n.tr('batch_metadata_summary'),
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 16),
        Text('${i18n.tr('batch_metadata_total')}: ${summary.total}'),
        Text('${i18n.tr('batch_metadata_applied')}: ${summary.applied}'),
        Text('${i18n.tr('batch_metadata_skipped')}: ${summary.skipped}'),
        Text(
          '${i18n.tr('batch_metadata_unprocessed')}: ${summary.unprocessed}',
        ),
        const SizedBox(height: 24),
        FilledButton(onPressed: onDone, child: Text(i18n.tr('done'))),
      ],
    );
  }
}

class _BatchMetadataErrorView extends StatelessWidget {
  const _BatchMetadataErrorView({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final i18n = context.watch<AppLanguageProvider>();
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              i18n.tr('batch_metadata_load_failed'),
              textAlign: TextAlign.center,
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
