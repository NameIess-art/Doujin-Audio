import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/app_runtime_providers.dart';
import '../state/listening_activity_provider.dart';
import '../theme/app_styles.dart';
import '../../core/media/music_track.dart';
import '../../core/media/path_display.dart';
import '../../core/logging/app_log_service.dart';
import '../../core/widgets/app_feedback.dart';
import '../../core/widgets/app_transitions.dart';
import '../../core/widgets/async_cover_image.dart';
import '../../core/widgets/mobile_overlay_inset.dart';
import '../../core/widgets/page_header_inset.dart';
import '../../core/widgets/scroll_activity_gate.dart';
import '../../core/widgets/top_page_header.dart';
import '../../core/widgets/windows_horizontal_wheel_scroll.dart';
import '../../features/asmr/domain/asmr_models.dart';
import '../../features/asmr/presentation/asmr_providers.dart';
import '../../features/asmr/presentation/asmr_work_detail_sheet.dart';
import '../../features/library/presentation/audio_detail_sheet.dart';
import '../../features/library/presentation/library_providers.dart';
import '../../features/settings/application/settings_state.dart';
import '../../features/settings/presentation/settings_providers.dart';
import 'app_presentation_providers.dart';
import 'listening_time_chart.dart';
import 'main_tab_state_mixin.dart';
import 'my_tag_management_page.dart';

class MyPage extends ConsumerStatefulWidget {
  const MyPage({super.key, required this.tabIndex});
  final int tabIndex;

  @override
  ConsumerState<MyPage> createState() => _MyPageState();
}

class _MyPageState extends ConsumerState<MyPage>
    with MainTabStateMixin<MyPage> {
  final _scroll = ScrollController();
  bool _editing = false;
  final _removingInterests = <String>{};
  @override
  int get tabIndex => widget.tabIndex;
  @override
  ScrollController get mainScrollController => _scroll;

  @override
  void initState() {
    super.initState();
    final controller = ref.read(mainScreenControllerProvider);
    initTabState(controller.scrollToTopTab, controller.stopScrollTab);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_refreshActivity());
    });
  }

  @override
  void dispose() {
    disposeTabState();
    _scroll.dispose();
    super.dispose();
  }

  void _openTags(bool excluded) => Navigator.of(context).push<void>(
    buildAppPageRoute<void>(
      context: context,
      child: MyTagManagementPage(excluded: excluded),
    ),
  );

  Future<void> _removeInterest(String key) async {
    setState(() => _removingInterests.add(key));
    try {
      await removeInterestTagWithUndo(context, ref, key);
    } catch (error, stack) {
      AppLogService.error(
        'my_interest_remove_failed',
        error: error,
        stackTrace: stack,
      );
      if (mounted) {
        showAppSnackBar(
          context,
          ref
              .read(appLanguageProviderInstanceProvider)
              .tr('operation_failed_retry'),
        );
      }
    } finally {
      if (mounted) setState(() => _removingInterests.remove(key));
    }
  }

  Future<void> _refreshActivity() async {
    try {
      await ref.read(listeningActivityServiceProvider)?.refresh();
    } catch (error, stack) {
      AppLogService.error(
        'my_activity_refresh_failed',
        error: error,
        stackTrace: stack,
      );
      if (mounted) {
        showAppSnackBar(
          context,
          ref
              .read(appLanguageProviderInstanceProvider)
              .tr('operation_failed_retry'),
        );
      }
    }
  }

  Future<void> _openHistory(MusicTrack track) async {
    final library = ref.read(libraryFacadeProvider);
    final local = library.library
        .where(
          (candidate) =>
              !candidate.isRemoteAsmr &&
              listeningWorkKey(candidate) == listeningWorkKey(track),
        )
        .firstOrNull;
    if (local != null && !local.isRemoteAsmr) {
      await showAudioDetailSheet(
        context,
        library.audioDetailTargetForTrack(local),
      );
    } else if (track.remoteMetadata != null) {
      await showAsmrWorkDetailSheet(
        context,
        AsmrWork.fromJson(track.remoteMetadata!),
      );
    } else {
      showAppSnackBar(
        context,
        ref.read(appLanguageProviderInstanceProvider).tr('my_work_unavailable'),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final activity = ref.watch(listeningActivityProvider);
    final controller = ref.watch(asmrLibraryControllerProvider);
    final removals = ref.watch(undoableRemovalStateProvider);
    final top =
        MediaQuery.paddingOf(context).top +
        AppPageHeaderMetrics.padding.vertical +
        AppPageHeaderMetrics.contentHeight +
        AppPageHeaderMetrics.bottomSpacing +
        AppPageHeaderMetrics.firstContentSpacing;
    Widget section(String title, Widget child, {Widget? trailing}) => Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ConstrainedBox(
              key: ValueKey('my-section-header-$title'),
              constraints: const BoxConstraints(minHeight: 32),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  if (trailing != null) ...[
                    const SizedBox(width: 8),
                    Flexible(child: trailing),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 4),
            child,
          ],
        ),
      ),
    );
    return ScrollActivityGate(
      child: PageHeaderInset(
        topInset: top,
        child: Stack(
          children: [
            Positioned.fill(
              child: AppPageContentTransition(
                child: ListView(
                  controller: _scroll,
                  padding: EdgeInsets.fromLTRB(
                    16,
                    top,
                    16,
                    MobileOverlayInset.of(context) + 16,
                  ),
                  children: [
                    activity.when(
                      data: (view) => ListeningTimeChart(
                        days: view.days,
                        i18n: i18n,
                        builder: (duration, chart) => section(
                          i18n.tr('my_listening_time'),
                          chart,
                          trailing: duration,
                        ),
                      ),
                      loading: () => section(
                        i18n.tr('my_listening_time'),
                        const Center(child: CircularProgressIndicator()),
                      ),
                      error: (error, stack) => section(
                        i18n.tr('my_listening_time'),
                        TextButton(
                          onPressed: _refreshActivity,
                          child: Text(i18n.tr('my_retry')),
                        ),
                      ),
                    ),
                    section(
                      i18n.tr('my_history'),
                      activity.when(
                        data: (view) => view.history.isEmpty
                            ? Text(i18n.tr('my_no_history'))
                            : _HistoryStrip(view: view, onOpen: _openHistory),
                        loading: () =>
                            const Center(child: CircularProgressIndicator()),
                        error: (error, stack) => TextButton(
                          onPressed: _refreshActivity,
                          child: Text(i18n.tr('my_retry')),
                        ),
                      ),
                    ),
                    section(
                      i18n.tr('my_interests'),
                      controller == null
                          ? Text(i18n.tr('my_no_interests'))
                          : ListenableBuilder(
                              listenable: controller,
                              builder: (context, _) => Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (controller.interestTags.isEmpty)
                                    Text(i18n.tr('my_no_interests')),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 2,
                                    children: [
                                      for (final interest
                                          in controller.interestTags)
                                        if (!removals.isHidden(
                                          interestTagRemovalKey(
                                            interest.tag.key,
                                          ),
                                        ))
                                          InputChip(
                                            key: ValueKey(
                                              'my-interest-${interest.tag.key}',
                                            ),
                                            visualDensity:
                                                VisualDensity.compact,
                                            label: Text(interest.tag.name),
                                            onDeleted:
                                                _editing &&
                                                    !_removingInterests
                                                        .contains(
                                                          interest.tag.key,
                                                        )
                                                ? () => unawaited(
                                                    _removeInterest(
                                                      interest.tag.key,
                                                    ),
                                                  )
                                                : null,
                                          ),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 4,
                                    children: [
                                      OutlinedButton.icon(
                                        onPressed: () => _openTags(false),
                                        icon: const Icon(Icons.add_rounded),
                                        label: Text(i18n.tr('my_add_interest')),
                                      ),
                                      OutlinedButton.icon(
                                        onPressed: () => _openTags(true),
                                        icon: const Icon(Icons.block_rounded),
                                        label: Text(
                                          i18n.tr('my_excluded_tags'),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                      trailing: TextButton(
                        style: TextButton.styleFrom(
                          minimumSize: const Size(0, 32),
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        onPressed: () => setState(() => _editing = !_editing),
                        child: Text(i18n.tr(_editing ? 'my_done' : 'my_edit')),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: TopPageHeader(
                key: headerKey,
                icon: Icons.person_rounded,
                topCapsuleTitle: i18n.tr('nav_my'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HistoryStrip extends ConsumerStatefulWidget {
  const _HistoryStrip({required this.view, required this.onOpen});
  final ListeningActivityView view;
  final Future<void> Function(MusicTrack track) onOpen;
  @override
  ConsumerState<_HistoryStrip> createState() => _HistoryStripState();
}

class _HistoryStripState extends ConsumerState<_HistoryStrip> {
  final _scroll = ScrollController();
  bool _loading = false;
  Object? _loadError;
  @override
  void initState() {
    super.initState();
    _scroll.addListener(_loadNearEnd);
  }

  void _loadNearEnd() {
    if (_scroll.hasClients &&
        _scroll.position.extentAfter < 250 &&
        !_loading &&
        _loadError == null &&
        widget.view.hasMoreHistory) {
      unawaited(_loadMore());
    }
  }

  Future<void> _loadMore() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      await ref.read(listeningActivityServiceProvider)?.loadMoreHistory();
    } catch (error) {
      if (mounted) setState(() => _loadError = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    return SizedBox(
      height: _HistoryWorkCard.coverHeight + 14,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: ClipRRect(
          key: const ValueKey('my-history-viewport'),
          borderRadius: BorderRadius.circular(12),
          child: WindowsHorizontalWheelScroll(
            controller: _scroll,
            builder: (controller) => ScrollConfiguration(
              behavior: ScrollConfiguration.of(
                context,
              ).copyWith(dragDevices: PointerDeviceKind.values.toSet()),
              child: ListView.separated(
                controller: controller,
                scrollDirection: Axis.horizontal,
                itemCount:
                    widget.view.history.length +
                    (widget.view.hasMoreHistory ? 1 : 0),
                separatorBuilder: (_, _) => const SizedBox(width: 12),
                itemBuilder: (context, index) {
                  if (index == widget.view.history.length) {
                    return SizedBox(
                      width: 100,
                      child: Center(
                        child: _loading
                            ? const CircularProgressIndicator()
                            : TextButton(
                                onPressed: _loadMore,
                                child: Text(
                                  i18n.tr(
                                    _loadError == null
                                        ? 'my_load_more'
                                        : 'my_retry',
                                  ),
                                ),
                              ),
                      ),
                    );
                  }
                  return _HistoryWorkCard(
                    entry: widget.view.history[index],
                    onOpen: widget.onOpen,
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final _historyWorkTitleProvider = FutureProvider.autoDispose
    .family<String?, MusicTrack>((ref, track) async {
      final metadataTitle = track.remoteMetadata?['title']?.toString().trim();
      if (track.isRemoteAsmr) {
        return metadataTitle?.isNotEmpty == true
            ? metadataTitle
            : (track.groupTitle.trim().isEmpty ? null : track.groupTitle);
      }
      final displayMode = ref.watch(
        settingsStateProvider.select(
          (state) => state.value?.workNameDisplay ?? WorkNameDisplay.workTitle,
        ),
      );
      final library = ref.watch(libraryFacadeProvider);
      final target = library.audioDetailTargetForTrack(track);
      final folderName = PathDisplay.folderName(target.targetPath);
      if (displayMode == WorkNameDisplay.folderName) return folderName;
      ref.watch(libraryDetailTargetRevisionProvider(target));
      final cached =
          library.resolvedAudioDetail(target) ??
          library.categorySnapshot?.detailFor(target);
      final detail = cached ?? (await library.loadAudioDetail(target)).detail;
      final title = detail.workTitle.trim();
      return title.isNotEmpty ? title : folderName;
    });

class _HistoryWorkCard extends ConsumerWidget {
  const _HistoryWorkCard({required this.entry, required this.onOpen});
  static const double coverWidth = 132;
  static const double coverHeight = coverWidth * 3 / 4;
  final ListeningHistoryEntry entry;
  final Future<void> Function(MusicTrack track) onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final library = ref.read(libraryFacadeProvider);
    final title =
        ref.watch(_historyWorkTitleProvider(entry.track)).value ??
        ref.read(appLanguageProviderInstanceProvider).tr('my_untitled_work');
    return Tooltip(
      message: title,
      child: Semantics(
        label: title,
        button: true,
        child: SizedBox(
          width: coverWidth,
          child: ClipRRect(
            key: ValueKey('my-history-card-${entry.workKey}'),
            borderRadius: BorderRadius.circular(12),
            child: Material(
              child: InkWell(
                onTap: () => onOpen(entry.track),
                child: ExcludeSemantics(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      AsyncLocalCoverImage(
                        requestKey: entry.workKey,
                        future: library.coverPathFutureForTrack(entry.track),
                        initialPath: library.resolvedCoverPathForTrack(
                          entry.track,
                        ),
                        fit: BoxFit.cover,
                        cacheWidth: 320,
                      ),
                      Positioned(
                        bottom: 8,
                        left: 8,
                        right: 8,
                        child: Text(
                          title,
                          key: ValueKey('my-history-title-${entry.workKey}'),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            height: 1.25,
                            shadows: [
                              Shadow(
                                color: Colors.black87,
                                blurRadius: 4,
                                offset: Offset(0, 1),
                              ),
                            ],
                          ),
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
    );
  }
}
