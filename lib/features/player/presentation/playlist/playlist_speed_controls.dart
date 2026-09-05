import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/presentation/app_presentation_providers.dart';
import '../../../../app/state/app_runtime_providers.dart';
import '../../../../core/widgets/app_feedback.dart';
import '../../application/playback_facade.dart';
import '../../application/playback_session_snapshot.dart';
import 'playlist_shared_helpers.dart';

class SpeedWheelPage extends ConsumerStatefulWidget {
  const SpeedWheelPage({
    super.key,
    required this.session,
    required this.playback,
  });

  final PlaybackSessionSnapshot session;
  final PlaybackFacade playback;

  @override
  ConsumerState<SpeedWheelPage> createState() => _SpeedWheelPageState();
}

class _SpeedWheelPageState extends ConsumerState<SpeedWheelPage> {
  late FixedExtentScrollController _controller;
  late int _selectedIndex;

  List<double> get _speeds => PlaybackFacade.playbackSpeedOptions;

  @override
  void initState() {
    super.initState();
    _selectedIndex = _nearestSpeedIndex(widget.session.speed);
    _controller = FixedExtentScrollController(initialItem: _selectedIndex);
  }

  @override
  void didUpdateWidget(covariant SpeedWheelPage oldWidget) {
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
      widget.playback.setSessionSpeed(
        widget.session.id,
        nextSpeed,
        persist: persist,
      ),
    );
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

    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final cs = Theme.of(context).colorScheme;
    final selectedSpeed = _speeds[_selectedIndex];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        Center(
          child: Text(
            formatSpeedValue(selectedSpeed),
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
          child: NotificationListener<ScrollEndNotification>(
            onNotification: (_) {
              _setSpeedIndex(_selectedIndex, persist: true);
              return false;
            },
            child: ListWheelScrollView.useDelegate(
              key: const ValueKey('playback_speed_wheel'),
              controller: _controller,
              itemExtent: 52,
              diameterRatio: 1.5,
              useMagnifier: true,
              magnification: 1.08,
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
                        duration: const Duration(milliseconds: 140),
                        curve: Curves.easeOutCubic,
                        style: selected
                            ? Theme.of(context).textTheme.headlineMedium!.copyWith(
                                color: cs.primary,
                                fontWeight: FontWeight.w900,
                                fontSize: 28,
                                letterSpacing: -0.5,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              )
                            : Theme.of(context).textTheme.titleMedium!.copyWith(
                                color: cs.onSurfaceVariant.withValues(
                                  alpha: 0.45,
                                ),
                                fontWeight: FontWeight.w600,
                                fontSize: 17,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                        child: Text(formatSpeedValue(speed)),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Center(
          child: FilledButton.tonal(
            key: const ValueKey<String>('restore_playback_speed'),
            style: sessionDetailResetButtonStyle(context),
            onPressed: (selectedSpeed - 1.0).abs() < 0.001 ? null : _resetSpeed,
            child: Text(i18n.tr('speed_reset')),
          ),
        ),
      ],
    );
  }
}
