import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/app_runtime_providers.dart';
import '../theme/app_styles.dart';
import '../../core/ui/undoable_removal_service.dart';
import '../../core/widgets/app_feedback.dart';
import '../../core/widgets/mobile_overlay_inset.dart';
import '../../core/widgets/page_header_inset.dart';
import '../../core/widgets/scroll_activity_gate.dart';
import '../../core/widgets/top_page_header.dart';
import '../../features/asmr/presentation/asmr_providers.dart';

UndoableRemovalKey interestTagRemovalKey(String key) =>
    UndoableRemovalKey('asmr-interest-tag', key);

Future<void> removeInterestTagWithUndo(
  BuildContext context,
  WidgetRef ref,
  String key,
) async {
  final controller = ref.read(asmrLibraryControllerProvider);
  if (controller == null) return;
  final i18n = ref.read(appLanguageProviderInstanceProvider);
  await showUndoableRemovalFeedback(
    context,
    service: ref.read(undoableRemovalServiceProvider),
    action: UndoableRemovalAction(
      key: interestTagRemovalKey(key),
      commit: () => controller.setTagInterested(key, false),
      undo: () {},
    ),
    message: i18n.tr('my_interest_removed'),
    batchMessage: (count) => i18n.tr('items_removed_count', {'count': count}),
    undoLabel: i18n.tr('undo'),
    failureMessage: i18n.tr('removal_failed'),
    icon: Icons.sell_outlined,
  );
}

/// Both preference editors share the same searchable catalog and state owner.
class MyTagManagementPage extends ConsumerStatefulWidget {
  const MyTagManagementPage({super.key, required this.excluded});
  final bool excluded;

  @override
  ConsumerState<MyTagManagementPage> createState() =>
      _MyTagManagementPageState();
}

class _MyTagManagementPageState extends ConsumerState<MyTagManagementPage> {
  final _search = TextEditingController();
  final _changes = <String, bool>{};
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    unawaited(ref.read(asmrLibraryControllerProvider)?.ensureTagCatalog());
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    final controller = ref.read(asmrLibraryControllerProvider);
    if (controller == null || _saving) return;
    setState(() => _saving = true);
    try {
      await controller.applyTagSelections(
        excluded: widget.excluded,
        changes: _changes,
      );
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) showAppSnackBar(context, error.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final controller = ref.watch(asmrLibraryControllerProvider);
    final removals = ref.watch(undoableRemovalStateProvider);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    const searchHeight = 38.0;
    const searchPadding = EdgeInsets.fromLTRB(16, 6, 16, 6);
    final headerTopInset =
        MediaQuery.paddingOf(context).top +
        AppPageHeaderMetrics.padding.vertical +
        AppPageHeaderMetrics.buttonSize +
        searchHeight +
        searchPadding.vertical +
        AppPageHeaderMetrics.firstContentSpacing;
    final content = controller == null
        ? Center(child: Text(i18n.tr('my_catalog_incomplete')))
        : ListenableBuilder(
            listenable: controller,
            builder: (context, _) {
              final interests = {
                for (final interest in controller.interestTags)
                  if (!removals.isHidden(
                    interestTagRemovalKey(interest.tag.key),
                  ))
                    interest.tag.key: interest.weight,
              };
              final selected = widget.excluded
                  ? controller.excludedTagKeys
                  : interests.keys.toSet();
              final query = _search.text.trim().toLowerCase();
              final tags = controller.allTags
                  .where(
                    (tag) =>
                        query.isEmpty ||
                        [
                          tag.name,
                          ...tag.aliases,
                        ].any((name) => name.toLowerCase().contains(query)),
                  )
                  .toList();
              tags.sort((a, b) {
                if (!widget.excluded) {
                  final weight = (interests[b.key] ?? 0).compareTo(
                    interests[a.key] ?? 0,
                  );
                  if (weight != 0) return weight;
                }
                return a.name.compareTo(b.name);
              });
              return CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(child: SizedBox(height: headerTopInset)),
                  if (controller.isLoadingTagCatalog)
                    const SliverToBoxAdapter(child: LinearProgressIndicator()),
                  if (!controller.tagCatalogComplete)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                i18n.tr(
                                  controller.tagCatalogError == null
                                      ? 'my_catalog_incomplete'
                                      : 'my_catalog_error',
                                ),
                              ),
                            ),
                            TextButton(
                              onPressed: controller.isLoadingTagCatalog
                                  ? null
                                  : () => controller.ensureTagCatalog(),
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
                    sliver: SliverList.builder(
                      itemCount: tags.length,
                      itemBuilder: (context, index) {
                        final tag = tags[index];
                        return CheckboxListTile(
                          key: ValueKey(tag.key),
                          title: Text(tag.name),
                          value:
                              _changes[tag.key] ?? selected.contains(tag.key),
                          onChanged:
                              _saving ||
                                  (!widget.excluded &&
                                      removals.isHidden(
                                        interestTagRemovalKey(tag.key),
                                      ))
                              ? null
                              : (value) => setState(() {
                                  if (value == selected.contains(tag.key)) {
                                    _changes.remove(tag.key);
                                  } else {
                                    _changes[tag.key] = value!;
                                  }
                                }),
                        );
                      },
                    ),
                  ),
                ],
              );
            },
          );
    return PopScope(
      canPop: !_saving,
      child: Scaffold(
        floatingActionButton: Padding(
          padding: EdgeInsets.only(bottom: MobileOverlayInset.of(context)),
          child: FloatingActionButton.extended(
            key: const ValueKey('my_tags_confirm'),
            onPressed: controller == null || _saving ? null : _confirm,
            icon: _saving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.check_rounded),
            label: Text(i18n.tr('confirm')),
          ),
        ),
        body: ScrollActivityGate(
          child: PageHeaderInset(
            topInset: headerTopInset,
            child: Stack(
              children: [
                Positioned.fill(child: content),
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: TopPageHeader(
                    title: i18n.tr(
                      widget.excluded ? 'my_excluded_tags' : 'my_add_interest',
                    ),
                    icon: widget.excluded
                        ? Icons.block_rounded
                        : Icons.sell_outlined,
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
                            hintText: i18n.tr('my_search_tags'),
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
