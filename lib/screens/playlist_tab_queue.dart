part of 'playlist_tab.dart';

class _PlaybackQueueCard extends StatelessWidget {
  const _PlaybackQueueCard({
    required this.session,
    required this.provider,
    required this.onOpen,
    required this.onEdit,
  });

  final PlaybackSession session;
  final AudioProvider provider;
  final VoidCallback onOpen;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final i18n = context.watch<AppLanguageProvider>();
    final cs = Theme.of(context).colorScheme;
    final queue = session.playbackQueue!;
    final tracks = queue.expandedTracks;
    final color = queue.colorValue == null
        ? cs.primary
        : Color(queue.colorValue!);
    final currentTrack = tracks.isEmpty
        ? null
        : tracks[session.currentQueueIndex.clamp(0, tracks.length - 1)];
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(14),
      side: BorderSide(color: color.withValues(alpha: 0.42)),
    );
    return SwipeRevealCard(
      key: ValueKey(session.id),
      margin: const EdgeInsets.only(bottom: 6),
      shape: shape,
      destructive: false,
      primaryActionIcon: Icons.edit_rounded,
      actionLabel: i18n.tr('edit'),
      removeTooltip: i18n.tr('edit_playback_queue'),
      onRemove: onEdit,
      child: Card(
        margin: EdgeInsets.zero,
        elevation: 0,
        color: color.withValues(alpha: 0.10),
        shape: shape,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
            child: Row(
              children: [
                _QueueCoverGrid(provider: provider, tracks: tracks),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        queue.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              fontWeight: FontWeight.w800,
                              color: color,
                            ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        currentTrack?.displayName ??
                            i18n.tr('empty_playback_queue'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: session.state.playing
                      ? i18n.tr('pause')
                      : i18n.tr('play'),
                  onPressed: tracks.isEmpty
                      ? null
                      : () => provider.toggleSessionPlayPause(session.id),
                  icon: Icon(
                    session.state.playing
                        ? Icons.pause_circle_filled_rounded
                        : Icons.play_circle_fill_rounded,
                    color: color,
                    size: 30,
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

class _QueueCoverGrid extends StatelessWidget {
  const _QueueCoverGrid({required this.provider, required this.tracks});

  final AudioProvider provider;
  final List<MusicTrack> tracks;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox.square(
        dimension: 68,
        child: GridView.builder(
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.zero,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
          ),
          itemCount: 4,
          itemBuilder: (context, index) {
            if (index >= tracks.length) {
              return ColoredBox(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: const Icon(Icons.music_note_rounded, size: 16),
              );
            }
            final track = tracks[index];
            return AsyncCoverImage(
              future: _coverFutureForTrack(provider, track),
              initialPath: provider.resolvedCoverPathForTrack(track),
              imageBuilder: (context, path) => RetryingFileImage(
                path: path,
                fit: BoxFit.cover,
                fallbackBuilder: (_) =>
                    CoverFallbackArtwork(seed: track.displayName),
              ),
              fallbackBuilder: (_) =>
                  CoverFallbackArtwork(seed: track.displayName),
            );
          },
        ),
      ),
    );
  }
}

class PlaybackQueueEditPage extends ConsumerWidget {
  const PlaybackQueueEditPage({super.key, required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(playbackStateProvider);
    final provider = ref.read(audioProviderFacadeProvider);
    final session = provider.sessionById(sessionId);
    final queue = session?.playbackQueue;
    final i18n = context.watch<AppLanguageProvider>();
    if (queue == null) return const SizedBox.shrink();
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            TopPageHeader(
              icon: Icons.edit_rounded,
              title: queue.name,
              trailing: IconButton(
                icon: const Icon(Icons.arrow_back_rounded),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _queueEditTile(
                    context,
                    Icons.queue_music_rounded,
                    i18n.tr('edit_queue_audio'),
                    () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            PlaybackQueueAudioEditPage(sessionId: sessionId),
                      ),
                    ),
                  ),
                  _queueEditTile(
                    context,
                    Icons.drive_file_rename_outline_rounded,
                    i18n.tr('edit_queue_name'),
                    () => _editQueueName(context, provider, queue.name),
                  ),
                  _queueEditTile(
                    context,
                    Icons.palette_outlined,
                    i18n.tr('edit_card_color'),
                    () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            _PlaybackQueueColorPage(sessionId: sessionId),
                      ),
                    ),
                  ),
                  _queueEditTile(
                    context,
                    Icons.delete_outline_rounded,
                    i18n.tr('remove_queue'),
                    () => _removeQueue(context, provider),
                    destructive: true,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _queueEditTile(
    BuildContext context,
    IconData icon,
    String title,
    VoidCallback onTap, {
    bool destructive = false,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: ListTile(
        leading: Icon(icon, color: destructive ? cs.error : cs.primary),
        title: Text(title),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: onTap,
      ),
    );
  }

  Future<void> _editQueueName(
    BuildContext context,
    AudioProvider provider,
    String currentName,
  ) async {
    final controller = TextEditingController(text: currentName);
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(context.read<AppLanguageProvider>().tr('edit_queue_name')),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(context.read<AppLanguageProvider>().tr('cancel')),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: Text(context.read<AppLanguageProvider>().tr('save')),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name?.isNotEmpty == true) {
      provider.renamePlaybackQueue(sessionId, name!);
    }
  }

  Future<void> _removeQueue(
    BuildContext context,
    AudioProvider provider,
  ) async {
    final i18n = context.read<AppLanguageProvider>();
    final confirmed = await showConfirmActionDialog(
      context: context,
      title: i18n.tr('remove_queue'),
      message: i18n.tr('remove_queue_confirm'),
      cancelLabel: i18n.tr('cancel'),
      confirmLabel: i18n.tr('remove'),
      icon: Icons.delete_outline_rounded,
    );
    if (!confirmed || !context.mounted) return;
    await provider.removeSession(sessionId);
    if (context.mounted) Navigator.of(context).pop();
  }
}

class PlaybackQueueAudioEditPage extends ConsumerWidget {
  const PlaybackQueueAudioEditPage({super.key, required this.sessionId});
  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(playbackStateProvider);
    final provider = ref.read(audioProviderFacadeProvider);
    final queue = provider.sessionById(sessionId)?.playbackQueue;
    final i18n = context.watch<AppLanguageProvider>();
    if (queue == null) return const SizedBox.shrink();
    return Scaffold(
      appBar: AppBar(title: Text(i18n.tr('edit_queue_audio'))),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Text(
            i18n.tr('queue_added_audio'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          if (queue.entries.isEmpty)
            ListTile(title: Text(i18n.tr('empty_playback_queue'))),
          for (final entry in queue.entries)
            Card(
              child: ListTile(
                title: Text(entry.title),
                subtitle: Text(
                  i18n.tr('audio_count', {'count': entry.tracks.length}),
                ),
                trailing: IconButton(
                  tooltip: i18n.tr('remove'),
                  icon: const Icon(Icons.remove_circle_outline_rounded),
                  onPressed: () =>
                      provider.removePlaybackQueueEntry(sessionId, entry.id),
                ),
              ),
            ),
          const SizedBox(height: 18),
          Text(
            i18n.tr('playback_list_audio'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          for (final source in provider.ordinaryPlaybackSessions)
            _QueueSourceAudioTile(queueSessionId: sessionId, source: source),
        ],
      ),
    );
  }
}

class _QueueSourceAudioTile extends ConsumerWidget {
  const _QueueSourceAudioTile({
    required this.queueSessionId,
    required this.source,
  });
  final String queueSessionId;
  final PlaybackSession source;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = ref.read(audioProviderFacadeProvider);
    final track = provider.trackByPath(source.currentTrackPath);
    if (track == null) return const SizedBox.shrink();
    final i18n = context.watch<AppLanguageProvider>();
    return Card(
      child: ListTile(
        title: Text(track.displayName),
        subtitle: Text(track.groupTitle),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: i18n.tr('add_audio_to_queue'),
              icon: const Icon(Icons.add_circle_outline_rounded),
              onPressed: () =>
                  provider.addTrackToPlaybackQueue(queueSessionId, track),
            ),
            IconButton(
              tooltip: i18n.tr('add_work_to_queue'),
              icon: const Icon(Icons.library_add_rounded),
              onPressed: () =>
                  provider.addWorkToPlaybackQueue(queueSessionId, track),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlaybackQueueColorPage extends ConsumerWidget {
  const _PlaybackQueueColorPage({required this.sessionId});
  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(playbackStateProvider);
    final provider = ref.read(audioProviderFacadeProvider);
    final value = provider.sessionById(sessionId)?.playbackQueue?.colorValue;
    final color = value == null
        ? Theme.of(context).colorScheme.primary
        : Color(value);
    final i18n = context.watch<AppLanguageProvider>();
    return Scaffold(
      appBar: AppBar(title: Text(i18n.tr('edit_card_color'))),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Center(child: CircleAvatar(radius: 34, backgroundColor: color)),
          const SizedBox(height: 20),
          for (final channel in <(String, int)>[
            ('R', (color.r * 255).round()),
            ('G', (color.g * 255).round()),
            ('B', (color.b * 255).round()),
          ])
            Row(
              children: [
                SizedBox(width: 24, child: Text(channel.$1)),
                Expanded(
                  child: Slider(
                    max: 255,
                    value: channel.$2.toDouble(),
                    onChanged: (next) {
                      final r = channel.$1 == 'R'
                          ? next.round()
                          : (color.r * 255).round();
                      final g = channel.$1 == 'G'
                          ? next.round()
                          : (color.g * 255).round();
                      final b = channel.$1 == 'B'
                          ? next.round()
                          : (color.b * 255).round();
                      provider.setPlaybackQueueColor(
                        sessionId,
                        Color.fromARGB(255, r, g, b),
                      );
                    },
                  ),
                ),
              ],
            ),
          TextButton(
            onPressed: () => provider.setPlaybackQueueColor(sessionId, null),
            child: Text(i18n.tr('reset_to_default')),
          ),
        ],
      ),
    );
  }
}
