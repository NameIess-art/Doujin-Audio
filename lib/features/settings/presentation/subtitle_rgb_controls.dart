import 'package:flutter/material.dart';

class SubtitleRgbControls extends StatelessWidget {
  const SubtitleRgbControls({
    super.key,
    required this.label,
    required this.resetTooltip,
    required this.currentColor,
    required this.defaultColor,
    required this.onChanged,
    required this.onReset,
    required this.cs,
    required this.labelStyle,
  });
  final String label;
  final String resetTooltip;
  final Color? currentColor;
  final Color defaultColor;
  final ValueChanged<Color> onChanged;
  final VoidCallback onReset;
  final ColorScheme cs;
  final TextStyle? labelStyle;
  @override
  Widget build(BuildContext context) {
    final int r = ((currentColor?.r ?? defaultColor.r) * 255).round();
    final int g = ((currentColor?.g ?? defaultColor.g) * 255).round();
    final int b = ((currentColor?.b ?? defaultColor.b) * 255).round();
    final int a = ((currentColor?.a ?? defaultColor.a) * 255).round();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text(label, style: labelStyle)),
            Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: Color.fromARGB(a, r, g, b),
                shape: BoxShape.circle,
                border: Border.all(color: cs.outlineVariant),
              ),
            ),
            if (currentColor != null)
              IconButton(
                icon: Icon(
                  Icons.close_rounded,
                  size: 18,
                  color: cs.onSurfaceVariant,
                ),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                onPressed: onReset,
                tooltip: resetTooltip,
              ),
          ],
        ),
        const SizedBox(height: 4),
        _RgbSliderRow(
          label: 'R',
          value: r,
          cs: cs,
          onChanged: (v) {
            onChanged(Color.fromARGB(a, v.round(), g, b));
          },
        ),
        _RgbSliderRow(
          label: 'G',
          value: g,
          cs: cs,
          onChanged: (v) {
            onChanged(Color.fromARGB(a, r, v.round(), b));
          },
        ),
        _RgbSliderRow(
          label: 'B',
          value: b,
          cs: cs,
          onChanged: (v) {
            onChanged(Color.fromARGB(a, r, g, v.round()));
          },
        ),
      ],
    );
  }
}

class _RgbSliderRow extends StatefulWidget {
  const _RgbSliderRow({
    required this.label,
    required this.value,
    required this.cs,
    required this.onChanged,
  });

  final String label;
  final int value;
  final ColorScheme cs;
  final ValueChanged<double> onChanged;

  @override
  State<_RgbSliderRow> createState() => _RgbSliderRowState();
}

class _RgbSliderRowState extends State<_RgbSliderRow> {
  late final TextEditingController _controller;
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value.toString());
  }

  @override
  void didUpdateWidget(covariant _RgbSliderRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_editing && widget.value != oldWidget.value) {
      _controller.text = widget.value.toString();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    _editing = false;
    final parsed = int.tryParse(_controller.text);
    if (parsed != null) {
      widget.onChanged(parsed.clamp(0, 255).toDouble());
    } else {
      _controller.text = widget.value.toString();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 20,
          child: Text(
            widget.label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: widget.cs.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: Slider(
            value: widget.value.toDouble(),
            max: 255,
            divisions: 255,
            onChanged: widget.onChanged,
          ),
        ),
        SizedBox(
          width: 36,
          child: TextField(
            controller: _controller,
            keyboardType: TextInputType.number,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: widget.cs.onSurface),
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 2,
                vertical: 4,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: BorderSide(
                  color: widget.cs.outlineVariant.withValues(alpha: 0.5),
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: BorderSide(color: widget.cs.primary, width: 1.5),
              ),
            ),
            onTap: () => _editing = true,
            onSubmitted: (_) => _submit(),
            onEditingComplete: _submit,
            onTapOutside: (_) => _submit(),
          ),
        ),
      ],
    );
  }
}
