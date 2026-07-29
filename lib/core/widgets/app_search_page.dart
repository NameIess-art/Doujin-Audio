import 'package:flutter/material.dart';

import '../../app/theme/app_design_tokens.dart';

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
  final Widget body;
  final Color? accentColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final tokens = AppDesignTokens.of(context);
    final accent = accentColor ?? cs.primary;
    return Scaffold(
      backgroundColor: cs.surface,
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
              child: SizedBox(
                key: const ValueKey<String>('app_search_field_shell'),
                height: 44,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(
                      color: cs.outlineVariant.withValues(alpha: 0.28),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: cs.shadow.withValues(alpha: 0.08),
                        blurRadius: 10,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
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
                      onChanged: onChanged,
                      onSubmitted: onSubmitted,
                      style: theme.textTheme.bodyMedium?.copyWith(fontSize: 15),
                      decoration: InputDecoration(
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
                        contentPadding: const EdgeInsets.symmetric(
                          vertical: 12,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
              child: Container(
                key: const ValueKey<String>('app_search_category_shell'),
                height: 40,
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: cs.outlineVariant.withValues(alpha: 0.24),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: cs.shadow.withValues(alpha: 0.06),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(20),
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
                            padding: const EdgeInsets.symmetric(horizontal: 14),
                            decoration: BoxDecoration(
                              color: selected
                                  ? accent.withValues(alpha: 0.17)
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Text(
                              category.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelLarge?.copyWith(
                                color: selected ? accent : cs.onSurfaceVariant,
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
            ),
            Expanded(child: body),
          ],
        ),
      ),
    );
  }
}
