import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

import '../../../core/widgets/page_translation_scope.dart';

class TranslatedMarkdownBody extends StatefulWidget {
  const TranslatedMarkdownBody({
    super.key,
    required this.nodes,
    required this.styleSheet,
  });

  final List<md.Node> nodes;
  final MarkdownStyleSheet styleSheet;

  @override
  State<TranslatedMarkdownBody> createState() => _TranslatedMarkdownBodyState();
}

class _TranslatedMarkdownBodyState extends State<TranslatedMarkdownBody>
    implements MarkdownBuilderDelegate {
  final _recognizers = <GestureRecognizer>[];
  List<String> _texts = [];

  @override
  void initState() {
    super.initState();
    _collectTexts();
  }

  @override
  void didUpdateWidget(TranslatedMarkdownBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!listEquals(widget.nodes, oldWidget.nodes)) {
      _collectTexts();
    }
  }

  void _collectTexts() {
    _texts = [];
    void collect(List<md.Node> nodes) {
      for (final node in nodes) {
        if (node is md.Text) {
          _texts.add(node.text);
        } else if (node is md.Element && !_keepOriginal(node)) {
          collect(node.children ?? const []);
        }
      }
    }

    collect(widget.nodes);
  }

  bool _keepOriginal(md.Element node) =>
      const {'pre', 'code', 'img'}.contains(node.tag) ||
      (node.tag == 'a' && node.textContent == node.attributes['href']);

  // Translate only AST text nodes: markup, URLs and code remain original.
  List<md.Node> _translateNodes(
    List<md.Node> nodes,
    String Function(String) translate,
  ) => nodes.map((node) {
    if (node is md.Text) return md.Text(translate(node.text));
    if (node is! md.Element) return node;
    if (_keepOriginal(node)) {
      return node;
    }
    final copy = md.Element(
      node.tag,
      node.children == null ? null : _translateNodes(node.children!, translate),
    );
    copy.attributes.addAll(node.attributes);
    return copy;
  }).toList();

  void _disposeRecognizers() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  @override
  GestureRecognizer createLink(String text, String? href, String title) {
    final recognizer = TapGestureRecognizer();
    _recognizers.add(recognizer);
    return recognizer;
  }

  @override
  TextSpan formatText(MarkdownStyleSheet styleSheet, String code) => TextSpan(
    style: styleSheet.code,
    text: code.replaceFirst(RegExp(r'\n$'), ''),
  );

  @override
  Widget build(BuildContext context) => WorkPageTranslationBuilder(
    texts: _texts,
    builder: (context, translate, enabled) {
      _disposeRecognizers();
      final children =
          MarkdownBuilder(
            delegate: this,
            selectable: false,
            styleSheet: widget.styleSheet,
            imageDirectory: null,
            imageBuilder: null,
            checkboxBuilder: null,
            bulletBuilder: null,
            builders: const {},
            paddingBuilders: const {},
            listItemCrossAxisAlignment:
                MarkdownListItemCrossAxisAlignment.baseline,
            fitContent: true,
          ).build(
            enabled ? _translateNodes(widget.nodes, translate) : widget.nodes,
          );
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      );
    },
  );

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }
}
