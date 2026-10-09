import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

import '../../../core/widgets/page_translation_scope.dart';

class TranslatedMarkdownBody extends StatefulWidget {
  const TranslatedMarkdownBody({
    super.key,
    required this.data,
    required this.styleSheet,
  });

  final String data;
  final MarkdownStyleSheet styleSheet;

  @override
  State<TranslatedMarkdownBody> createState() => _TranslatedMarkdownBodyState();
}

class _TranslatedMarkdownBodyState extends State<TranslatedMarkdownBody>
    implements MarkdownBuilderDelegate {
  final _recognizers = <GestureRecognizer>[];
  List<md.Node> _nodes = [];
  List<String> _texts = [];

  @override
  void initState() {
    super.initState();
    _parse();
  }

  @override
  void didUpdateWidget(TranslatedMarkdownBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.data != oldWidget.data) _parse();
  }

  void _parse() {
    _nodes = md.Document(
      extensionSet: md.ExtensionSet.gitHubFlavored,
      encodeHtml: false,
    ).parseLines(const LineSplitter().convert(widget.data));
    _texts = [];
    _translateNodes(_nodes, (text) {
      _texts.add(text);
      return text;
    });
  }

  // Translate only AST text nodes: markup, URLs and code remain original.
  List<md.Node> _translateNodes(
    List<md.Node> nodes,
    String Function(String) translate,
  ) => nodes.map((node) {
    if (node is md.Text) return md.Text(translate(node.text));
    if (node is! md.Element) return node;
    if (const {'pre', 'code', 'img'}.contains(node.tag) ||
        (node.tag == 'a' && node.textContent == node.attributes['href'])) {
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
      if (!enabled) {
        return MarkdownBody(data: widget.data, styleSheet: widget.styleSheet);
      }
      final children = MarkdownBuilder(
        delegate: this,
        selectable: false,
        styleSheet: widget.styleSheet,
        imageDirectory: null,
        imageBuilder: null,
        checkboxBuilder: null,
        bulletBuilder: null,
        builders: const {},
        paddingBuilders: const {},
        listItemCrossAxisAlignment: MarkdownListItemCrossAxisAlignment.baseline,
        fitContent: true,
      ).build(_translateNodes(_nodes, translate));
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
