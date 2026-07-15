part of 'playlist_tab.dart';

class _SpeedWheelPage extends ConsumerStatefulWidget {
  const _SpeedWheelPage({
    super.key,
    required this.session,
    required this.provider,
  });

  final PlaybackSession session;
  final AudioProvider provider;

  @override
  ConsumerState<_SpeedWheelPage> createState() => _SpeedWheelPageState();
}

@visibleForTesting
int playbackSpeedWheelIndexAfterDesktopScroll({
  required int currentIndex,
  required double scrollDeltaY,
  required int itemCount,
  bool wheelLocked = false,
}) {
  if (wheelLocked || itemCount <= 0 || scrollDeltaY.abs() < 0.01) {
    return currentIndex;
  }
  final direction = scrollDeltaY > 0 ? 1 : -1;
  return (currentIndex + direction).clamp(0, itemCount - 1).toInt();
}

class _SpeedWheelPageState extends ConsumerState<_SpeedWheelPage> {
  late FixedExtentScrollController _controller;
  late int _selectedIndex;
  double _desktopScrollAccumulator = 0.0;
  int _targetDesktopWheelIndex = -1;

  List<double> get _speeds => PlaybackFacade.playbackSpeedOptions;

  @override
  void initState() {
    super.initState();
    _selectedIndex = _nearestSpeedIndex(widget.session.speed);
    _controller = FixedExtentScrollController(initialItem: _selectedIndex);
  }

  @override
  void didUpdateWidget(covariant _SpeedWheelPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextIndex = _nearestSpeedIndex(widget.session.speed);
    if (oldWidget.session.id != widget.session.id ||
        nextIndex != _selectedIndex) {
      _selectedIndex = nextIndex;
      _controller.dispose();
      _controller = FixedExtentScrollController(initialItem: _selectedIndex);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  int _nearestSpeedIndex(double speed) {
    var bestIndex = 0;
    var bestDistance = double.infinity;
    for (var index = 0; index < _speeds.length; index++) {
      final distance = (_speeds[index] - speed).abs();
      if (distance < bestDistance) {
        bestDistance = distance;
        bestIndex = index;
      }
    }
    return bestIndex;
  }

  void _setSpeedIndex(int index, {required bool persist}) {
    final nextIndex = index.clamp(0, _speeds.length - 1);
    final nextSpeed = _speeds[nextIndex];
    if (_selectedIndex != nextIndex) {
      AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection);
      setState(() => _selectedIndex = nextIndex);
    }
    unawaited(
      widget.provider.playbackFacade.setSessionSpeed(
        widget.session.id,
        nextSpeed,
        persist: persist,
      ),
    );
  }

  void _handleDesktopPointerSignal(PointerSignalEvent event) {
    if (!Platform.isWindows || event is! PointerScrollEvent) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (e) {
      if (e is! PointerScrollEvent) return;
      _desktopScrollAccumulator += e.scrollDelta.dy;
      const threshold = 60.0;
      final steps = (_desktopScrollAccumulator / threshold).truncate();
      if (steps == 0) return;
      _desktopScrollAccumulator -= steps * threshold;

      final baseIndex = _targetDesktopWheelIndex != -1
          ? _targetDesktopWheelIndex
          : _selectedIndex;
      final nextIndex = (baseIndex + steps)
          .clamp(0, _speeds.length - 1)
          .toInt();
      if (nextIndex == baseIndex) {
        _desktopScrollAccumulator = 0.0;
        return;
      }
      _targetDesktopWheelIndex = nextIndex;
      _controller
          .animateToItem(
            nextIndex,
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOutCubic,
          )
          .then((_) {
            if (!mounted) return;
            if (_targetDesktopWheelIndex == nextIndex) {
              _targetDesktopWheelIndex = -1;
            }
          });
    });
  }

  void _resetSpeed() {
    final index = _nearestSpeedIndex(1.0);
    _controller.animateToItem(
      index,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
    );
    _setSpeedIndex(index, persist: true);
  }

  @override
  Widget build(BuildContext context) {
    final detail = ref.watch(sessionDetailTransportProvider(widget.session.id));
    final speed = detail?.speed ?? widget.session.speed;

    final nextIndex = _nearestSpeedIndex(speed);
    if (nextIndex != _selectedIndex) {
      _selectedIndex = nextIndex;
      _controller.dispose();
      _controller = FixedExtentScrollController(initialItem: _selectedIndex);
    }

    final i18n = context.read<AppLanguageProvider>();
    final cs = Theme.of(context).colorScheme;
    final selectedSpeed = _speeds[_selectedIndex];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        Center(
          child: Text(
            _formatSpeedValue(selectedSpeed),
            key: ValueKey<double>(selectedSpeed),
            style: Theme.of(context).textTheme.displaySmall?.copyWith(
              color: cs.onSurface,
              fontWeight: FontWeight.w900,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: Listener(
            onPointerSignal: _handleDesktopPointerSignal,
            child: NotificationListener<ScrollEndNotification>(
              onNotification: (_) {
                _setSpeedIndex(_selectedIndex, persist: true);
                return false;
              },
              child: ListWheelScrollView.useDelegate(
                key: const ValueKey('playback_speed_wheel'),
                controller: _controller,
                itemExtent: 44,
                diameterRatio: 1.35,
                physics: const FixedExtentScrollPhysics(),
                onSelectedItemChanged: (index) {
                  _setSpeedIndex(index, persist: false);
                },
                childDelegate: ListWheelChildBuilderDelegate(
                  childCount: _speeds.length,
                  builder: (context, index) {
                    if (index < 0 || index >= _speeds.length) return null;
                    final speed = _speeds[index];
                    final selected = index == _selectedIndex;
                    return GestureDetector(
                      onTap: () {
                        AppInteractionFeedback.trigger(
                          AppInteractionFeedbackType.selection,
                        );
                        _controller.animateToItem(
                          index,
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeOutCubic,
                        );
                      },
                      child: Center(
                        child: AnimatedDefaultTextStyle(
                          duration: const Duration(milliseconds: 120),
                          curve: Curves.easeOutCubic,
                          style: Theme.of(context).textTheme.titleLarge!
                              .copyWith(
                                color: selected
                                    ? cs.primary
                                    : cs.onSurfaceVariant,
                                fontWeight: selected
                                    ? FontWeight.w900
                                    : FontWeight.w700,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                          child: Text(_formatSpeedValue(speed)),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Center(
          child: FilledButton.tonal(
            key: const ValueKey<String>('restore_playback_speed'),
            style: _sessionDetailResetButtonStyle,
            onPressed: (selectedSpeed - 1.0).abs() < 0.001 ? null : _resetSpeed,
            child: Text(i18n.tr('speed_reset')),
          ),
        ),
      ],
    );
  }
}
