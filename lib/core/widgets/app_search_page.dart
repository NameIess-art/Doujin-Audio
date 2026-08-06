import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../app/theme/app_design_tokens.dart';
import 'app_edge_fade_mask.dart';
import 'app_transitions.dart';

PageRouteBuilder<T> buildAppSearchPageRoute<T>({
  required BuildContext context,
  required Widget child,
}) {
  return buildAppPageRoute<T>(
    context: context,
    style: AppPageTransitionStyle.fadeThrough,
    child: child,
  );
}

@immutable
class AppSearchCategory<T> {
  const AppSearchCategory({required this.value, required this.label});

  final T value;
  final String label;
}

class AppSearchPageScaffold<T> extends StatelessWidget {
  const AppSearchPageScaffold({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.hintText,
    required this.categories,
    required this.selectedCategory,
    required this.onCategorySelected,
    required this.onChanged,
    required this.onSubmitted,
    required this.onCloseOrClear,
    required this.blurEnabled,
    required this.body,
    this.accentColor,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String hintText;
  final List<AppSearchCategory<T>> categories;
  final T selectedCategory;
  final ValueChanged<T> onCategorySelected;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;
  final VoidCallback onCloseOrClear;
  final bool blurEnabled;
  final Widget body;
  final Color? accentColor;

  static double controlsTopInset(BuildContext context) =>
      MediaQuery.paddingOf(context).top + 106;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final tokens = AppDesignTokens.of(context);
    final accent = accentColor ?? cs.primary;
    final content = Scaffold(
      backgroundColor: cs.surface,
      resizeToAvoidBottomInset: false,
      body: Stack(
        key: const ValueKey<String>('app_search_stack'),
        fit: StackFit.expand,
        children: [
          KeyedSubtree(
            key: const ValueKey<String>('app_search_body_layer'),
            child: body,
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: MediaQuery.paddingOf(context).top + 98,
            child: const AppEdgeFadeMask(
              key: ValueKey<String>('app_search_top_fade_mask'),
              direction: AppEdgeFadeDirection.towardTop,
            ),
          ),
          Positioned(
            key: const ValueKey<String>('app_search_controls_overlay'),
            top: MediaQuery.paddingOf(context).top + 8,
            left: 10,
            right: 10,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  key: const ValueKey<String>('app_search_field_shell'),
                  height: 44,
                  child: _SearchFloatingCapsule(
                    radius: 22,
                    blurEnabled: blurEnabled,
                    child: TextSelectionTheme(
                      data: TextSelectionThemeData(
                        cursorColor: accent,
                        selectionColor: accent.withValues(alpha: 0.24),
                        selectionHandleColor: accent,
                      ),
                      child: TextField(
                        key: const ValueKey<String>('app_search_field'),
                        controller: controller,
                        focusNode: focusNode,
                        autofocus: true,
                        cursorColor: accent,
                        textInputAction: TextInputAction.search,
                        textAlignVertical: TextAlignVertical.center,
                        onChanged: onChanged,
                        onSubmitted: onSubmitted,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontSize: 15,
                        ),
                        decoration: InputDecoration(
                          filled: false,
                          fillColor: Colors.transparent,
                          prefixIcon: Icon(
                            Icons.search_rounded,
                            color: cs.onSurfaceVariant,
                            size: 21,
                          ),
                          prefixIconConstraints: const BoxConstraints.tightFor(
                            width: 42,
                            height: 44,
                          ),
                          suffixIcon: IconButton(
                            key: const ValueKey<String>('app_search_close'),
                            onPressed: onCloseOrClear,
                            icon: const Icon(Icons.close_rounded, size: 21),
                            color: cs.onSurfaceVariant,
                            padding: EdgeInsets.zero,
                            visualDensity: VisualDensity.compact,
                          ),
                          suffixIconConstraints: const BoxConstraints.tightFor(
                            width: 42,
                            height: 44,
                          ),
                          hintText: hintText,
                          hintStyle: theme.textTheme.bodyMedium?.copyWith(
                            color: cs.onSurfaceVariant,
                            fontSize: 15,
                          ),
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          isDense: true,
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                SizedBox(
                  key: const ValueKey<String>('app_search_category_shell'),
                  height: 40,
                  child: _SearchFloatingCapsule(
                    radius: 20,
                    blurEnabled: blurEnabled,
                    child: ListView.separated(
                      key: const ValueKey<String>('app_search_categories'),
                      padding: const EdgeInsets.all(4),
                      scrollDirection: Axis.horizontal,
                      physics: const BouncingScrollPhysics(),
                      itemCount: categories.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 2),
                      itemBuilder: (context, index) {
                        final category = categories[index];
                        final selected = category.value == selectedCategory;
                        return Semantics(
                          button: true,
                          selected: selected,
                          child: InkWell(
                            key: ValueKey<String>(
                              'app_search_category_${category.value}',
                            ),
                            borderRadius: BorderRadius.circular(16),
                            onTap: () => onCategorySelected(category.value),
                            child: AnimatedContainer(
                              duration: tokens.motionFast,
                              alignment: Alignment.center,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                              ),
                              decoration: BoxDecoration(
                                color: selected
                                    ? accent.withValues(alpha: 0.19)
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: Text(
                                category.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.labelLarge?.copyWith(
                                  color: selected
                                      ? accent
                                      : cs.onSurfaceVariant,
                                  fontWeight: selected
                                      ? FontWeight.w700
                                      : FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    return MediaQuery.removeViewInsets(
      key: const ValueKey<String>('app_search_keyboard_inset_boundary'),
      context: context,
      removeBottom: true,
      child: content,
    );
  }
}

class _SearchFloatingCapsule extends StatelessWidget {
  const _SearchFloatingCapsule({
    required this.radius,
    required this.blurEnabled,
    required this.child,
  });

  final double radius;
  final bool blurEnabled;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final background = isDark ? cs.surfaceBright : cs.surfaceContainerHigh;
    final borderRadius = BorderRadius.circular(radius);
    final capsuleSurface = DecoratedBox(
      decoration: BoxDecoration(
        color: background.withValues(
          alpha: blurEnabled ? (isDark ? 0.80 : 0.86) : 1,
        ),
        borderRadius: borderRadius,
        border: Border.all(
          color: cs.outlineVariant.withValues(alpha: isDark ? 0.24 : 0.42),
        ),
      ),
      child: child,
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: [
          BoxShadow(
            color: cs.shadow.withValues(alpha: 0.14),
            blurRadius: 18,
            spreadRadius: -5,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: borderRadius,
        child: blurEnabled
            ? BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                child: capsuleSurface,
              )
            : capsuleSurface,
      ),
    );
  }
}
