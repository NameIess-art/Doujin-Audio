import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/app_runtime_providers.dart';
import '../state/listening_activity_provider.dart';
import '../theme/app_styles.dart';
import '../theme/app_design_tokens.dart';
import '../../core/media/music_track.dart';
import '../../core/media/path_display.dart';
import '../../core/logging/app_log_service.dart';
import '../../core/ui/ui_interaction_coordinator.dart';
import '../../core/widgets/app_feedback.dart';
import '../../core/widgets/app_transitions.dart';
import '../../core/widgets/async_cover_image.dart';
import '../../core/widgets/mobile_overlay_inset.dart';
import '../../core/widgets/page_header_inset.dart';
import '../../core/widgets/scroll_activity_gate.dart';
import '../../core/widgets/shimmer_loading.dart';
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
  const MyPage({super.key, required this.tabIndex, this.onSwitchPage});
  final int tabIndex;
  final VoidCallback? onSwitchPage;

  @override
  ConsumerState<MyPage> createState() => _MyPageState();
}

class _MyPageState extends ConsumerState<MyPage>
    with MainTabStateMixin<MyPage> {
  final _scroll = ScrollController();
  MyInterestType _interestType = MyInterestType.tags;
  late final _refreshCommitKey =
      'my_activity_refresh_${identityHashCode(this)}';
  @override
  int get tabIndex => widget.tabIndex;
  @override
  bool get handlesScrollToTop =>
      TickerMode.getValuesNotifier(context).value.enabled;
  @override
  ScrollController get mainScrollController => _scroll;

  @override
  void initState() {
    super.initState();
    final controller = ref.read(mainScreenControllerProvider);
    initTabState(controller.scrollToTopTab, controller.stopScrollTab);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      UiInteractionCoordinator.instance.scheduleCommit(
        key: _refreshCommitKey,
        canRun: () =>
            mounted && TickerMode.getValuesNotifier(context).value.enabled,
        commit: () => unawaited(_refreshActivity()),
      );
    });
  }

  @override
  void dispose() {
    disposeTabState();
    UiInteractionCoordinator.instance.cancelCommit(_refreshCommitKey);
    _scroll.dispose();
    super.dispose();
  }

  void _openTags(bool excluded) => Navigator.of(context).push<void>(
    buildAppPageRoute<void>(
      context: context,
      child: MyTagManagementPage(excluded: excluded, type: _interestType),
    ),
  );

  Future<void> _setChartStyle(ListeningChartStyle style) async {
    try {
      await ref.read(settingsRepositoryProvider).setListeningChartStyle(style);
    } catch (error, stack) {
      AppLogService.error(
        'my_chart_style_save_failed',
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
    final activityReady = ref.watch(
      listeningActivityProvider.select(
        (state) => state.hasValue || state.hasError,
      ),
    );
    final controller = ref.watch(asmrLibraryControllerProvider);
    final top =
        MediaQuery.paddingOf(context).top +
        AppPageHeaderMetrics.padding.vertical +
        AppPageHeaderMetrics.contentHeight +
        AppPageHeaderMetrics.bottomSpacing +
        AppPageHeaderMetrics.firstContentSpacing;
    Widget section(
      String title,
      Widget child, {
      Widget? trailing,
      Widget? titleWidget,
      bool skeleton = false,
      double headerSpacing = 4,
    }) {
      final titleLabel =
          titleWidget ??
          Text(title, style: Theme.of(context).textTheme.titleMedium);
      return Card(
        margin: const EdgeInsets.only(bottom: 16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(
            AppDesignTokens.of(context).radiusCard,
          ),
        ),
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
                      child: skeleton
                          ? Stack(
                              children: [
                                Opacity(opacity: 0, child: titleLabel),
                                const Positioned.fill(
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: ShimmerContainer(
                                      width: 80,
                                      height: 18,
                                    ),
                                  ),
                                ),
                              ],
                            )
                          : titleLabel,
                    ),
                    if (trailing != null) ...[
                      const SizedBox(width: 8),
                      Flexible(child: trailing),
                    ],
                  ],
                ),
              ),
              SizedBox(height: headerSpacing),
              child,
            ],
          ),
        ),
      );
    }

    Widget interestTabs() => Wrap(
      spacing: 8,
      children: [
        for (final type in MyInterestType.values)
          Semantics(
            selected: _interestType == type,
            child: TextButton(
              key: ValueKey(
                'my-interest-tab-${type == MyInterestType.voiceActors ? 'voices' : type.name}',
              ),
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 32),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                textStyle: Theme.of(context).textTheme.titleMedium,
                foregroundColor: _interestType == type
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.onSurfaceVariant,
                backgroundColor: _interestType == type
                    ? Theme.of(context).colorScheme.secondaryContainer
                    : null,
              ),
              onPressed: () {
                if (_interestType == type) return;
                setState(() => _interestType = type);
              },
              child: Text(i18n.tr(type.titleKey)),
            ),
          ),
      ],
    );
    final interestType = _interestType;
    final interestKeyPrefix = switch (interestType) {
      MyInterestType.tags => '',
      MyInterestType.voiceActors => 'voice-',
      MyInterestType.circles => 'circle-',
    };
    Widget interestSection() => section(
      i18n.tr('my_interests'),
      AnimatedSwitcher(
        key: const ValueKey('my-interest-transition'),
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : kAppFadeDuration,
        switchInCurve: kAppFadeCurve,
        switchOutCurve: kAppFadeCurve,
        layoutBuilder: (current, previous) => Stack(
          alignment: Alignment.topLeft,
          children: [
            for (final child in previous)
              ExcludeFocus(
                child: ExcludeSemantics(child: IgnorePointer(child: child)),
              ),
            ?current,
          ],
        ),
        child: KeyedSubtree(
          key: ValueKey(interestType),
          child: controller == null
              ? Text(i18n.tr(interestType.emptyKey))
              : Consumer(
                  builder: (context, ref, _) {
                    final tags = ref.watch(asmrTagInterestsProvider);
                    final voices = ref.watch(asmrVoiceActorInterestsProvider);
                    final circles = ref.watch(asmrCircleInterestsProvider);
                    final state = switch (interestType) {
                      MyInterestType.tags => tags,
                      MyInterestType.voiceActors => voices,
                      MyInterestType.circles => circles,
                    };
                    if (!state.hasValue) {
                      if (state.hasError) {
                        return TextButton(
                          onPressed: () =>
                              ref.invalidate(switch (interestType) {
                                MyInterestType.tags => asmrTagInterestsProvider,
                                MyInterestType.voiceActors =>
                                  asmrVoiceActorInterestsProvider,
                                MyInterestType.circles =>
                                  asmrCircleInterestsProvider,
                              }),
                          child: Text(i18n.tr('my_retry')),
                        );
                      }
                      return const ShimmerLoader(
                        child: ShimmerContainer(
                          width: 120,
                          height: 32,
                          borderRadius: 8,
                        ),
                      );
                    }
                    final interests = state.requireValue;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (interests.isEmpty)
                          Text(i18n.tr(interestType.emptyKey)),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final interest in interests.take(20))
                              InputChip(
                                key: ValueKey(
                                  'my-${interestKeyPrefix}interest-${interest.tag.key}',
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                  vertical: 8,
                                ),
                                labelPadding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                ),
                                visualDensity: VisualDensity.compact,
                                materialTapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                                showCheckmark: false,
                                side: BorderSide(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.outlineVariant,
                                ),
                                label: Text(
                                  interest.tag.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                onPressed: () async {
                                  final name = interest.tag.name;
                                  await Clipboard.setData(
                                    ClipboardData(text: name),
                                  );
                                  if (!context.mounted) return;
                                  showAppSnackBar(
                                    context,
                                    i18n.tr('copied_to_clipboard', {
                                      'value': name,
                                    }),
                                    icon: Icons.content_copy_rounded,
                                  );
                                },
                              ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          children: [
                            OutlinedButton.icon(
                              onPressed: () => _openTags(false),
                              icon: const Icon(Icons.add_rounded),
                              label: Text(i18n.tr(interestType.addKey)),
                            ),
                            OutlinedButton.icon(
                              onPressed: () => _openTags(true),
                              icon: const Icon(Icons.block_rounded),
                              label: Text(i18n.tr(interestType.excludedKey)),
                            ),
                          ],
                        ),
                      ],
                    );
                  },
                ),
        ),
      ),
      titleWidget: interestTabs(),
      headerSpacing: 12,
    );

    Widget pageList(
      List<Widget> children, {
      ScrollController? controller,
      bool scrollable = true,
    }) => ListView(
      controller: controller,
      primary: false,
      physics: scrollable ? null : const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.fromLTRB(
        16,
        top,
        16,
        MobileOverlayInset.of(context) + 16,
      ),
      // There are only three bounded sections. Recreating an offscreen section
      // would rescan chart history and restart artwork, titles and taste reads
      // as it re-enters the viewport during a drag.
      children: [
        for (final child in children) _RetainedMySection(child: child),
      ],
    );
    Widget listeningChart({bool skeleton = false}) => Consumer(
      builder: (context, ref, _) {
        final activity = skeleton ? null : ref.watch(listeningActivityProvider);
        final style =
            ref.watch(
              settingsStateProvider.select(
                (state) => state.value?.listeningChartStyle,
              ),
            ) ??
            ref
                .read(settingsRepositoryProvider)
                .slice
                .state
                .listeningChartStyle;
        Widget buildSection(Widget duration, Widget chart) => section(
          i18n.tr('my_listening_time'),
          chart,
          trailing: duration,
          skeleton: skeleton,
        );
        if (skeleton) {
          return ListeningTimeChart.skeleton(
            i18n: i18n,
            style: style,
            builder: buildSection,
          );
        }
        return activity!.when(
          data: (view) => ListeningTimeChart(
            days: view.days,
            i18n: i18n,
            style: style,
            onStyleChanged: _setChartStyle,
            builder: buildSection,
          ),
          loading: () => const SizedBox.shrink(),
          error: (error, stack) => section(
            i18n.tr('my_listening_time'),
            TextButton(
              onPressed: _refreshActivity,
              child: Text(i18n.tr('my_retry')),
            ),
          ),
        );
      },
    );
    Widget coverSkeleton(String key) => SizedBox(
      key: ValueKey(key),
      height: _HistoryWorkCard.coverHeight + 14,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 12,
          children: List.generate(
            8,
            (_) => const ShimmerContainer(
              width: _HistoryWorkCard.coverWidth,
              height: _HistoryWorkCard.coverHeight,
              borderRadius: 12,
            ),
          ),
        ),
      ),
    );
    Widget interestSkeleton() => section(
      i18n.tr('my_interests'),
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: List.generate(
              20,
              (index) => SizedBox(
                height: 40,
                child: Center(
                  widthFactor: 1,
                  child: ShimmerContainer(
                    width: 48.0 + (index % 3) * 24,
                    height: 28,
                    borderRadius: 8,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          const Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              ShimmerContainer(width: 160, height: 40, borderRadius: 20),
              ShimmerContainer(width: 192, height: 40, borderRadius: 20),
            ],
          ),
        ],
      ),
      skeleton: true,
      titleWidget: interestTabs(),
      headerSpacing: 12,
    );

    final skeleton = Builder(
      builder: (context) => IgnorePointer(
        child: ExcludeSemantics(
          child: ShimmerLoader(
            key: const ValueKey('my-page-skeleton'),
            child: pageList([
              listeningChart(skeleton: true),
              section(
                i18n.tr('my_history'),
                coverSkeleton('my-skeleton-history'),
                skeleton: true,
              ),
              interestSkeleton(),
            ], scrollable: false),
          ),
        ),
      ),
    );
    return ScrollActivityGate(
      child: PageHeaderInset(
        topInset: top,
        child: Stack(
          children: [
            Positioned.fill(
              child: buildScrollToTopTransition(
                AppPageContentTransition.deferred(
                  isReady: activityReady,
                  placeholder: skeleton,
                  builder: (_) => pageList([
                    listeningChart(),
                    section(
                      i18n.tr('my_history'),
                      Consumer(
                        builder: (context, ref, _) => ref
                            .watch(listeningActivityProvider)
                            .when(
                              data: (view) => view.history.isEmpty
                                  ? Text(i18n.tr('my_no_history'))
                                  : _HistoryStrip(
                                      view: view,
                                      onOpen: _openHistory,
                                    ),
                              loading: () => const SizedBox.shrink(),
                              error: (error, stack) => TextButton(
                                onPressed: _refreshActivity,
                                child: Text(i18n.tr('my_retry')),
                              ),
                            ),
                      ),
                    ),
                    interestSection(),
                  ], controller: _scroll),
                ),
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: TopPageHeader(
                key: headerKey,
                titleWidget: HeaderTopCapsule(
                  title: i18n.tr('nav_my'),
                  leading: Icon(
                    Icons.person_rounded,
                    size: 16,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                trailing: widget.onSwitchPage == null
                    ? null
                    : IconButton(
                        key: const ValueKey('switch-to-settings'),
                        tooltip: i18n.tr('switch_to_settings'),
                        onPressed: widget.onSwitchPage,
                        icon: const Icon(Icons.settings_rounded),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RetainedMySection extends StatefulWidget {
  const _RetainedMySection({required this.child});
  final Widget child;

  @override
  State<_RetainedMySection> createState() => _RetainedMySectionState();
}

class _RetainedMySectionState extends State<_RetainedMySection>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
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
              padding: const EdgeInsets.symmetric(horizontal: 2),
              scrollDirection: Axis.horizontal,
              itemCount:
                  widget.view.history.length +
                  (widget.view.hasMoreHistory ? 1 : 0),
              separatorBuilder: (_, _) => const SizedBox.shrink(),
              itemBuilder: (context, index) {
                if (index == widget.view.history.length) {
                  return SizedBox(
                    width: 112,
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
    return _WorkCoverCard(
      cardKey: 'my-history-card-${entry.workKey}',
      titleKey: 'my-history-title-${entry.workKey}',
      title: title,
      onOpen: () => onOpen(entry.track),
      cover: AsyncLocalCoverImage(
        requestKey: entry.workKey,
        future: ref
            .read(libraryCoverUiControllerProvider)
            .deferredTrackCover(entry.track, context: context),
        initialPath: library.resolvedCoverPathForTrack(entry.track),
        fit: BoxFit.cover,
        deferLoadDuringInteraction: true,
        cacheWidth: 320,
      ),
    );
  }
}

class _WorkCoverCard extends StatelessWidget {
  const _WorkCoverCard({
    required this.cardKey,
    required this.titleKey,
    required this.title,
    required this.cover,
    required this.onOpen,
  });
  final String cardKey;
  final String titleKey;
  final String title;
  final Widget cover;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: title,
      child: Semantics(
        label: title,
        button: true,
        child: SizedBox(
          width: _HistoryWorkCard.coverWidth + 12,
          child: ClipRect(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(6, 6, 6, 8),
              child: CoverArtworkFrame(
                key: ValueKey(cardKey),
                borderRadius: BorderRadius.circular(12),
                child: Material(
                  child: InkWell(
                    onTap: onOpen,
                    child: ExcludeSemantics(
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          cover,
                          Positioned(
                            bottom: 8,
                            left: 8,
                            right: 8,
                            child: Text(
                              title,
                              key: ValueKey(titleKey),
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
        ),
      ),
    );
  }
}
