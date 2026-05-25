import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../providers/subtitle_settings_provider.dart';
import '../widgets/subtitle_window_visual.dart';

class SubtitleOverlayWindow extends StatefulWidget {
  final WindowController windowController;
  final Map<String, dynamic> args;

  const SubtitleOverlayWindow({
    super.key,
    required this.windowController,
    required this.args,
  });

  @override
  State<SubtitleOverlayWindow> createState() => _SubtitleOverlayWindowState();
}

class _SubtitleOverlayWindowState extends State<SubtitleOverlayWindow> {
  String _subtitleText = '';
  double _fontSize = 16.0;
  Color _backgroundColor = Colors.black;
  Color _textColor = Colors.white;
  double _backgroundOpacity = 0.2;
  String _fontFamily = '';
  double _borderDepth = 0.5;
  double _backgroundBlur = 12.0;

  bool _isPlaying = false;
  bool _isHovering = false;

  @override
  void initState() {
    super.initState();
    _applyInitialArgs();
    widget.windowController.setWindowMethodHandler(_handleMethodCall);
  }

  void _applyInitialArgs() {
    final initialStyle = widget.args['initialStyle'];
    if (initialStyle is Map) {
      _applyStyle(initialStyle);
    }
    final initialSubtitle = widget.args['initialSubtitle'];
    if (initialSubtitle is String) {
      _subtitleText = initialSubtitle;
    }
    final initialIsPlaying = widget.args['initialIsPlaying'];
    if (initialIsPlaying is bool) {
      _isPlaying = initialIsPlaying;
    }
  }

  Future<dynamic> _handleMethodCall(MethodCall call) async {
    if (call.method == 'updateSubtitle') {
      final text = call.arguments['text'] as String?;
      if (text != null && mounted) {
        setState(() {
          _subtitleText = text;
        });
      }
    } else if (call.method == 'updateStyle') {
      final args = call.arguments as Map;
      if (mounted) {
        setState(() {
          _applyStyle(args);
        });
      }
    } else if (call.method == 'updatePlaybackState') {
      final isPlaying = call.arguments['isPlaying'] as bool?;
      if (isPlaying != null && mounted) {
        setState(() {
          _isPlaying = isPlaying;
        });
      }
    }
  }

  Color _parseColor(String hexColor) {
    hexColor = hexColor.replaceAll('#', '');
    if (hexColor.length == 6) {
      hexColor = 'FF$hexColor';
    }
    return Color(int.parse(hexColor, radix: 16));
  }

  void _applyStyle(Map args) {
    if (args['fontSize'] != null) {
      _fontSize = (args['fontSize'] as num).toDouble();
    }
    if (args['backgroundColor'] != null) {
      _backgroundColor = _parseColor(args['backgroundColor'] as String);
    }
    if (args['textColor'] != null) {
      _textColor = _parseColor(args['textColor'] as String);
    }
    if (args['backgroundOpacity'] != null) {
      _backgroundOpacity = (args['backgroundOpacity'] as num).toDouble();
    }
    if (args['fontFamily'] != null) {
      _fontFamily = args['fontFamily'] as String;
    }
    if (args['borderDepth'] != null) {
      _borderDepth = (args['borderDepth'] as num).toDouble();
    }
    if (args['backgroundBlur'] != null) {
      _backgroundBlur = (args['backgroundBlur'] as num).toDouble();
    }
  }

  void _sendCommand(String command) {
    WindowController.fromWindowId('0').invokeMethod(command);
  }

  @override
  Widget build(BuildContext context) {
    final dummySettings = SubtitleSettingsState(
      fontSize: _fontSize,
      backgroundColor: _backgroundColor,
      fontColor: _textColor,
      backgroundOpacity: _backgroundOpacity,
      fontFamily: _fontFamily,
      borderDepth: _borderDepth,
      backgroundBlur: _backgroundBlur,
    );

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: Colors.transparent,
        body: MouseRegion(
          onEnter: (_) => setState(() => _isHovering = true),
          onExit: (_) => setState(() => _isHovering = false),
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onPanStart: (details) {
              windowManager.startDragging();
            },
            child: Container(
              color: Colors.transparent,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  AnimatedOpacity(
                    opacity: _isHovering ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 200),
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: _backgroundColor.withValues(alpha: 0.8),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(
                              Icons.skip_previous,
                              color: Colors.white,
                            ),
                            iconSize: 20,
                            onPressed: () => _sendCommand('previous'),
                          ),
                          IconButton(
                            icon: Icon(
                              _isPlaying ? Icons.pause : Icons.play_arrow,
                              color: Colors.white,
                            ),
                            iconSize: 20,
                            onPressed: () => _sendCommand('playPause'),
                          ),
                          IconButton(
                            icon: const Icon(
                              Icons.skip_next,
                              color: Colors.white,
                            ),
                            iconSize: 20,
                            onPressed: () => _sendCommand('next'),
                          ),
                          const SizedBox(width: 8),
                          IconButton(
                            icon: const Icon(
                              Icons.close,
                              color: Colors.redAccent,
                            ),
                            iconSize: 20,
                            onPressed: () => _sendCommand('closeOverlay'),
                          ),
                        ],
                      ),
                    ),
                  ),
                  SubtitleWindowVisual(
                    settings: dummySettings,
                    text: _subtitleText,
                    maxTextWidth: double.infinity,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
