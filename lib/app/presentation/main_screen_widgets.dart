part of 'main_screen.dart';

class _AmbientBackground extends StatelessWidget {
  const _AmbientBackground({this.tinyMode = false});

  final bool tinyMode;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (tinyMode) {
      return DecoratedBox(decoration: BoxDecoration(color: cs.surface));
    }
    return RepaintBoundary(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: cs.surface,
          border: Border(
            top: BorderSide(color: cs.primary.withValues(alpha: 0.045)),
          ),
        ),
      ),
    );
  }
}

class _BottomDestinationInkResponse extends StatelessWidget {
  const _BottomDestinationInkResponse({
    required this.inkKey,
    required this.onTap,
    required this.child,
  });

  final Key inkKey;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return InkResponse(
      key: inkKey,
      onTap: onTap,
      // Consume long presses so they do not turn into navigation taps.
      onLongPress: () {},
      containedInkWell: true,
      radius: 32,
      highlightColor: Colors.transparent,
      splashColor: Colors.transparent,
      child: child,
    );
  }
}

class _GlobalUpdateOperationBanner extends ConsumerWidget {
  const _GlobalUpdateOperationBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final operation = ref.watch(
      uiOperationForScopeProvider(UiOperationScope.settingsUpdate),
    );
    final isDownloadOperation = operation.labelKey == 'downloading_update';
    if (!isDownloadOperation || (!operation.isBusy && !operation.hasError)) {
      return const SizedBox.shrink();
    }

    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final top =
        MediaQuery.paddingOf(context).top +
        AppPageHeaderMetrics.toolbarHeight +
        8;
    final hasError = operation.hasError;
    final progress = operation.progress;
    final percent = progress == null ? '--' : '${(progress * 100).round()}';
    final message = hasError
        ? i18n.tr('update_download_failed_next_step')
        : i18n.tr('downloading_update', {'percent': percent});
    final label = message;

    return Positioned(
      top: top,
      left: 12,
      right: 12,
      child: IgnorePointer(
        ignoring: !hasError,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Material(
              color: Colors.transparent,
              child: AppFeedbackSurface(
                tone: hasError
                    ? AppFeedbackTone.destructive
                    : AppFeedbackTone.info,
                icon: hasError
                    ? Icons.error_outline_rounded
                    : Icons.download_rounded,
                title: hasError
                    ? i18n.tr('update_download_failed')
                    : i18n.tr('download_update'),
                message: label,
                trailing: SizedBox(
                  width: 72,
                  child: LinearProgressIndicator(value: progress),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TimerPresentation {
  const _TimerPresentation({
    required this.duration,
    required this.remaining,
    required this.active,
    required this.mode,
  });

  final Duration? duration;
  final Duration? remaining;
  final bool active;
  final TimerMode? mode;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is _TimerPresentation &&
        other.duration == duration &&
        other.remaining == remaining &&
        other.active == active &&
        other.mode == mode;
  }

  @override
  int get hashCode => Object.hash(duration, remaining, active, mode);
}
