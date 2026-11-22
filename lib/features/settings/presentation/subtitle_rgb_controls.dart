import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../core/widgets/unified_popup_menu.dart';

class SubtitleRgbControls extends StatelessWidget {
  const SubtitleRgbControls({
    super.key,
    required this.label,
    required this.resetTooltip,
    required this.currentColor,
    required this.defaultColor,
    required this.onChanged,
    required this.onChangeStart,
    required this.onChangeEnd,
    required this.onReset,
    required this.cs,
    required this.labelStyle,
  });
  final String label;
  final String resetTooltip;
  final Color? currentColor;
  final Color defaultColor;
  final ValueChanged<Color> onChanged;
  final VoidCallback onChangeStart;
  final VoidCallback onChangeEnd;
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
                color: cs.onSurfaceVariant,
                icon: const Icon(Icons.restart_alt_rounded, size: 18),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                onPressed: onReset,
                tooltip: resetTooltip,
              ),
          ],
        ),
        const SizedBox(height: 4),
        _RgbSliderRow(
          label: 'R',
          onChangeStart: onChangeStart,
          onChangeEnd: onChangeEnd,
          value: r,
          cs: cs,
          onChanged: (v) {
            onChanged(Color.fromARGB(a, v.round(), g, b));
          },
        ),
        _RgbSliderRow(
          label: 'G',
          onChangeStart: onChangeStart,
          onChangeEnd: onChangeEnd,
          value: g,
          cs: cs,
          onChanged: (v) {
            onChanged(Color.fromARGB(a, r, v.round(), b));
          },
        ),
        _RgbSliderRow(
          label: 'B',
          onChangeStart: onChangeStart,
          onChangeEnd: onChangeEnd,
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
    required this.onChangeStart,
    required this.onChangeEnd,
  });

  final String label;
  final int value;
  final ColorScheme cs;
  final ValueChanged<double> onChanged;
  final VoidCallback onChangeStart;
  final VoidCallback onChangeEnd;

  @override
  State<_RgbSliderRow> createState() => _RgbSliderRowState();
}

class _RgbSliderRowState extends State<_RgbSliderRow> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value.toString());
    _focusNode = FocusNode()..addListener(_handleFocusChange);
  }

  @override
  void didUpdateWidget(covariant _RgbSliderRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_editing && widget.value != oldWidget.value) {
      _syncControllerText(widget.value.toString());
    }
  }

  @override
  void dispose() {
    _focusNode.removeListener(_handleFocusChange);
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _syncControllerText(String nextText) {
    if (_controller.text == nextText) return;
    _controller.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: nextText.length),
    );
  }

  void _handleFocusChange() {
    if (_focusNode.hasFocus) {
      _editing = true;
    } else {
      _submit();
    }
  }

  void _submit() {
    if (!_editing) return;
    _editing = false;
    final parsed = int.tryParse(_controller.text.trim());
    if (parsed != null) {
      final clamped = parsed.clamp(0, 255);
      _syncControllerText(clamped.toString());
      if (clamped != widget.value) {
        widget.onChanged(clamped.toDouble());
      }
    } else {
      _syncControllerText(widget.value.toString());
    }
  }

  void _handleTextChanged(String text) {
    _editing = true;
    final parsed = int.tryParse(text.trim());
    if (parsed != null && parsed >= 0 && parsed <= 255 && parsed != widget.value) {
      widget.onChanged(parsed.toDouble());
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
            onChangeStart: (_) => widget.onChangeStart(),
            onChanged: widget.onChanged,
            onChangeEnd: (_) => widget.onChangeEnd(),
          ),
        ),
        SizedBox(
          width: 46,
          child: TextField(
            contextMenuBuilder: buildAppEditableTextMenu,
            controller: _controller,
            focusNode: _focusNode,
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(3),
            ],
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: widget.cs.onSurface),
            decoration: const InputDecoration(
              isDense: true,
              // Keep these inline values compact beside the sliders.
              constraints: BoxConstraints(),
              contentPadding: EdgeInsets.symmetric(
                horizontal: 2,
                vertical: 4,
              ),
            ),
            onChanged: _handleTextChanged,
            onSubmitted: (_) => _submit(),
            onEditingComplete: _submit,
            onTapOutside: (_) => _submit(),
          ),
        ),
      ],
    );
  }
}
