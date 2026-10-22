import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/app_runtime_providers.dart';
import '../../core/widgets/app_feedback.dart';
import '../../core/widgets/mobile_overlay_inset.dart';
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
  final _pending = <String>{};

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

  Future<void> _set(String key, bool selected) async {
    final controller = ref.read(asmrLibraryControllerProvider);
    if (controller == null) return;
    setState(() => _pending.add(key));
    try {
      if (widget.excluded) {
        await controller.setTagExcluded(key, selected);
      } else {
        await controller.setTagInterested(key, selected);
      }
    } catch (error) {
      if (mounted) showAppSnackBar(context, error.toString());
    } finally {
      if (mounted) setState(() => _pending.remove(key));
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final controller = ref.watch(asmrLibraryControllerProvider);
    return Scaffold(
      appBar: AppPageAppBar(
        title: Text(
          i18n.tr(widget.excluded ? 'my_excluded_tags' : 'my_add_interest'),
        ),
        icon: widget.excluded ? Icons.block_rounded : Icons.sell_outlined,
      ),
      body: controller == null
          ? Center(child: Text(i18n.tr('my_catalog_incomplete')))
          : ListenableBuilder(
              listenable: controller,
              builder: (context, _) {
                final interests = {
                  for (final interest in controller.interestTags)
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
                return Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: TextField(
                        controller: _search,
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(
                          labelText: i18n.tr('my_search_tags'),
                          prefixIcon: const Icon(Icons.search_rounded),
                          suffixIcon: _search.text.isEmpty
                              ? null
                              : IconButton(
                                  onPressed: () => setState(_search.clear),
                                  icon: const Icon(Icons.clear_rounded),
                                ),
                        ),
                      ),
                    ),
                    if (controller.isLoadingTagCatalog)
                      const LinearProgressIndicator(),
                    if (!controller.tagCatalogComplete)
                      Padding(
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
                    Expanded(
                      child: ListView.builder(
                        padding: EdgeInsets.only(
                          bottom: MobileOverlayInset.of(context) + 16,
                        ),
                        itemCount: tags.length,
                        itemBuilder: (context, index) {
                          final tag = tags[index];
                          return CheckboxListTile(
                            key: ValueKey(tag.key),
                            title: Text(tag.name),
                            value: selected.contains(tag.key),
                            onChanged: _pending.contains(tag.key)
                                ? null
                                : (value) => unawaited(_set(tag.key, value!)),
                            secondary: _pending.contains(tag.key)
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : null,
                          );
                        },
                      ),
                    ),
                  ],
                );
              },
            ),
    );
  }
}
