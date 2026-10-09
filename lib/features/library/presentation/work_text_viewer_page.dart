import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfx/pdfx.dart';

import '../../../app/localization/app_language_provider.dart';
import '../../../app/state/app_runtime_providers.dart';
import '../../../app/theme/app_design_tokens.dart';
import '../../../app/theme/app_styles.dart';
import '../../../core/ui/ui_interaction_coordinator.dart';
import '../../../core/widgets/page_header_inset.dart';
import '../../../core/widgets/app_transitions.dart';
import '../../../core/widgets/top_page_header.dart';
import '../application/work_text_service.dart';
import 'library_providers.dart';
import '../../../core/widgets/page_translation_scope.dart';
import 'translated_markdown_body.dart';

class WorkTextViewerPage extends ConsumerStatefulWidget {
  const WorkTextViewerPage({
    super.key,
    required this.files,
    this.initialIndex = 0,
  });

  final List<WorkTextFile> files;
  final int initialIndex;

  @override
  ConsumerState<WorkTextViewerPage> createState() => _WorkTextViewerPageState();
}

class _WorkTextViewerPageState extends ConsumerState<WorkTextViewerPage> {
  late int _currentIndex;
  final ScrollController _scrollController = ScrollController();

  bool _loading = true;
  PreparedWorkText? _document;
  PdfController? _pdfController;
  bool _loadFailed = false;
  int _loadGeneration = 0;
  bool _loadPending = false;
  late final _loadKey = 'work_text_load_${identityHashCode(this)}';
  late final _resultKey = 'work_text_result_${identityHashCode(this)}';

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex.clamp(
      0,
      widget.files.isEmpty ? 0 : widget.files.length - 1,
    );
    _loadFile();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loadPending) _scheduleFileRead();
  }

  @override
  void dispose() {
    _loadGeneration++;
    UiInteractionCoordinator.instance.cancelCommit(_loadKey);
    UiInteractionCoordinator.instance.cancelCommit(_resultKey);
    _disposePdfController();
    _scrollController.dispose();
    super.dispose();
  }

  void _disposePdfController() {
    _pdfController?.dispose();
    _pdfController = null;
  }

  WorkTextFile? get _currentFile =>
      widget.files.isNotEmpty ? widget.files[_currentIndex] : null;

  void _loadFile() {
    _loadGeneration++;
    UiInteractionCoordinator.instance.cancelCommit(_loadKey);
    UiInteractionCoordinator.instance.cancelCommit(_resultKey);
    _disposePdfController();
    final file = _currentFile;
    if (file == null) {
      setState(() {
        _loading = false;
        _document = null;
        _loadFailed = false;
      });
      _loadPending = false;
      return;
    }

    setState(() {
      _loading = true;
      _loadFailed = false;
      _document = null;
    });
    _loadPending = true;
    _scheduleFileRead();
  }

  void _scheduleFileRead() {
    final gen = _loadGeneration;
    UiInteractionCoordinator.instance.scheduleCommit(
      key: _loadKey,
      commit: () {
        if (!mounted ||
            gen != _loadGeneration ||
            !_loadPending ||
            ModalRoute.of(context)?.isCurrent == false) {
          return;
        }
        _loadPending = false;
        unawaited(_readFile(_currentFile!, gen));
      },
    );
  }

  Future<void> _readFile(WorkTextFile file, int gen) async {
    try {
      final service = ref.read(workTextServiceProvider);
      final bytes = file.isPdf ? await service.readDocumentBytes(file) : null;
      final document = file.isPdf
          ? null
          : await service.readPreparedDocument(file);
      _publishFileResult(gen, () {
        if (file.isPdf) {
          if (bytes == null || bytes.isEmpty) {
            setState(() {
              _loading = false;
              _loadFailed = true;
            });
            return;
          }
          final controller = PdfController(
            document: PdfDocument.openData(bytes),
          );
          setState(() {
            _loading = false;
            _pdfController = controller;
          });
        } else {
          setState(() {
            _loading = false;
            _document = document;
          });
        }
      });
    } catch (_) {
      _publishFileResult(gen, () {
        setState(() {
          _loading = false;
          _loadFailed = true;
        });
      });
    }
  }

  void _publishFileResult(int gen, VoidCallback publish) {
    if (!mounted || gen != _loadGeneration) return;
    UiInteractionCoordinator.instance.scheduleCommit(
      key: _resultKey,
      commit: () {
        if (!mounted || gen != _loadGeneration) return;
        try {
          publish();
        } catch (_) {
          setState(() {
            _loading = false;
            _loadFailed = true;
          });
        }
      },
    );
  }

  void _onSwitchFile(int newIndex) {
    if (widget.files.length < 2) return;
    final wrappedIndex = newIndex % widget.files.length;
    if (wrappedIndex == _currentIndex) return;
    setState(() {
      _currentIndex = wrappedIndex;
    });
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }
    _loadFile();
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ref.watch(appLanguageProviderInstanceProvider);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final file = _currentFile;
    final hasMultipleFiles = widget.files.length > 1;
    final canTranslate =
        !_loading &&
        !_loadFailed &&
        file != null &&
        !file.isPdf &&
        _document?.isEmpty == false;

    final bottomPadding = MediaQuery.paddingOf(context).bottom;
    final contentTopInset = AppPageHeaderMetrics.contentTopInset(context);

    final page = Scaffold(
      backgroundColor: cs.surface,
      body: PageHeaderInset(
        topInset: contentTopInset,
        child: Stack(
          children: [
            Positioned.fill(
              child: AppPageContentTransition(
                child: _buildContent(
                  context,
                  theme,
                  cs,
                  contentTopInset,
                  bottomPadding,
                ),
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: TopPageHeader(
                key: const ValueKey<String>('work_text_header'),
                icon: AppDesignTokens.textFileIcon,
                iconColor: AppDesignTokens.textFileIconColor,
                title: file?.displayName ?? i18n.tr('script_text_viewer_title'),
                trailing: file != null && !file.isPdf
                    ? WorkPageTranslationButton(
                        buttonKey: 'work_text_translation',
                        enabled: canTranslate,
                      )
                    : null,
                leading: IconButton(
                  icon: const Icon(Icons.arrow_back_rounded),
                  tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
            ),
            if (hasMultipleFiles)
              Positioned(
                right: 16,
                bottom: bottomPadding + 20,
                child: AppPageContentTransition(
                  child: _buildBottomRightSwitcher(context, theme, cs, i18n),
                ),
              ),
          ],
        ),
      ),
    );
    return WorkPageTranslationHost(key: ValueKey(_loadGeneration), child: page);
  }

  Widget _buildContent(
    BuildContext context,
    ThemeData theme,
    ColorScheme cs,
    double contentTopInset,
    double bottomPadding,
  ) {
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    if (_loading) {
      return const Center(child: CircularProgressIndicator.adaptive());
    }

    if (_loadFailed) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline_rounded, size: 48, color: cs.error),
              const SizedBox(height: 12),
              Text(
                i18n.tr('text_file_load_failed'),
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.tonal(
                onPressed: _loadFile,
                child: Text(i18n.tr('retry')),
              ),
            ],
          ),
        ),
      );
    }

    final file = _currentFile;
    if (file == null) {
      return Center(
        child: Text(
          i18n.tr('empty_file'),
          style: theme.textTheme.bodyMedium?.copyWith(
            color: cs.onSurfaceVariant.withValues(alpha: 0.7),
          ),
        ),
      );
    }

    if (file.isPdf) {
      return _buildPdfContent(
        context,
        theme,
        cs,
        contentTopInset,
        bottomPadding,
      );
    }

    if (_document?.isEmpty != false) {
      return Center(
        child: Text(
          i18n.tr('empty_file'),
          style: theme.textTheme.bodyMedium?.copyWith(
            color: cs.onSurfaceVariant.withValues(alpha: 0.7),
          ),
        ),
      );
    }

    return _buildDocumentContent(
      context,
      theme,
      cs,
      contentTopInset,
      bottomPadding,
    );
  }

  Widget _buildFadeInContent({
    required BuildContext context,
    required Widget child,
  }) {
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    return TweenAnimationBuilder<double>(
      key: ValueKey<int>(_loadGeneration),
      tween: Tween<double>(begin: disableAnimations ? 1.0 : 0.0, end: 1.0),
      duration: disableAnimations
          ? Duration.zero
          : kPlaceholderContentTransitionDuration,
      curve: Curves.easeOutCubic,
      builder: (context, opacity, child) {
        return Opacity(opacity: opacity, child: child);
      },
      child: child,
    );
  }

  Widget _buildPdfContent(
    BuildContext context,
    ThemeData theme,
    ColorScheme cs,
    double contentTopInset,
    double bottomPadding,
  ) {
    final controller = _pdfController;
    if (controller == null) {
      return const Center(child: CircularProgressIndicator.adaptive());
    }

    return Stack(
      children: [
        Positioned.fill(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              16,
              contentTopInset,
              16,
              bottomPadding + 76,
            ),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 960),
                child: _buildFadeInContent(
                  context: context,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: PdfView(
                      controller: controller,
                      scrollDirection: Axis.vertical,
                      pageSnapping: false,
                      builders: PdfViewBuilders<DefaultBuilderOptions>(
                        options: const DefaultBuilderOptions(),
                        documentLoaderBuilder: (_) => const Center(
                          child: CircularProgressIndicator.adaptive(),
                        ),
                        pageLoaderBuilder: (_) => const Center(
                          child: CircularProgressIndicator.adaptive(),
                        ),
                        errorBuilder: (context, _) => Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              ref
                                  .read(appLanguageProviderInstanceProvider)
                                  .tr('text_file_load_failed'),
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: cs.error,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        Positioned(
          left: 16,
          bottom: bottomPadding + 20,
          child: PdfPageNumber(
            controller: controller,
            builder: (context, loading, page, pages) {
              if (loading == PdfLoadingState.loading ||
                  pages == null ||
                  pages <= 1) {
                return const SizedBox.shrink();
              }
              return HeaderFloatingSurface(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Center(
                  child: Text(
                    '$page / $pages',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5,
                      fontSize: 12.5,
                      color: cs.onSurface,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildDocumentContent(
    BuildContext context,
    ThemeData theme,
    ColorScheme cs,
    double contentTopInset,
    double bottomPadding,
  ) {
    final document = _document!;
    final markdown = _currentFile!.isMarkdown;
    final textStyle = theme.textTheme.bodyLarge?.copyWith(
      height: 1.65,
      letterSpacing: 0.2,
      fontFamilyFallback: const [
        'Noto Sans CJK SC',
        'Noto Sans CJK JP',
        'sans-serif',
      ],
    );
    final markdownStyle = MarkdownStyleSheet.fromTheme(theme).copyWith(
      p: textStyle,
      h1: theme.textTheme.headlineMedium?.copyWith(
        fontWeight: FontWeight.w700,
        color: cs.onSurface,
      ),
      h2: theme.textTheme.headlineSmall?.copyWith(
        fontWeight: FontWeight.w700,
        color: cs.onSurface,
      ),
      h3: theme.textTheme.titleLarge?.copyWith(
        fontWeight: FontWeight.w700,
        color: cs.onSurface,
      ),
      code: theme.textTheme.bodyMedium?.copyWith(
        fontFamily: 'monospace',
        backgroundColor: cs.surfaceContainerHighest,
      ),
      codeblockDecoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
    );
    return SelectionArea(
      child: _buildFadeInContent(
        context: context,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960),
            child: CustomScrollView(
              controller: _scrollController,
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(
                    20,
                    contentTopInset,
                    20,
                    bottomPadding + 76,
                  ),
                  sliver: SliverList.builder(
                    itemCount: markdown
                        ? document.markdownNodes.length
                        : document.textBlocks.length,
                    itemBuilder: (context, index) => Padding(
                      key: ValueKey('work_document_${_loadGeneration}_$index'),
                      padding: EdgeInsets.only(
                        bottom: markdown
                            ? (markdownStyle.blockSpacing ?? 8)
                            : 0,
                      ),
                      child: markdown
                          ? TranslatedMarkdownBody(
                              nodes: [document.markdownNodes[index]],
                              styleSheet: markdownStyle,
                            )
                          : _buildTextBlock(
                              document.textBlocks[index],
                              textStyle,
                              collapseBoundary:
                                  index < document.textBlocks.length - 1,
                            ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTextBlock(
    String block,
    TextStyle? style, {
    required bool collapseBoundary,
  }) => WorkPageTranslationBuilder(
    texts: [block],
    builder: (context, translate, _) {
      final text = translate(block);
      final content = Text(text, style: style);
      return collapseBoundary && text.endsWith('\n')
          ? _TextBlockBoundary(child: content)
          : content;
    },
  );

  Widget _buildBottomRightSwitcher(
    BuildContext context,
    ThemeData theme,
    ColorScheme cs,
    AppLanguageProvider i18n,
  ) {
    return HeaderFloatingSurface(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            iconSize: 18,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 32, height: 32),
            icon: const Icon(Icons.chevron_left_rounded),
            tooltip: i18n.tr('prev_text_file'),
            onPressed: () => _onSwitchFile(_currentIndex - 1),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text(
              '${_currentIndex + 1}/${widget.files.length}',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
                fontSize: 12.5,
                color: cs.onSurface,
              ),
            ),
          ),
          IconButton(
            iconSize: 18,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 32, height: 32),
            icon: const Icon(Icons.chevron_right_rounded),
            tooltip: i18n.tr('next_text_file'),
            onPressed: () => _onSwitchFile(_currentIndex + 1),
          ),
        ],
      ),
    );
  }
}

class _TextBlockBoundary extends SingleChildRenderObjectWidget {
  const _TextBlockBoundary({required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _TextBlockBoundaryBox();
}

class _TextBlockBoundaryBox extends RenderProxyBox {
  @override
  void performLayout() {
    super.performLayout();
    RenderBox text = child!;
    // Selectable Text adds a MouseRegion above its paragraph.
    while (text is RenderProxyBox) {
      text = text.child!;
    }
    final paragraph = text as RenderParagraph;
    // Keep the newline in selection/copy, but reuse the paragraph's completed
    // layout to omit its empty last line. The next block supplies that line.
    final end = paragraph.getOffsetForCaret(
      TextPosition(offset: paragraph.text.toPlainText().length),
      Rect.zero,
    );
    size = constraints.constrain(Size(size.width, end.dy));
  }
}
