import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfx/pdfx.dart';

import '../../../app/localization/app_language_provider.dart';
import '../../../app/state/app_runtime_providers.dart';
import '../../../app/theme/app_design_tokens.dart';
import '../../../app/theme/app_styles.dart';
import '../../../core/logging/app_log_service.dart';
import '../../../core/ui/ui_interaction_coordinator.dart';
import '../../../core/widgets/page_header_inset.dart';
import '../../../core/widgets/app_transitions.dart';
import '../../../core/widgets/top_page_header.dart';
import '../application/work_text_service.dart';
import 'library_providers.dart';
import '../../../core/widgets/page_translation_scope.dart';
import '../../../core/widgets/windows_smooth_scroll_controller.dart';
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
  final ScrollController _scrollController = WindowsSmoothScrollController();
  ModalRoute<dynamic>? _route;

  bool _loading = true;
  PreparedWorkText? _document;
  Uint8List? _pdfBytes;
  bool _loadFailed = false;
  int _loadGeneration = 0;
  bool _loadPending = false;
  WorkTextReadRequest? _readRequest;
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
    _readRequest?.cancel();
    UiInteractionCoordinator.instance.cancelCommit(_loadKey);
    UiInteractionCoordinator.instance.cancelCommit(_resultKey);
    _scrollController.dispose();
    super.dispose();
  }

  WorkTextFile? get _currentFile =>
      widget.files.isNotEmpty ? widget.files[_currentIndex] : null;

  void _loadFile() {
    _loadGeneration++;
    _readRequest?.cancel();
    _readRequest = null;
    UiInteractionCoordinator.instance.cancelCommit(_loadKey);
    UiInteractionCoordinator.instance.cancelCommit(_resultKey);
    _pdfBytes = null;
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
            _route?.isCurrent == false) {
          return;
        }
        _loadPending = false;
        unawaited(_readFile(_currentFile!, gen));
      },
    );
  }

  Future<void> _readFile(WorkTextFile file, int gen) async {
    final request = _readRequest = WorkTextReadRequest();
    try {
      final service = ref.read(workTextServiceProvider);
      final bytes = file.isPdf
          ? await service.readDocumentBytes(file, request: request)
          : null;
      final document = file.isPdf
          ? null
          : await service.readPreparedDocument(file, request: request);
      _publishFileResult(gen, () {
        if (file.isPdf) {
          if (bytes == null || bytes.isEmpty) {
            setState(() {
              _loading = false;
              _loadFailed = true;
            });
            return;
          }
          setState(() {
            _loading = false;
            _pdfBytes = bytes;
          });
        } else {
          setState(() {
            _loading = false;
            _document = document;
          });
        }
      });
    } on WorkTextReadCancelled {
      // A replaced document has no result to publish.
    } catch (_) {
      _publishFileResult(gen, () {
        setState(() {
          _loading = false;
          _loadFailed = true;
        });
      });
    } finally {
      if (identical(_readRequest, request)) _readRequest = null;
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
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
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
                leading: const AppHeaderBackButton(),
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
    final content = WorkPageTranslationHost(
      key: ValueKey(_loadGeneration),
      child: page,
    );
    return Builder(
      builder: (routeContext) {
        // Resuming a pending read must not rebuild an already loaded document.
        _route = ModalRoute.of(routeContext);
        if (_loadPending) _scheduleFileRead();
        return content;
      },
    );
  }

  Widget _buildContent(
    BuildContext context,
    ThemeData theme,
    ColorScheme cs,
    double contentTopInset,
    double bottomPadding,
  ) {
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final Widget content;
    if (_loading) {
      content = const Center(
        key: ValueKey('text_loading'),
        child: CircularProgressIndicator.adaptive(),
      );
    } else if (_loadFailed) {
      content = Center(
        key: const ValueKey('text_failed'),
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
    } else {
      final file = _currentFile;
      if (file == null) {
        content = Center(
          key: const ValueKey('text_empty_file'),
          child: Text(
            i18n.tr('empty_file'),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: cs.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ),
        );
      } else if (_pdfBytes case final bytes?) {
        content = _WorkPdfContent(
          key: ValueKey(('text_pdf', _loadGeneration)),
          bytes: bytes,
          errorMessage: i18n.tr('text_file_load_failed'),
          contentTopInset: contentTopInset,
          bottomPadding: bottomPadding,
        );
      } else if (_document?.isEmpty != false) {
        content = Center(
          key: const ValueKey('text_empty_doc'),
          child: Text(
            i18n.tr('empty_file'),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: cs.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ),
        );
      } else {
        content = KeyedSubtree(
          key: ValueKey('text_doc_${file.path}'),
          child: _buildDocumentContent(
            context,
            theme,
            cs,
            contentTopInset,
            bottomPadding,
          ),
        );
      }
    }

    return AnimatedSwitcher(
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : kPlaceholderContentTransitionDuration,
      switchInCurve: kAppFadeCurve,
      switchOutCurve: kAppFadeCurve,
      child: content,
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
      duration: disableAnimations ? Duration.zero : kAppFadeDuration,
      curve: kAppFadeCurve,
      builder: (context, opacity, child) {
        return FadeTransition(
          opacity: AlwaysStoppedAnimation<double>(opacity),
          child: child,
        );
      },
      child: child,
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
      followBarGlass: true,
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

class _WorkPdfContent extends StatefulWidget {
  const _WorkPdfContent({
    super.key,
    required this.bytes,
    required this.errorMessage,
    required this.contentTopInset,
    required this.bottomPadding,
  });

  final Uint8List bytes;
  final String errorMessage;
  final double contentTopInset;
  final double bottomPadding;

  @override
  State<_WorkPdfContent> createState() => _WorkPdfContentState();
}

class _WorkPdfContentState extends State<_WorkPdfContent> {
  late final _opening = _openDocument();
  PdfDocument? _document;
  PdfController? _controller;
  final _pageRenders = <Future<Object?>>{};

  Future<PdfController?> _openDocument() async {
    final document = await PdfDocument.openData(widget.bytes);
    if (!mounted) {
      await _closeDocument(document);
      return null;
    }
    _document = document;
    // PdfView needs a resolved document because it may detach during opening.
    return _controller = PdfController(document: Future.value(document));
  }

  @override
  void dispose() {
    _controller?.dispose();
    final document = _document;
    if (document != null) unawaited(_closeDocument(document));
    super.dispose();
  }

  Future<void> _closeDocument(PdfDocument document) async {
    // Android requires each PdfRenderer.Page to be closed before its document.
    // PdfView's image futures complete after render and page.close().
    try {
      await Future.wait(_pageRenders);
    } catch (_) {
      // PdfView handles page-image errors. Still close the document.
    }
    try {
      await document.close();
    } catch (error, stackTrace) {
      AppLogService.warning(
        'Failed to close work PDF',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  void _trackPageRender(Future<Object?> render) {
    if (!_pageRenders.add(render)) return;
    unawaited(
      render.then<void>(
        (_) => _pageRenders.remove(render),
        onError: (Object _, StackTrace _) => _pageRenders.remove(render),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    const builders = PdfViewBuilders<DefaultBuilderOptions>(
      options: DefaultBuilderOptions(),
    );
    const loader = Center(child: CircularProgressIndicator.adaptive());

    return FutureBuilder<PdfController?>(
      future: _opening,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                widget.errorMessage,
                style: theme.textTheme.bodyMedium?.copyWith(color: cs.error),
              ),
            ),
          );
        }
        final controller = snapshot.data;
        if (controller == null) return loader;
        return Stack(
          children: [
            Positioned.fill(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  16,
                  widget.contentTopInset,
                  16,
                  widget.bottomPadding + 76,
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 960),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: PdfView(
                        controller: controller,
                        scrollDirection: Axis.vertical,
                        pageSnapping: false,
                        builders: PdfViewBuilders<DefaultBuilderOptions>(
                          options: builders.options,
                          documentLoaderBuilder: (_) => loader,
                          pageLoaderBuilder: (_) => loader,
                          pageBuilder: (context, render, index, document) {
                            _trackPageRender(render);
                            return builders.pageBuilder(
                              context,
                              render,
                              index,
                              document,
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              left: 16,
              bottom: widget.bottomPadding + 20,
              child: PdfPageNumber(
                controller: controller,
                builder: (context, loading, page, pages) {
                  if (loading == PdfLoadingState.loading ||
                      pages == null ||
                      pages <= 1) {
                    return const SizedBox.shrink();
                  }
                  return HeaderFloatingSurface(
                    followBarGlass: true,
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
      },
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
