import 'package:flutter/material.dart';

import '../../app/theme/app_design_tokens.dart';
import '../../app/theme/app_styles.dart';
import 'app_bottom_sheet.dart';
import 'app_buttons.dart';
import 'app_dialog.dart';
import 'app_transitions.dart';
import 'windows_smooth_scroll_controller.dart';
import 'unified_popup_menu.dart';

const double _singleFieldPanelHeight = 192;

Future<T?> showAppInputPanel<T>({
  required BuildContext context,
  required AppEditPanelHeader header,
  double? preferredHeight = _singleFieldPanelHeight,
  Key? surfaceKey,
  required Widget Function(BuildContext context, double? height) builder,
}) => showAppDialog<T>(
  context: context,
  // The queue name editor uses the root theme in the overlay route.
  captureLocalThemes: false,
  builder: (context) => Semantics(
    scopesRoute: true,
    namesRoute: true,
    explicitChildNodes: true,
    label: header.title,
    child: LayoutBuilder(
      builder: (context, constraints) => AppEditPanelSurface(
        surfaceKey: surfaceKey,
        child: builder(
          context,
          preferredHeight == null
              ? null
              : constraints.constrainHeight(preferredHeight),
        ),
      ),
    ),
  ),
);

Future<T?> showAppTextInputPanel<T>({
  required BuildContext context,
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
    required this.editingInput,
    required this.builder,
  });

  final Key? surfaceKey;
  final bool editingInput;
  final Widget Function(
    BuildContext context,
    double editHeight,
    double inputHeight,
  )
  builder;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight;
        final keyboardHeight = MediaQuery.viewInsetsOf(context).bottom;
        // Keep the anchor independent of keyboard-driven changes to system bar padding.
        final anchorHeight = (height - MediaQuery.viewPaddingOf(context).bottom)
            .clamp(0.0, height);
        final usableHeight = (height - keyboardHeight).clamp(0.0, anchorHeight);
        final editHeight = anchorHeight.clamp(0.0, 350.0);
        final inputHeight = usableHeight.clamp(0.0, _singleFieldPanelHeight);
        final editTop = (anchorHeight - editHeight) / 2;
        final top = editingInput
            ? editTop.clamp(0.0, usableHeight - inputHeight)
            : editTop;

        final reducedMotion =
            MediaQuery.maybeDisableAnimationsOf(context) ?? false;
        return AnimatedPadding(
          duration: reducedMotion ? Duration.zero : kAppMotionFast,
          curve: kAppSpringCurve,
          padding: EdgeInsets.only(top: top),
          child: Align(
            alignment: Alignment.topCenter,
            child: AppEditPanelSurface(
              surfaceKey: surfaceKey,
              child: builder(context, editHeight, inputHeight),
            ),
          ),
        );
      },
    );
  }
}

class AppEditPanelSurface extends StatelessWidget {
  const AppEditPanelSurface({super.key, this.surfaceKey, required this.child});

  final Key? surfaceKey;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final tokens = AppDesignTokens.of(context);
    final radius = BorderRadius.circular(tokens.radiusOverlay);
    return DecoratedBox(
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
        color: appFloatingSurfaceColor(colors),
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(
            color: appOverlayBorderColor(colors, tokens, elevated: true),
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: child,
      ),
    );
  }
}

class AppEditPanelHeader extends StatelessWidget {
  const AppEditPanelHeader({
    super.key,
    this.iconKey,
    this.icon,
    this.iconWidget,
    required this.title,
    this.accentColor,
    this.titleColor,
  }) : assert(icon != null || iconWidget != null);

  final Key? iconKey;
  final IconData? icon;
  final Widget? iconWidget;
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
          child: iconWidget == null
              ? Icon(icon, key: iconKey, color: accent, size: 22)
              : Center(
                  key: iconKey,
                  child: IconTheme.merge(
                    data: IconThemeData(color: accent, size: 22),
                    child: iconWidget!,
                  ),
                ),
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

  final double? height;
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
        contextMenuBuilder: buildAppEditableTextMenu,
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
    this.height,
    required this.header,
    required this.fields,
    required this.cancelLabel,
    required this.submitLabel,
    required this.onCancel,
    required this.onSubmit,
  });

  final double? height;
  final AppEditPanelHeader header;
  final Widget fields;
  final String cancelLabel;
  final String submitLabel;
  final VoidCallback? onCancel;
  final VoidCallback? onSubmit;

  @override
  Widget build(BuildContext context) {
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
            const SizedBox(height: 8),
            AppBottomSheetActions(
              cancelLabel: cancelLabel,
              confirmLabel: submitLabel,
              onCancel: onCancel,
              onConfirm: onSubmit,
            ),
          ],
        ),
      ).withWindowsSmoothScroll(),
    );
  }
}
