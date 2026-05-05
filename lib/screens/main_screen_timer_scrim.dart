part of 'main_screen.dart';

class _ImmediateTimerScrim extends StatelessWidget {
  const _ImmediateTimerScrim();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Positioned.fill(
      child: IgnorePointer(
        child: ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: cs.scrim.withValues(alpha: 0.12),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
