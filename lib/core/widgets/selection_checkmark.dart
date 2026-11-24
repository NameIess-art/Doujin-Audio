import 'package:flutter/material.dart';

import '../../app/theme/app_design_tokens.dart';
import 'app_transitions.dart';

class SelectionCheckmark extends StatefulWidget {
  const SelectionCheckmark({
    super.key,
    required this.indicatorKey,
    required this.isSelected,
    this.showUnselectedOutline = false,
  });

  final Key indicatorKey;
  final bool isSelected;
  final bool showUnselectedOutline;

  @override
  State<SelectionCheckmark> createState() => _SelectionCheckmarkState();
}

class _SelectionCheckmarkState extends State<SelectionCheckmark>
    with SingleTickerProviderStateMixin {
  AnimationController? _strokeController;
  Animation<double>? _strokeProgress;

  AnimationController _ensureStrokeController() {
    final existing = _strokeController;
    if (existing != null) return existing;
    final controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
      value: widget.isSelected ? 1.0 : 0.0,
    );
    _strokeController = controller;
    _strokeProgress = CurvedAnimation(
      parent: controller,
      curve: const Interval(0.18, 1.0, curve: Curves.easeOutCubic),
    );
    return controller;
  }

  @override
  void didUpdateWidget(covariant SelectionCheckmark oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isSelected == widget.isSelected) return;
    final reducedMotion =
        MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final tickerEnabled = TickerMode.valuesOf(context).enabled;
    final controller = _ensureStrokeController();
    if (reducedMotion || !tickerEnabled) {
      controller.value = widget.isSelected ? 1.0 : 0.0;
    } else if (widget.isSelected) {
      controller.forward(from: 0.0);
    } else {
      controller.value = 0.0;
    }
  }

  @override
  void dispose() {
    _strokeController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = AppDesignTokens.of(context);
    final cs = Theme.of(context).colorScheme;
    final stroke = _strokeProgress;
    final badge = Container(
      key: widget.indicatorKey,
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: tokens.success,
        border: Border.all(color: cs.surface, width: 2),
      ),
      child: stroke == null
          ? CustomPaint(
              painter: _CheckmarkStrokePainter(
                color: tokens.onSuccess,
                progress: kAlwaysCompleteAnimation,
              ),
            )
          : CustomPaint(
              painter: _CheckmarkStrokePainter(
                color: tokens.onSuccess,
                progress: stroke,
              ),
            ),
    );
    final animatedCheck = AppDeferredFade(
      visible: widget.isSelected,
      beginScale: 0.72,
      fadeInDuration: kAppMotionFast,
      fadeOutDuration: const Duration(milliseconds: 160),
      scaleCurve: kAppSpringBackCurve,
      child: badge,
    );
    return IgnorePointer(
      child: ExcludeSemantics(
        child: !widget.showUnselectedOutline
            ? animatedCheck
            : Stack(
                alignment: Alignment.center,
                children: [
                  Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.black.withValues(alpha: 0.22),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.85),
                        width: 1.6,
                      ),
                    ),
                  ),
                  animatedCheck,
                ],
              ),
      ),
    );
  }
}

class _CheckmarkStrokePainter extends CustomPainter {
  _CheckmarkStrokePainter({required this.color, required this.progress})
    : super(repaint: progress);

  final Color color;
  final Animation<double> progress;

  @override
  void paint(Canvas canvas, Size size) {
    final t = progress.value.clamp(0.0, 1.0);
    if (t <= 0.0) return;
    final w = size.width;
    final h = size.height;
    final start = Offset(w * 0.27, h * 0.52);
    final mid = Offset(w * 0.44, h * 0.69);
    final end = Offset(w * 0.75, h * 0.34);

    final leg1 = (mid - start).distance;
    final leg2 = (end - mid).distance;
    final total = leg1 + leg2;
    final drawn = total * t;

    final path = Path()..moveTo(start.dx, start.dy);
    if (drawn <= leg1) {
      final p = Offset.lerp(start, mid, drawn / leg1)!;
      path.lineTo(p.dx, p.dy);
    } else {
      path.lineTo(mid.dx, mid.dy);
      final p = Offset.lerp(mid, end, ((drawn - leg1) / leg2).clamp(0.0, 1.0))!;
      path.lineTo(p.dx, p.dy);
    }

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _CheckmarkStrokePainter oldDelegate) {
    return oldDelegate.color != color || oldDelegate.progress != progress;
  }
}
