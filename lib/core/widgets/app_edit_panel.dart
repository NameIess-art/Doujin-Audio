import 'package:flutter/material.dart';

import '../../app/theme/app_design_tokens.dart';
import 'app_buttons.dart';
import 'app_dialog.dart';
import 'windows_smooth_scroll_controller.dart';

const double _singleFieldPanelHeight = 192;

Future<T?> showAppEditPanel<T>({
  required BuildContext context,
  required String barrierLabel,
  required WidgetBuilder builder,
}) => showAppOverlayPanel<T>(
  context: context,
  barrierLabel: barrierLabel,
  mobileAlignment: Alignment.center,
  mobileOuterPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
  builder: builder,
);

Future<T?> showAppInputPanel<T>({
  required BuildContext context,
  required String barrierLabel,
  required AppEditPanelHeader header,
  double preferredHeight = _singleFieldPanelHeight,
  Key? surfaceKey,
  required Widget Function(BuildContext context, double height) builder,
}) => showAppEditPanel<T>(
  context: context,
  barrierLabel: barrierLabel,
  builder: (context) => Semantics(
    scopesRoute: true,
    namesRoute: true,
    explicitChildNodes: true,
    label: header.title,
    child: AppEditPanel(
      surfaceKey: surfaceKey,
      editingInput: true,
      preferredInputHeight: preferredHeight,
      builder: (context, _, height) => builder(context, height),
    ),
  ),
);

Future<T?> showAppTextInputPanel<T>({
  required BuildContext context,
  required String barrierLabel,
  required AppEditPanelHeader header,
  required String initialValue,
  required String cancelLabel,
  required String submitLabel,
  required T? Function(String) parse,
  TextInputType? keyboardType,
  InputDecoration decoration = const InputDecoration(),
  Key? inputKey,
  Key? surfaceKey,
}) => showAppInputPanel<T>(
  context: context,
  barrierLabel: barrierLabel,
  header: header,
  surfaceKey: surfaceKey,
  builder: (panelContext, height) => AppEditInput(
    height: height,
    header: header,
    inputKey: inputKey,
    initialValue: initialValue,
    keyboardType: keyboardType,
    decoration: decoration,
    cancelLabel: cancelLabel,
    submitLabel: submitLabel,
    onCancel: () => Navigator.pop(panelContext),
    onSubmit: (text) {
      final result = parse(text);
      if (result != null) Navigator.pop(panelContext, result);
    },
  ),
);

class AppEditPanel extends StatelessWidget {
  const AppEditPanel({
    super.key,
    this.surfaceKey,
    this.preferredInputHeight = _singleFieldPanelHeight,
    required this.editingInput,
    required this.builder,
  });

  final Key? surfaceKey;
  final double preferredInputHeight;
  final bool editingInput;
  final Widget Function(
    BuildContext context,
    double editHeight,
    double inputHeight,
  )
  builder;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(
      AppDesignTokens.of(context).radiusOverlay,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight;
        final keyboardHeight = MediaQuery.viewInsetsOf(context).bottom;
        // Keep the anchor independent of keyboard-driven changes to system bar padding.
        final anchorHeight = (height - MediaQuery.viewPaddingOf(context).bottom)
            .clamp(0.0, height);
        final usableHeight = (height - keyboardHeight).clamp(0.0, anchorHeight);
        final editHeight = anchorHeight.clamp(0.0, 350.0);
        final inputHeight = usableHeight.clamp(0.0, preferredInputHeight);
        final editTop = (anchorHeight - editHeight) / 2;
        final top = editingInput
            ? editTop.clamp(0.0, usableHeight - inputHeight)
            : editTop;

        return Padding(
          padding: EdgeInsets.only(top: top),
          child: Align(
            alignment: Alignment.topCenter,
            child: DecoratedBox(
              key: surfaceKey,
              decoration: BoxDecoration(
                borderRadius: radius,
                boxShadow: [
                  BoxShadow(
                    color: colors.shadow.withValues(alpha: 0.22),
                    blurRadius: 32,
                    offset: const Offset(0, 18),
                  ),
                ],
              ),
              child: Material(
                color: colors.surfaceContainerLow,
                borderRadius: radius,
                clipBehavior: Clip.antiAlias,
                child: builder(context, editHeight, inputHeight),
              ),
            ),
          ),
        );
      },
    );
  }
}

class AppEditPanelHeader extends StatelessWidget {
  const AppEditPanelHeader({
    super.key,
    this.iconKey,
    required this.icon,
    required this.title,
    this.accentColor,
    this.titleColor,
  });

  final Key? iconKey;
  final IconData icon;
  final String title;
  final Color? accentColor;
  final Color? titleColor;

  @override
  Widget build(BuildContext context) {
    final accent = accentColor ?? Theme.of(context).colorScheme.primary;
    return Row(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(
              AppDesignTokens.of(context).radiusSmall,
            ),
          ),
          child: Icon(icon, key: iconKey, color: accent, size: 22),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: titleColor,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ],
    );
  }
}

ButtonStyle appEditPanelActionStyle({Color? foregroundColor}) {
  return appTextButtonStyle(
    style: TextButton.styleFrom(
      shape: const StadiumBorder(),
      foregroundColor: foregroundColor,
      textStyle: const TextStyle(fontWeight: FontWeight.w600),
    ),
  );
}

class AppEditInput extends StatefulWidget {
  const AppEditInput({
    super.key,
    required this.height,
    required this.header,
    this.inputKey,
    required this.initialValue,
    this.keyboardType,
    this.decoration = const InputDecoration(),
    required this.cancelLabel,
    required this.submitLabel,
    required this.onCancel,
    required this.onSubmit,
  });

  final double height;
  final AppEditPanelHeader header;
  final Key? inputKey;
  final String initialValue;
  final TextInputType? keyboardType;
  final InputDecoration decoration;
  final String cancelLabel;
  final String submitLabel;
  final VoidCallback onCancel;
  final ValueChanged<String> onSubmit;

  @override
  State<AppEditInput> createState() => _AppEditInputState();
}

class _AppEditInputState extends State<AppEditInput> {
  late final _controller = TextEditingController(text: widget.initialValue);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppEditPanelForm(
      height: widget.height,
      header: widget.header,
      fields: TextField(
        key: widget.inputKey,
        controller: _controller,
        autofocus: true,
        keyboardType: widget.keyboardType,
        decoration: widget.decoration,
        textInputAction: TextInputAction.done,
        onSubmitted: widget.onSubmit,
      ),
      cancelLabel: widget.cancelLabel,
      submitLabel: widget.submitLabel,
      onCancel: widget.onCancel,
      onSubmit: () => widget.onSubmit(_controller.text),
    );
  }
}

class AppEditPanelForm extends StatelessWidget {
  const AppEditPanelForm({
    super.key,
    required this.height,
    required this.header,
    required this.fields,
    required this.cancelLabel,
    required this.submitLabel,
    required this.onCancel,
    required this.onSubmit,
  });

  final double height;
  final AppEditPanelHeader header;
  final Widget fields;
  final String cancelLabel;
  final String submitLabel;
  final VoidCallback onCancel;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final actionStyle = appEditPanelActionStyle();
    return SizedBox(
      width: double.infinity,
      height: height,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            header,
            const SizedBox(height: 12),
            fields,
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerRight,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton(
                    style: actionStyle,
                    onPressed: onCancel,
                    child: Text(cancelLabel),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    style: actionStyle,
                    onPressed: onSubmit,
                    child: Text(submitLabel),
                  ),
                ],
              ),
            ),
          ],
        ),
      ).withWindowsSmoothScroll(),
    );
  }
}
