import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/app_runtime_providers.dart';
import '../state/listening_activity_provider.dart';
import '../theme/app_styles.dart';
import '../../core/media/music_track.dart';
import '../../core/media/path_display.dart';
import '../../core/logging/app_log_service.dart';
import '../../core/ui/ui_interaction_coordinator.dart';
import '../../core/ui/interaction_deferred_stream.dart';
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

  void _openTags(bool excluded, {bool voiceActors = false}) =>
      Navigator.of(context).push<void>(
        buildAppPageRoute<void>(
          context: context,
          child: MyTagManagementPage(
            excluded: excluded,
            voiceActors: voiceActors,
          ),
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
    final activity = ref.watch(listeningActivityProvider);
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
      String? titleNote,
      bool skeleton = false,
    }) {
      final titleLabel = Wrap(
        spacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          if (titleNote != null)
            Text(
              titleNote,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(
                  context,
                ).colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
              ),
            ),
        ],
      );
      return Card(
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
              const SizedBox(height: 4),
              child,
            ],
          ),
        ),
      );
    }

    Widget interestSection({bool voiceActors = false}) => section(
      i18n.tr(voiceActors ? 'my_voice_interests' : 'my_interests'),
      controller == null
          ? Text(
              i18n.tr(
                voiceActors ? 'my_no_voice_interests' : 'my_no_interests',
              ),
            )
          : Consumer(
              builder: (context, ref, _) {
                final interests =
                    ref
                        .watch(
                          voiceActors
                              ? asmrVoiceActorInterestsProvider
                              : asmrTagInterestsProvider,
                        )
                        .value ??
                    const [];
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (interests.isEmpty)
                      Text(
                        i18n.tr(
                          voiceActors
                              ? 'my_no_voice_interests'
                              : 'my_no_interests',
                        ),
                      ),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final interest in interests.take(
                          voiceActors ? 10 : 20,
                        ))
                          InputChip(
                            key: ValueKey(
                              'my-${voiceActors ? 'voice-' : ''}interest-${interest.tag.key}',
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
                                i18n.tr('copied_to_clipboard', {'value': name}),
                                icon: Icons.content_copy_rounded,
                              );
                            },
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        OutlinedButton.icon(
                          onPressed: () =>
                              _openTags(false, voiceActors: voiceActors),
                          icon: const Icon(Icons.add_rounded),
                          label: Text(
                            i18n.tr(
                              voiceActors
                                  ? 'my_add_voice_interest'
                                  : 'my_add_interest',
                            ),
                          ),
                        ),
                        if (!voiceActors)
                          OutlinedButton.icon(
                            onPressed: () => _openTags(true),
                            icon: const Icon(Icons.block_rounded),
                            label: Text(i18n.tr('my_excluded_tags')),
                          ),
                      ],
                    ),
                  ],
                );
              },
            ),
      titleNote: i18n.tr(
        voiceActors ? 'my_voice_interest_limit' : 'my_interest_limit',
      ),
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
      // There are only five bounded sections. Recreating an offscreen section
      // would rescan chart history and restart artwork, titles and taste reads
      // as it re-enters the viewport during a drag.
      children: [
        for (final child in children) _RetainedMySection(child: child),
      ],
    );
    Widget listeningChart(ListeningActivityView? view) => Consumer(
      builder: (context, ref, _) {
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
          skeleton: view == null,
        );
        return view == null
            ? ListeningTimeChart.skeleton(
                i18n: i18n,
                style: style,
                builder: buildSection,
              )
            : ListeningTimeChart(
                days: view.days,
                i18n: i18n,
                style: style,
                onStyleChanged: _setChartStyle,
                builder: buildSection,
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
    Widget interestSkeleton({bool voiceActors = false}) => section(
      i18n.tr(voiceActors ? 'my_voice_interests' : 'my_interests'),
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: List.generate(
              voiceActors ? 10 : 20,
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
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              const ShimmerContainer(width: 160, height: 40, borderRadius: 20),
              if (!voiceActors)
                const ShimmerContainer(
                  width: 192,
                  height: 40,
                  borderRadius: 20,
                ),
            ],
          ),
        ],
      ),
      skeleton: true,
      titleNote: i18n.tr(
        voiceActors ? 'my_voice_interest_limit' : 'my_interest_limit',
      ),
    );

    final skeleton = Builder(
      builder: (context) => IgnorePointer(
        child: ExcludeSemantics(
          child: ShimmerLoader(
            key: const ValueKey('my-page-skeleton'),
            child: pageList([
              listeningChart(null),
              section(
                i18n.tr('my_history'),
                coverSkeleton('my-skeleton-history'),
                skeleton: true,
              ),
              section(
                i18n.tr('my_daily_recommendations'),
                coverSkeleton('my-skeleton-daily'),
                skeleton: true,
              ),
              interestSkeleton(),
              interestSkeleton(voiceActors: true),
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
              child: AppPageContentTransition.deferred(
                isReady: activity.hasValue || activity.hasError,
                placeholder: skeleton,
                builder: (_) => pageList([
                  activity.when(
                    data: listeningChart,
                    loading: () => const SizedBox.shrink(),
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
                      loading: () => const SizedBox.shrink(),
                      error: (error, stack) => TextButton(
                        onPressed: _refreshActivity,
                        child: Text(i18n.tr('my_retry')),
                      ),
                    ),
                  ),
                  section(
                    i18n.tr('my_daily_recommendations'),
                    const _DailyRecommendations(),
                  ),
                  interestSection(),
                  interestSection(voiceActors: true),
                ], controller: _scroll),
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

final _dailyRecommendationsProvider = StreamProvider.autoDispose((ref) {
  final controller = ref.watch(asmrLibraryControllerProvider);
  if (controller == null) {
    return Stream.value((
      works: <AsmrWork>[],
      loading: false,
      error: null,
      date: null,
      language: null,
    ));
  }
  return interactionDeferredListenableStream(
    source: controller,
    structural: true,
    read: () => (
      works: controller.dailyRecommendations,
      loading: controller.isLoadingDailyRecommendations,
      error: controller.dailyRecommendationsError,
      date: controller.dailyRecommendationsDate,
      language: controller.contentLanguage,
    ),
  );
});

class _DailyRecommendations extends ConsumerStatefulWidget {
  const _DailyRecommendations();

  @override
  ConsumerState<_DailyRecommendations> createState() =>
      _DailyRecommendationsState();
}

class _DailyRecommendationsState extends ConsumerState<_DailyRecommendations>
    with WidgetsBindingObserver {
  final _scroll = ScrollController();
  late final _commitKey = 'my_daily_${identityHashCode(this)}';
  ValueListenable<TickerModeData>? _ticker;
  Timer? _midnight;
  bool _foreground = true;
  bool _routeVisible = true;

  bool get _visible =>
      mounted &&
      _foreground &&
      _routeVisible &&
      (_ticker?.value.enabled ?? true);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ticker = TickerMode.getValuesNotifier(context);
    if (!identical(ticker, _ticker)) {
      _ticker?.removeListener(_checkDay);
      _ticker = ticker;
      ticker.addListener(_checkDay);
    }
    _routeVisible = ModalRoute.isCurrentOf(context) ?? true;
    _checkDay();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _checkDay();
  }

  void _checkDay() {
    _midnight?.cancel();
    UiInteractionCoordinator.instance.cancelCommit(_commitKey);
    if (!_visible) return;
    UiInteractionCoordinator.instance.scheduleCommit(
      key: _commitKey,
      structural: true,
      canRun: () => _visible,
      commit: () {
        unawaited(
          ref.read(asmrLibraryControllerProvider)?.ensureDailyRecommendations(),
        );
      },
    );
    final now = DateTime.now();
    _midnight = Timer(
      DateTime(now.year, now.month, now.day + 1).difference(now),
      _checkDay,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.removeListener(_checkDay);
    _midnight?.cancel();
    UiInteractionCoordinator.instance.cancelCommit(_commitKey);
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    ref.listen(asmrLibraryControllerProvider, (_, _) => _checkDay());
    ref.listen(appLanguageStateProvider, (_, _) => _checkDay());
    ref.listen(
      _dailyRecommendationsProvider.select((state) => state.value?.language),
      (previous, next) {
        if (next != null && previous != next) _checkDay();
      },
    );
    final state = ref.watch(_dailyRecommendationsProvider).value;
    if (state == null || (state.loading && state.works.isEmpty)) {
      return const SizedBox(
        key: ValueKey('my-daily-loading'),
        height: _HistoryWorkCard.coverHeight + 14,
        child: ShimmerLoader(
          child: Row(
            spacing: 12,
            children: [
              ShimmerContainer(
                width: _HistoryWorkCard.coverWidth,
                height: _HistoryWorkCard.coverHeight,
                borderRadius: 12,
              ),
              Expanded(
                child: ShimmerContainer(
                  height: _HistoryWorkCard.coverHeight,
                  borderRadius: 12,
                ),
              ),
            ],
          ),
        ),
      );
    }
    final now = DateTime.now();
    final today =
        '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final stale = state.date != null && state.date != today;
    return Column(
      key: const ValueKey('my-daily-recommendations'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (state.works.isNotEmpty)
          SizedBox(
            height: _HistoryWorkCard.coverHeight + 14,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: ClipRRect(
                key: const ValueKey('my-daily-viewport'),
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
                      itemCount: state.works.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 12),
                      itemBuilder: (context, index) =>
                          _DailyWorkCard(work: state.works[index]),
                    ),
                  ),
                ),
              ),
            ),
          )
        else if (state.error == null)
          Text(i18n.tr('my_daily_empty')),
        if (stale)
          Text(
            i18n.tr('my_daily_stale'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        if (state.error != null)
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            children: [
              Text(i18n.tr('my_daily_error')),
              TextButton(
                onPressed: _checkDay,
                child: Text(i18n.tr('my_retry')),
              ),
            ],
          ),
      ],
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

class _DailyWorkCard extends ConsumerWidget {
  const _DailyWorkCard({required this.work});
  final AsmrWork work;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final library = ref.read(libraryFacadeProvider);
    final url = work.preferredCoverUrl;
    final coverUi = ref.read(libraryCoverUiControllerProvider);
    return _WorkCoverCard(
      cardKey: 'my-daily-card-${work.workKey}',
      titleKey: 'my-daily-title-${work.workKey}',
      title: work.title,
      onOpen: () => showAsmrWorkDetailSheet(context, work),
      cover: AsyncRemoteCoverImage(
        url: url,
        future: coverUi.deferredRemoteCover(url, context: context),
        initialPath: library.resolvedCoverPathForRemoteCover(url),
        retryFutureBuilder: () =>
            coverUi.deferredRemoteCover(url, context: context),
        onImageError: library.coverArtworkCacheService.reportArtworkReadFailure,
        retryDelay: const Duration(seconds: 5),
        maxRetryAttempts: 2,
        fit: BoxFit.cover,
        deferLoadDuringInteraction: true,
        cacheWidth: 320,
        fallbackBuilder: (_) => const CoverFallbackArtwork(),
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
          width: _HistoryWorkCard.coverWidth,
          child: ClipRRect(
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
    );
  }
}
