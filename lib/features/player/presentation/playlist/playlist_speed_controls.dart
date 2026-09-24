import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
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
  int? _wheelTargetIndex;
  bool _isAdjusting = false;
  int _adjustmentGeneration = 0;
  int _committedGeneration = -1;

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
    if (oldWidget.session.id != widget.session.id ||
        (oldWidget.session.speed != widget.session.speed && !_isAdjusting)) {
      _isAdjusting = false;
      _adjustmentGeneration++;
      final nextIndex = _nearestSpeedIndex(
        widget.playback.sessionById(widget.session.id)?.speed ??
            widget.session.speed,
      );
      if (nextIndex != _selectedIndex) {
        _selectedIndex = nextIndex;
        _wheelTargetIndex = null;
        _controller.dispose();
        _controller = FixedExtentScrollController(initialItem: _selectedIndex);
      }
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

  void _setSpeedIndex(int index) {
    final nextIndex = index.clamp(0, _speeds.length - 1);
    _isAdjusting = true;
    _adjustmentGeneration++;
    if (_selectedIndex != nextIndex) {
      AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection);
      setState(() => _selectedIndex = nextIndex);
    }
  }

  Future<void> _commitSpeed() async {
    final generation = _adjustmentGeneration;
    final sessionId = widget.session.id;
    final selectedSpeed = _speeds[_selectedIndex];
    await widget.playback.setSessionSpeed(sessionId, selectedSpeed);
    if (!mounted ||
        widget.session.id != sessionId ||
        generation != _adjustmentGeneration) {
      return;
    }
    setState(() => _isAdjusting = false);
  }

  void _finishAdjustment() {
    if (!_isAdjusting || _committedGeneration == _adjustmentGeneration) return;
    _committedGeneration = _adjustmentGeneration;
    _wheelTargetIndex = null;
    unawaited(_commitSpeed());
  }

  void _resetSpeed() {
    final index = _nearestSpeedIndex(1.0);
    _setSpeedIndex(index);
    _controller.animateToItem(
      index,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final speed =
        ref.watch(
          sessionDetailTransportProvider(
            widget.session.id,
          ).select((state) => state?.speed),
        ) ??
        widget.session.speed;

    if (!_isAdjusting) {
      final nextIndex = _nearestSpeedIndex(
        widget.playback.sessionById(widget.session.id)?.speed ?? speed,
      );
      if (nextIndex != _selectedIndex) {
        _selectedIndex = nextIndex;
        _controller.dispose();
        _controller = FixedExtentScrollController(initialItem: _selectedIndex);
      }
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
          child: Stack(
            children: [
              NotificationListener<ScrollNotification>(
                onNotification: (notification) {
                  if (notification is ScrollStartNotification) {
                    _isAdjusting = true;
                    _adjustmentGeneration++;
                  } else if (notification is ScrollEndNotification) {
                    _finishAdjustment();
                  }
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
                    _setSpeedIndex(index);
                  },
                  childDelegate: ListWheelChildBuilderDelegate(
                    childCount: _speeds.length,
                    builder: (context, index) {
                      if (index < 0 || index >= _speeds.length) return null;
                      final speed = _speeds[index];
                      final selected = index == _selectedIndex;
                      return InkWell(
                        onTap: () {
                          _wheelTargetIndex = null;
                          _isAdjusting = true;
                          _adjustmentGeneration++;
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
              if (defaultTargetPlatform == TargetPlatform.windows)
                Positioned.fill(
                  child: Listener(
                    behavior: HitTestBehavior.translucent,
                    onPointerSignal: (signal) {
                      if (signal is PointerScrollEvent) {
                        GestureBinding.instance.pointerSignalResolver.register(
                          signal,
                          (event) {
                            final scrollEvent = event as PointerScrollEvent;
                            if (scrollEvent.scrollDelta.dy == 0) return;
                            final delta = scrollEvent.scrollDelta.dy > 0
                                ? 1
                                : -1;
                            final baseIndex =
                                _wheelTargetIndex ?? _selectedIndex;
                            final nextIndex = (baseIndex + delta).clamp(
                              0,
                              _speeds.length - 1,
                            );
                            if (nextIndex != _selectedIndex ||
                                _wheelTargetIndex != nextIndex) {
                              _wheelTargetIndex = nextIndex;
                              AppInteractionFeedback.trigger(
                                AppInteractionFeedbackType.selection,
                              );
                              _setSpeedIndex(nextIndex);
                              _controller.animateToItem(
                                nextIndex,
                                duration: const Duration(milliseconds: 150),
                                curve: Curves.easeOutCubic,
                              );
                            }
                          },
                        );
                      }
                    },
                  ),
                ),
            ],
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
