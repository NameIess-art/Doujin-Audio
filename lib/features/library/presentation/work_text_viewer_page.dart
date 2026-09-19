import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfx/pdfx.dart';

import '../../../app/localization/app_language_provider.dart';
import '../../../app/state/app_runtime_providers.dart';
import '../../../app/theme/app_styles.dart';
import '../../../core/widgets/page_header_inset.dart';
import '../../../core/widgets/top_page_header.dart';
import '../application/work_text_service.dart';

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
  static const int _contentChunkSize = 16 * 1024;
  static const double _loadMoreThreshold = 800;

  late int _currentIndex;
  final ScrollController _scrollController = ScrollController();

  bool _loading = true;
  String _content = '';
  int _visibleContentLength = 0;
  PdfController? _pdfController;
  String? _errorMessage;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_loadMoreIfNeeded);
    _currentIndex = widget.initialIndex.clamp(
      0,
      widget.files.isEmpty ? 0 : widget.files.length - 1,
    );
    _loadFile();
  }

  @override
  void dispose() {
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

  Future<void> _loadFile() async {
    final gen = ++_loadGeneration;
    _disposePdfController();
    final file = _currentFile;
    if (file == null) {
      setState(() {
        _loading = false;
        _content = '';
        _visibleContentLength = 0;
        _errorMessage = null;
      });
      return;
    }

    setState(() {
      _loading = true;
      _errorMessage = null;
      _content = '';
      _visibleContentLength = 0;
    });

    try {
      final service = ref.read(workTextServiceProvider);
      if (file.isPdf) {
        final bytes = await service.readDocumentBytes(file);
        if (!mounted || gen != _loadGeneration) return;
        if (bytes == null || bytes.isEmpty) {
          setState(() {
            _loading = false;
            _errorMessage = 'Failed to load PDF file';
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
        final result = await service.readDecodedText(file);
        if (!mounted || gen != _loadGeneration) return;
        setState(() {
          _loading = false;
          _content = result.text;
          _visibleContentLength = _nextContentEnd(result.text, 0);
        });
        _scheduleViewportFill(gen);
      }
    } catch (e) {
      if (!mounted || gen != _loadGeneration) return;
      setState(() {
        _loading = false;
        _errorMessage = e.toString();
      });
    }
  }

  String get _visibleContent => _content.substring(0, _visibleContentLength);

  int _nextContentEnd(String content, int currentEnd) {
    if (currentEnd >= content.length) return content.length;
    var target = (currentEnd + _contentChunkSize).clamp(0, content.length);
    if (target < content.length) {
      final newline = content.indexOf('\n', target);
      if (newline >= 0 && newline - target <= 1024) {
        target = newline + 1;
      } else if (target > 0 &&
          _isHighSurrogate(content.codeUnitAt(target - 1)) &&
          _isLowSurrogate(content.codeUnitAt(target))) {
        target++;
      }
    }
    return target;
  }

  bool _isHighSurrogate(int codeUnit) =>
      codeUnit >= 0xD800 && codeUnit <= 0xDBFF;

  bool _isLowSurrogate(int codeUnit) =>
      codeUnit >= 0xDC00 && codeUnit <= 0xDFFF;

  void _loadMoreIfNeeded() {
    if (!_scrollController.hasClients ||
        _scrollController.position.extentAfter > _loadMoreThreshold) {
      return;
    }
    _appendContentChunk();
  }

  bool _appendContentChunk() {
    if (_loading ||
        _currentFile?.isPdf == true ||
        _visibleContentLength >= _content.length) {
      return false;
    }
    setState(() {
      _visibleContentLength = _nextContentEnd(_content, _visibleContentLength);
    });
    return true;
  }

  void _scheduleViewportFill(int generation) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          generation != _loadGeneration ||
          !_scrollController.hasClients ||
          _scrollController.position.maxScrollExtent > 0) {
        return;
      }
      if (_appendContentChunk()) {
        _scheduleViewportFill(generation);
      }
    });
  }

  void _onSwitchFile(int newIndex) {
    if (newIndex < 0 ||
        newIndex >= widget.files.length ||
        newIndex == _currentIndex) {
      return;
    }
    setState(() {
      _currentIndex = newIndex;
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

    final bottomPadding = MediaQuery.paddingOf(context).bottom;
    final contentTopInset = AppPageHeaderMetrics.contentTopInset(context);

    return Scaffold(
      backgroundColor: cs.surface,
      body: PageHeaderInset(
        topInset: contentTopInset,
        child: Stack(
          children: [
            Positioned.fill(
              child: _buildContent(
                context,
                theme,
                cs,
                contentTopInset,
                bottomPadding,
              ),
            ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: TopPageHeader(
              key: const ValueKey<String>('work_text_header'),
              icon: file?.isPdf == true
                  ? Icons.picture_as_pdf_rounded
                  : (file?.isMarkdown == true
                      ? Icons.article_rounded
                      : Icons.description_rounded),
              title: file?.displayName ?? i18n.tr('script_text_viewer_title'),
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
              child: _buildBottomRightSwitcher(context, theme, cs, i18n),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent(
    BuildContext context,
    ThemeData theme,
    ColorScheme cs,
    double contentTopInset,
    double bottomPadding,
  ) {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator.adaptive(),
      );
    }

    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline_rounded, size: 48, color: cs.error),
              const SizedBox(height: 12),
              Text(
                _errorMessage!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.tonal(
                onPressed: _loadFile,
                child: const Text('Retry'),
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
          '(Empty file)',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: cs.onSurfaceVariant.withValues(alpha: 0.7),
          ),
        ),
      );
    }

    if (file.isPdf) {
      return _buildPdfContent(context, theme, cs, contentTopInset, bottomPadding);
    }

    if (_content.isEmpty) {
      return Center(
        child: Text(
          '(Empty file)',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: cs.onSurfaceVariant.withValues(alpha: 0.7),
          ),
        ),
      );
    }

    if (file.isMarkdown) {
      return _buildMarkdownContent(
        context,
        theme,
        cs,
        contentTopInset,
        bottomPadding,
      );
    }

    return _buildTextContent(context, theme, cs, contentTopInset, bottomPadding);
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
                      errorBuilder: (context, error) => Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            error.toString(),
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

  Widget _buildMarkdownContent(
    BuildContext context,
    ThemeData theme,
    ColorScheme cs,
    double contentTopInset,
    double bottomPadding,
  ) {
    return SelectionArea(
      child: SingleChildScrollView(
        controller: _scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(
          20,
          contentTopInset,
          20,
          bottomPadding + 76,
        ),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960),
            child: SizedBox(
              width: double.infinity,
              child: MarkdownBody(
                data: _visibleContent,
                styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
                  p: theme.textTheme.bodyLarge?.copyWith(
                    height: 1.65,
                    letterSpacing: 0.2,
                    fontFamilyFallback: const [
                      'Noto Sans CJK SC',
                      'Noto Sans CJK JP',
                      'sans-serif',
                    ],
                  ),
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
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTextContent(
    BuildContext context,
    ThemeData theme,
    ColorScheme cs,
    double contentTopInset,
    double bottomPadding,
  ) {
    return SelectionArea(
      child: SingleChildScrollView(
        controller: _scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(
          20,
          contentTopInset,
          20,
          bottomPadding + 76,
        ),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960),
            child: SizedBox(
              width: double.infinity,
              child: Text(
                _visibleContent,
                style: theme.textTheme.bodyLarge?.copyWith(
                  height: 1.65,
                  letterSpacing: 0.2,
                  fontFamilyFallback: const [
                    'Noto Sans CJK SC',
                    'Noto Sans CJK JP',
                    'sans-serif',
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBottomRightSwitcher(
    BuildContext context,
    ThemeData theme,
    ColorScheme cs,
    AppLanguageProvider i18n,
  ) {
    final canPrev = _currentIndex > 0;
    final canNext = _currentIndex < widget.files.length - 1;

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
            onPressed: canPrev ? () => _onSwitchFile(_currentIndex - 1) : null,
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
            onPressed: canNext ? () => _onSwitchFile(_currentIndex + 1) : null,
          ),
        ],
      ),
    );
  }
}
