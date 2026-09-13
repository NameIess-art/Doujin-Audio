import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/localization/app_language_provider.dart';
import '../../../app/state/app_runtime_providers.dart';
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
  late int _currentIndex;
  final ScrollController _scrollController = ScrollController();

  bool _loading = true;
  String _content = '';
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex.clamp(
      0,
      widget.files.isEmpty ? 0 : widget.files.length - 1,
    );
    _loadFileText();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  WorkTextFile? get _currentFile =>
      widget.files.isNotEmpty ? widget.files[_currentIndex] : null;

  Future<void> _loadFileText() async {
    final file = _currentFile;
    if (file == null) {
      setState(() {
        _loading = false;
        _content = '';
        _errorMessage = null;
      });
      return;
    }

    setState(() {
      _loading = true;
      _errorMessage = null;
    });

    try {
      final service = ref.read(workTextServiceProvider);
      final result = await service.readDecodedText(file);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _content = result.text;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _errorMessage = e.toString();
      });
    }
  }

  void _onSwitchFile(int newIndex) {
    if (newIndex < 0 || newIndex >= widget.files.length || newIndex == _currentIndex) {
      return;
    }
    setState(() {
      _currentIndex = newIndex;
    });
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }
    _loadFileText();
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ref.watch(appLanguageProviderInstanceProvider);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final file = _currentFile;
    final hasMultipleFiles = widget.files.length > 1;

    final mediaQuery = MediaQuery.of(context);
    final topPadding = mediaQuery.padding.top;
    final bottomPadding = mediaQuery.padding.bottom;

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: _buildContent(context, theme, cs, topPadding, bottomPadding),
          ),
          Positioned(
            top: topPadding + 10,
            left: 16,
            right: 16,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 960),
                child: _buildFloatingHeaderRow(
                  context,
                  theme,
                  cs,
                  file,
                  i18n,
                ),
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
    );
  }

  Widget _buildFloatingHeaderRow(
    BuildContext context,
    ThemeData theme,
    ColorScheme cs,
    WorkTextFile? file,
    AppLanguageProvider i18n,
  ) {
    return Row(
      children: [
        _buildFloatingExitCircle(context, theme, cs),
        const SizedBox(width: 8),
        Expanded(
          child: _buildFloatingTitleCapsule(context, theme, cs, file, i18n),
        ),
      ],
    );
  }

  Widget _buildFloatingExitCircle(
    BuildContext context,
    ThemeData theme,
    ColorScheme cs,
  ) {
    return HeaderFloatingButton(
      child: IconButton(
        icon: const Icon(Icons.arrow_back_rounded),
        tooltip: MaterialLocalizations.of(context).backButtonTooltip,
        onPressed: () => Navigator.of(context).pop(),
      ),
    );
  }

  Widget _buildFloatingTitleCapsule(
    BuildContext context,
    ThemeData theme,
    ColorScheme cs,
    WorkTextFile? file,
    AppLanguageProvider i18n,
  ) {
    return HeaderFloatingSurface(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Center(
        child: Text(
          file?.displayName ?? i18n.tr('script_text_viewer_title'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
            fontSize: 13.5,
            letterSpacing: 0.1,
            color: cs.onSurface,
          ),
        ),
      ),
    );
  }

  Widget _buildContent(
    BuildContext context,
    ThemeData theme,
    ColorScheme cs,
    double topPadding,
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
                style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              FilledButton.tonal(
                onPressed: _loadFileText,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
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

    return SelectionArea(
      child: SingleChildScrollView(
        controller: _scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(
          20,
          topPadding + 10 + 38 + 14,
          20,
          bottomPadding + 76,
        ),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960),
            child: SizedBox(
              width: double.infinity,
              child: Text(
                _content,
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
