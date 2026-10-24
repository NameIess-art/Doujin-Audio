import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/app_runtime_providers.dart';
import '../theme/app_styles.dart';
import '../../core/widgets/app_feedback.dart';
import '../../core/widgets/app_transitions.dart';
import '../../core/widgets/mobile_overlay_inset.dart';
import '../../core/widgets/page_header_inset.dart';
import '../../core/widgets/scroll_activity_gate.dart';
import '../../core/widgets/top_page_header.dart';
import '../../features/asmr/presentation/asmr_providers.dart';

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
              final listened = {
                for (final interest in controller.listenedTagInterests)
                  interest.tag.key: interest.weight,
              };
              final selected = widget.excluded
                  ? controller.excludedTagKeys
                  : {...controller.manualInterestTagKeys, ...listened.keys};
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
                  final weight = (listened[b.key] ?? 0).compareTo(
                    listened[a.key] ?? 0,
                  );
                  if (weight != 0) return weight;
                  final selection = (selected.contains(b.key) ? 1 : 0)
                      .compareTo(selected.contains(a.key) ? 1 : 0);
                  if (selection != 0) return selection;
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
                          subtitle:
                              !widget.excluded && listened.containsKey(tag.key)
                              ? Text(i18n.tr('my_listened_tag'))
                              : null,
                          value:
                              (!widget.excluded &&
                                  listened.containsKey(tag.key)) ||
                              (_changes[tag.key] ?? selected.contains(tag.key)),
                          onChanged:
                              _saving ||
                                  (!widget.excluded &&
                                      listened.containsKey(tag.key))
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
