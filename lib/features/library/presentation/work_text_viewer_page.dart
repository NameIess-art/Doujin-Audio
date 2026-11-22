import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfx/pdfx.dart';

import '../../../app/localization/app_language_provider.dart';
import '../../../app/state/app_runtime_providers.dart';
import '../../../app/theme/app_design_tokens.dart';
import '../../../app/theme/app_styles.dart';
import '../../../core/logging/app_log_service.dart';
import '../../../core/ui/ui_interaction_coordinator.dart';
import '../../../core/widgets/app_bottom_sheet.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_feedback.dart';
import '../../../core/widgets/page_header_inset.dart';
import '../../../core/widgets/app_transitions.dart';
import '../../../core/widgets/top_page_header.dart';
import '../application/work_text_service.dart';
import 'library_providers.dart';
import '../../../core/widgets/page_translation_scope.dart';
import '../../../core/widgets/windows_smooth_scroll_controller.dart';
import 'translated_markdown_body.dart';
import '../../../core/widgets/unified_popup_menu.dart';

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
  double _fontScale = 1.0;
  WorkTextEncoding? _encodingOverride;
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
          : await service.readPreparedDocument(
              file,
              encodingOverride: _encodingOverride,
              request: request,
            );
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
      _encodingOverride = null;
    });
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }
    _loadFile();
  }

  Future<void> _copyAllText() async {
    final document = _document;
    if (document == null || document.isEmpty) return;
    final content = _currentFile?.isMarkdown == true
        ? document.markdownNodes.map((node) => node.textContent).join('\n')
        : document.textBlocks.join();
    if (content.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: content));
    unawaited(
      AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection),
    );
    if (!mounted) return;
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    showAppSnackBar(
      context,
      i18n.tr('copied'),
      icon: Icons.content_copy_rounded,
    );
  }

  void _setEncodingOverride(WorkTextEncoding? encoding) {
    if (_encodingOverride == encoding) return;
    setState(() {
      _encodingOverride = encoding;
    });
    _loadFile();
  }

  Future<void> _showFileListSheet(BuildContext context) async {
    if (widget.files.length <= 2) return;
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final selectedIndex = await AppBottomSheet.show<int>(
      context: context,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.65,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppBottomSheetHeader(
                title: i18n.tr('text_file_list'),
                icon: Icons.list_rounded,
              ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: widget.files.length,
                  itemBuilder: (itemContext, index) {
                    final item = widget.files[index];
                    final selected = index == _currentIndex;
                    return ListTile(
                      key: ValueKey<String>('work_text_file_list_item_$index'),
                      dense: true,
                      leading: Icon(
                        item.isPdf
                            ? Icons.picture_as_pdf_outlined
                            : AppDesignTokens.textFileIcon,
                        color: selected
                            ? Theme.of(itemContext).colorScheme.primary
                            : Theme.of(itemContext).colorScheme.onSurfaceVariant,
                        size: 20,
                      ),
                      title: Text(
                        item.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: selected
                              ? FontWeight.w700
                              : FontWeight.w500,
                          color: selected
                              ? Theme.of(itemContext).colorScheme.primary
                              : null,
                        ),
                      ),
                      trailing: selected
                          ? Icon(
                              Icons.check_rounded,
                              size: 18,
                              color: Theme.of(itemContext).colorScheme.primary,
                            )
                          : null,
                      onTap: () => Navigator.of(sheetContext).pop(index),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (mounted && selectedIndex != null) {
      _onSwitchFile(selectedIndex);
    }
  }

  Future<void> _showReadingOptionsSheet(BuildContext context) async {
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final file = _currentFile;
    if (file == null || file.isPdf) return;
    await AppBottomSheet.show<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: StatefulBuilder(
          builder: (innerContext, setSheetState) {
            final cs = Theme.of(innerContext).colorScheme;
            final encodings = <WorkTextEncoding?>[
              null,
              WorkTextEncoding.utf8,
              WorkTextEncoding.shiftJis,
              WorkTextEncoding.gbk,
            ];
            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppBottomSheetHeader(
                    title: i18n.tr('more_actions'),
                    icon: Icons.tune_rounded,
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Text(
                        i18n.tr('text_font_size'),
                        style: Theme.of(innerContext).textTheme.titleSmall,
                      ),
                      const Spacer(),
                      IconButton(
                        key: const ValueKey<String>('work_text_font_decrease'),
                        tooltip: 'A-',
                        onPressed: _fontScale <= 0.8
                            ? null
                            : () {
                                setState(() {
                                  _fontScale = (_fontScale - 0.15).clamp(
                                    0.8,
                                    1.8,
                                  );
                                });
                                setSheetState(() {});
                              },
                        icon: const Icon(Icons.text_decrease_rounded),
                      ),
                      Text(
                        '${(_fontScale * 100).round()}%',
                        style: Theme.of(innerContext).textTheme.labelLarge
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      IconButton(
                        key: const ValueKey<String>('work_text_font_increase'),
                        tooltip: 'A+',
                        onPressed: _fontScale >= 1.8
                            ? null
                            : () {
                                setState(() {
                                  _fontScale = (_fontScale + 0.15).clamp(
                                    0.8,
                                    1.8,
                                  );
                                });
                                setSheetState(() {});
                              },
                        icon: const Icon(Icons.text_increase_rounded),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    i18n.tr('text_encoding'),
                    style: Theme.of(innerContext).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      for (final encoding in encodings)
                        ChoiceChip(
                          key: ValueKey<String>(
                            'work_text_encoding_${encoding?.name ?? 'auto'}',
                          ),
                          label: Text(
                            encoding?.label ?? i18n.tr('text_encoding_auto'),
                          ),
                          selected: _encodingOverride == encoding,
                          visualDensity: VisualDensity.compact,
                          onSelected: (_) {
                            Navigator.of(sheetContext).pop();
                            _setEncodingOverride(encoding);
                          },
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Divider(
                    height: 1,
                    color: cs.outlineVariant.withValues(alpha: 0.4),
                  ),
                  ListTile(
                    key: const ValueKey<String>('work_text_copy_all_action'),
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.content_copy_rounded, size: 20),
                    title: Text(i18n.tr('copy_all')),
                    enabled: _document?.isEmpty == false,
                    onTap: _document?.isEmpty == false
                        ? () {
                            Navigator.of(sheetContext).pop();
                            unawaited(_copyAllText());
                          }
                        : null,
                  ),
                  if (widget.files.length > 2)
                    ListTile(
                      key: const ValueKey<String>('work_text_file_list_action'),
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.list_rounded, size: 20),
                      title: Text(i18n.tr('text_file_list')),
                      onTap: () {
                        Navigator.of(sheetContext).pop();
                        unawaited(_showFileListSheet(context));
                      },
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
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
                iconColor: AppDesignTokens.of(context).textFileColor,
                title: file?.displayName ?? i18n.tr('script_text_viewer_title'),
                trailing: file != null && !file.isPdf
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          WorkPageTranslationButton(
                            buttonKey: 'work_text_translation',
                            enabled: canTranslate,
                          ),
                          const SizedBox(width: 6),
                          HeaderFloatingButton(
                            child: IconButton(
                              key: const ValueKey<String>(
                                'work_text_options_button',
                              ),
                              tooltip: i18n.tr('more_actions'),
                              icon: const Icon(
                                Icons.more_vert_rounded,
                                size: 20,
                              ),
                              onPressed: () =>
                                  _showReadingOptionsSheet(context),
                            ),
                          ),
                        ],
                      )
                    : widget.files.length > 2
                    ? HeaderFloatingButton(
                        child: IconButton(
                          key: const ValueKey<String>(
                            'work_text_file_list_button',
                          ),
                          tooltip: i18n.tr('text_file_list'),
                          icon: const Icon(Icons.list_rounded, size: 20),
                          onPressed: () => _showFileListSheet(context),
                        ),
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
              AppPillButton(
                onPressed: _loadFile,
                style: FilledButton.styleFrom(
                  backgroundColor: cs.secondaryContainer,
                  foregroundColor: cs.onSecondaryContainer,
                ),
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
          retryLabel: i18n.tr('retry'),
          onRetry: _loadFile,
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

  Widget _buildDocumentContent(
    BuildContext context,
    ThemeData theme,
    ColorScheme cs,
    double contentTopInset,
    double bottomPadding,
  ) {
    final document = _document!;
    final markdown = _currentFile!.isMarkdown;
    final baseFontSize = theme.textTheme.bodyLarge?.fontSize ?? 16.0;
    final textStyle = theme.textTheme.bodyLarge?.copyWith(
      fontSize: baseFontSize * _fontScale,
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
        fontSize: (theme.textTheme.headlineMedium?.fontSize ?? 28) * _fontScale,
        fontWeight: FontWeight.w700,
        color: cs.onSurface,
      ),
      h2: theme.textTheme.headlineSmall?.copyWith(
        fontSize: (theme.textTheme.headlineSmall?.fontSize ?? 24) * _fontScale,
        fontWeight: FontWeight.w700,
        color: cs.onSurface,
      ),
      h3: theme.textTheme.titleLarge?.copyWith(
        fontSize: (theme.textTheme.titleLarge?.fontSize ?? 22) * _fontScale,
        fontWeight: FontWeight.w700,
        color: cs.onSurface,
      ),
      code: theme.textTheme.bodyMedium?.copyWith(
        fontSize: (theme.textTheme.bodyMedium?.fontSize ?? 14) * _fontScale,
        fontFamily: 'monospace',
        backgroundColor: cs.surfaceContainerHighest,
      ),
      codeblockDecoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
    );
    final maxWidth = AppDesignTokens.of(context).readableContentMaxWidth;
    return SelectionArea(
      contextMenuBuilder: buildAppSelectableTextMenu,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final horizontalPadding = math.max(
            20.0,
            (constraints.maxWidth - maxWidth) / 2,
          );
          return CustomScrollView(
            controller: _scrollController,
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  horizontalPadding,
                  contentTopInset,
                  horizontalPadding,
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
          );
        },
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
          ? _TextBlockBoundary(textLength: text.length, child: content)
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
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: widget.files.length > 2
                ? () => _showFileListSheet(context)
                : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
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
    required this.retryLabel,
    required this.onRetry,
    required this.contentTopInset,
    required this.bottomPadding,
  });

  final Uint8List bytes;
  final String errorMessage;
  final String retryLabel;
  final VoidCallback onRetry;
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
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.error_outline_rounded, size: 48, color: cs.error),
                  const SizedBox(height: 12),
                  Text(
                    widget.errorMessage,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 16),
                  AppPillButton(
                    key: const ValueKey<String>('work_pdf_retry_button'),
                    onPressed: widget.onRetry,
                    style: FilledButton.styleFrom(
                      backgroundColor: cs.secondaryContainer,
                      foregroundColor: cs.onSecondaryContainer,
                    ),
                    child: Text(widget.retryLabel),
                  ),
                ],
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
  const _TextBlockBoundary({required this.textLength, required super.child});

  final int textLength;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _TextBlockBoundaryBox(textLength);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _TextBlockBoundaryBox renderObject,
  ) {
    renderObject.textLength = textLength;
  }
}

class _TextBlockBoundaryBox extends RenderProxyBox {
  _TextBlockBoundaryBox(this._textLength);

  int _textLength;
  int get textLength => _textLength;
  set textLength(int value) {
    if (_textLength == value) return;
    _textLength = value;
    markNeedsLayout();
  }

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
      TextPosition(offset: _textLength),
      Rect.zero,
    );
    size = constraints.constrain(Size(size.width, end.dy));
  }
}
