import 'dart:async';

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/app_runtime_providers.dart';
import '../theme/app_styles.dart';
import '../../core/widgets/app_feedback.dart';
import '../../core/widgets/app_search_suggestions.dart';
import '../../core/widgets/app_transitions.dart';
import '../../core/widgets/mobile_overlay_inset.dart';
import '../../core/widgets/page_header_inset.dart';
import '../../core/widgets/scroll_activity_gate.dart';
import '../../core/widgets/top_page_header.dart';
import '../../core/widgets/windows_smooth_scroll_controller.dart';
import '../../features/asmr/presentation/asmr_providers.dart';
import '../../features/asmr/application/asmr_library_controller.dart';

enum MyInterestType {
  tags(
    'my_interests',
    'my_no_interests',
    'my_add_interest',
    'my_excluded_tags',
    'my_listened_tag',
    'my_catalog',
    'my_search_tags',
  ),
  voiceActors(
    'my_voice_interests',
    'my_no_voice_interests',
    'my_add_voice_interest',
    'my_excluded_voice_actors',
    'my_listened_voice_actor',
    'my_voice_catalog',
    'my_voice_search',
  ),
  circles(
    'my_circle_interests',
    'my_no_circle_interests',
    'my_add_circle_interest',
    'my_excluded_circles',
    'my_listened_circle',
    'my_circle_catalog',
    'my_circle_search',
  );

  const MyInterestType(
    this.titleKey,
    this.emptyKey,
    this.addKey,
    this.excludedKey,
    this.listenedKey,
    this.catalogKey,
    this.searchKey,
  );
  final String titleKey;
  final String emptyKey;
  final String addKey;
  final String excludedKey;
  final String listenedKey;
  final String catalogKey;
  final String searchKey;
}

typedef _InterestCatalogInputs = ({
  List<AsmrTag> tags,
  List<AsmrTagInterest> listened,
  Set<String> selected,
  Set<String> excluded,
});

typedef _InterestCatalogView = ({
  List<String> items,
  Map<String, String> labels,
  Map<String, AsmrTag> tags,
  Set<String> automatic,
  Set<String> selected,
});

/// All interest editors share the searchable catalog and draft confirmation.
class MyTagManagementPage extends ConsumerStatefulWidget {
  const MyTagManagementPage({
    super.key,
    required this.excluded,
    this.type = MyInterestType.tags,
  });
  final bool excluded;
  final MyInterestType type;

  @override
  ConsumerState<MyTagManagementPage> createState() =>
      _MyTagManagementPageState();
}

class _MyTagManagementPageState extends ConsumerState<MyTagManagementPage> {
  final _search = TextEditingController();
  final _changes = <String, bool>{};
  bool _saving = false;
  AsmrLibraryController? _catalogController;
  _InterestCatalogInputs? _catalogInputs;
  _InterestCatalogView? _catalogView;
  String? _matchedQuery;
  List<String>? _matchingItems;

  void _invalidateCatalogView() {
    _catalogView = null;
    _matchedQuery = null;
    _matchingItems = null;
  }

  void _refreshCatalog() {
    // Saving can publish preferences before its recommendation refresh
    // completes. Keep the outgoing editor in its current order.
    if (_saving) return;
    final next = _readCatalogInputs(_catalogController!);
    final previous = _catalogInputs;
    _catalogInputs = next;
    if (previous == null ||
        !identical(previous.tags, next.tags) ||
        !identical(previous.listened, next.listened) ||
        !setEquals(previous.selected, next.selected) ||
        !setEquals(previous.excluded, next.excluded)) {
      _invalidateCatalogView();
    }
  }

  void _watchCatalog(AsmrLibraryController? controller) {
    if (identical(controller, _catalogController)) return;
    _catalogController?.removeListener(_refreshCatalog);
    _catalogController = controller;
    controller?.addListener(_refreshCatalog);
    _catalogInputs = null;
    _invalidateCatalogView();
  }

  @override
  void didUpdateWidget(covariant MyTagManagementPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.type != widget.type ||
        oldWidget.excluded != widget.excluded) {
      _catalogInputs = null;
      _invalidateCatalogView();
    }
  }

  @override
  void initState() {
    super.initState();
    final controller = ref.read(asmrLibraryControllerProvider);
    if (controller != null) unawaited(_loadCatalog(controller));
  }

  Future<void> _loadCatalog(AsmrLibraryController controller) =>
      switch (widget.type) {
        MyInterestType.tags => controller.ensureTagCatalog(),
        MyInterestType.voiceActors => controller.ensureVoiceActorCatalog(),
        MyInterestType.circles => controller.ensureCircleCatalog(),
      };

  @override
  void dispose() {
    _catalogController?.removeListener(_refreshCatalog);
    _search.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    final controller = ref.read(asmrLibraryControllerProvider);
    if (controller == null || _saving) return;
    setState(() => _saving = true);
    try {
      await switch (widget.type) {
        MyInterestType.tags => controller.applyTagSelections(
          excluded: widget.excluded,
          changes: _changes,
        ),
        MyInterestType.voiceActors => controller.applyVoiceActorSelections(
          excluded: widget.excluded,
          changes: _changes,
        ),
        MyInterestType.circles => controller.applyCircleSelections(
          excluded: widget.excluded,
          changes: _changes,
        ),
      };
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _refreshCatalog();
      });
      showAppSnackBar(context, error.toString());
    }
  }

  _InterestCatalogView _buildCatalogView(AsmrLibraryController controller) {
    final inputs = _catalogInputs ??= _readCatalogInputs(controller);
    final weights = widget.excluded
        ? <String, double>{}
        : {
            for (final interest in inputs.listened)
              interest.tag.key: interest.weight,
          };
    final tags = inputs.tags
        .where((tag) => widget.excluded || !inputs.excluded.contains(tag.key))
        .toList();
    tags.sort((a, b) {
      final automatic = (weights.containsKey(b.key) ? 1 : 0).compareTo(
        weights.containsKey(a.key) ? 1 : 0,
      );
      if (automatic != 0) return automatic;
      final weight = (weights[b.key] ?? 0).compareTo(weights[a.key] ?? 0);
      if (weight != 0) return weight;
      // The saved selection sets the order for this editor. Drafts only
      // affect the highlight, so a tap never moves the target.
      final selected = (inputs.selected.contains(b.key) ? 1 : 0).compareTo(
        inputs.selected.contains(a.key) ? 1 : 0,
      );
      if (!weights.containsKey(a.key) && selected != 0) return selected;
      final name = a.name.compareTo(b.name);
      return name != 0 ? name : a.key.compareTo(b.key);
    });
    return (
      items: [for (final tag in tags) tag.key],
      labels: {for (final tag in tags) tag.key: tag.name},
      tags: {for (final tag in tags) tag.key: tag},
      automatic: weights.keys.toSet(),
      selected: inputs.selected,
    );
  }

  List<String> _visibleItems(_InterestCatalogView view) {
    final query = _search.text.trim().toLowerCase();
    if (_matchingItems == null || _matchedQuery != query) {
      _matchedQuery = query;
      _matchingItems = query.isEmpty
          ? view.items
          : view.items
                .where(
                  (key) => view.tags[key]!.aliases.any(
                    (name) => name.toLowerCase().contains(query),
                  ),
                )
                .toList(growable: false);
    }
    return _matchingItems!;
  }

  _InterestCatalogInputs _readCatalogInputs(AsmrLibraryController controller) =>
      (
        tags: switch (widget.type) {
          MyInterestType.tags => controller.allTags,
          MyInterestType.voiceActors => controller.allVoiceActors,
          MyInterestType.circles => controller.allCircles,
        },
        listened: switch (widget.type) {
          MyInterestType.tags => controller.listenedTagInterests,
          MyInterestType.voiceActors => controller.listenedVoiceActorInterests,
          MyInterestType.circles => controller.listenedCircleInterests,
        },
        excluded: Set.of(switch (widget.type) {
          MyInterestType.tags => controller.excludedTagKeys,
          MyInterestType.voiceActors => controller.excludedVoiceActorKeys,
          MyInterestType.circles => controller.excludedCircleKeys,
        }),
        selected: Set.of(
          widget.excluded
              ? switch (widget.type) {
                  MyInterestType.tags => controller.excludedTagKeys,
                  MyInterestType.voiceActors =>
                    controller.excludedVoiceActorKeys,
                  MyInterestType.circles => controller.excludedCircleKeys,
                }
              : switch (widget.type) {
                  MyInterestType.tags => controller.manualInterestTagKeys,
                  MyInterestType.voiceActors =>
                    controller.manualInterestVoiceActorKeys,
                  MyInterestType.circles => controller.manualInterestCircleKeys,
                },
        ),
      );

  @override
  Widget build(BuildContext context) {
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final controller = ref.watch(asmrLibraryControllerProvider);
    _watchCatalog(controller);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    const searchHeight = 38.0;
    const searchPadding = EdgeInsets.fromLTRB(16, 6, 16, 0);
    final headerTopInset = AppPageHeaderMetrics.contentTopInset(
      context,
      additionalHeight: searchHeight + searchPadding.top,
    );
    final content = controller == null
        ? Center(child: Text(i18n.tr('${widget.type.catalogKey}_incomplete')))
        : ListenableBuilder(
            listenable: controller,
            builder: (context, _) {
              final view = _catalogView ??= _buildCatalogView(controller);
              final items = _visibleItems(view);
              final (loading, complete, error) = switch (widget.type) {
                MyInterestType.tags => (
                  controller.isLoadingTagCatalog,
                  controller.tagCatalogComplete,
                  controller.tagCatalogError,
                ),
                MyInterestType.voiceActors => (
                  controller.isLoadingVoiceActorCatalog,
                  controller.voiceActorCatalogComplete,
                  controller.voiceActorCatalogError,
                ),
                MyInterestType.circles => (
                  controller.isLoadingCircleCatalog,
                  controller.circleCatalogComplete,
                  controller.circleCatalogError,
                ),
              };
              return CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(child: SizedBox(height: headerTopInset)),
                  if (loading)
                    const SliverToBoxAdapter(child: LinearProgressIndicator()),
                  if (!complete)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                i18n.tr(
                                  '${widget.type.catalogKey}_${error == null ? 'incomplete' : 'error'}',
                                ),
                              ),
                            ),
                            TextButton(
                              onPressed: loading
                                  ? null
                                  : () => _loadCatalog(controller),
                              child: Text(i18n.tr('my_retry')),
                            ),
                          ],
                        ),
                      ),
                    ),
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(
                      16,
                      0,
                      16,
                      MobileOverlayInset.of(context) + 88,
                    ),
                    sliver: AppElementChipSliver(
                      items: items,
                      labels: view.labels,
                      resolveRowCount: true,
                      isSelected: (key) =>
                          view.automatic.contains(key) ||
                          (_changes[key] ?? view.selected.contains(key)),
                      isEnabled: (key) => !view.automatic.contains(key),
                      disabledHint: i18n.tr(widget.type.listenedKey),
                      readOnly: _saving,
                      onToggle: (key) => setState(() {
                        final value =
                            !(_changes[key] ?? view.selected.contains(key));
                        if (value == view.selected.contains(key)) {
                          _changes.remove(key);
                        } else {
                          _changes[key] = value;
                        }
                      }),
                    ),
                  ),
                ],
              ).withWindowsSmoothScroll();
            },
          );
    return PopScope(
      canPop: !_saving,
      child: Scaffold(
        body: ScrollActivityGate(
          child: PageHeaderInset(
            topInset: headerTopInset,
            child: Stack(
              children: [
                Positioned.fill(child: content),
                Positioned(
                  right: 16,
                  bottom:
                      16 +
                      MediaQuery.paddingOf(context).bottom +
                      MobileOverlayInset.of(context),
                  child: AppPageContentTransition(
                    child: HeaderFloatingSurface(
                      key: const ValueKey('my_tags_confirm'),
                      height: 46,
                      radius: 23,
                      padding: EdgeInsets.zero,
                      child: Material(
                        color: cs.primary,
                        borderRadius: BorderRadius.circular(23),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(23),
                          onTap: controller == null || _saving
                              ? null
                              : _confirm,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 18),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (_saving)
                                  SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: cs.onPrimary,
                                    ),
                                  )
                                else
                                  Icon(
                                    Icons.check_rounded,
                                    size: 18,
                                    color: cs.onPrimary,
                                  ),
                                const SizedBox(width: 6),
                                Text(
                                  i18n.tr('confirm'),
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
                    title: i18n.tr(
                      widget.excluded
                          ? widget.type.excludedKey
                          : widget.type.addKey,
                    ),
                    icon: widget.excluded
                        ? Icons.block_rounded
                        : switch (widget.type) {
                            MyInterestType.tags => Icons.sell_outlined,
                            MyInterestType.voiceActors =>
                              Icons.record_voice_over_rounded,
                            MyInterestType.circles => Icons.groups_rounded,
                          },
                    leading: const BackButton(),
                    additionalChild: Padding(
                      padding: searchPadding,
                      child: HeaderFloatingSurface(
                        key: const ValueKey('my_tag_search_capsule'),
                        child: TextField(
                          controller: _search,
                          onChanged: (_) => setState(() {}),
                          textInputAction: TextInputAction.search,
                          textAlignVertical: TextAlignVertical.center,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontSize: 14,
                          ),
                          decoration: InputDecoration(
                            hintText: i18n.tr(widget.type.searchKey),
                            hintStyle: theme.textTheme.bodyMedium?.copyWith(
                              color: cs.onSurfaceVariant,
                              fontSize: 14,
                            ),
                            filled: false,
                            fillColor: Colors.transparent,
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            isDense: true,
                            contentPadding: const EdgeInsets.only(right: 10),
                            prefixIcon: Icon(
                              Icons.search_rounded,
                              color: cs.onSurfaceVariant,
                              size: 20,
                            ),
                            prefixIconConstraints:
                                const BoxConstraints.tightFor(
                                  width: searchHeight,
                                  height: searchHeight,
                                ),
                            suffixIconConstraints:
                                const BoxConstraints.tightFor(
                                  width: searchHeight,
                                  height: searchHeight,
                                ),
                            suffixIcon: _search.text.isEmpty
                                ? null
                                : IconButton(
                                    onPressed: () => setState(_search.clear),
                                    padding: EdgeInsets.zero,
                                    tooltip: MaterialLocalizations.of(
                                      context,
                                    ).deleteButtonTooltip,
                                    icon: const Icon(
                                      Icons.clear_rounded,
                                      size: 20,
                                    ),
                                  ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
