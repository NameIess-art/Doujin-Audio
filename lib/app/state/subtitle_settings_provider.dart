import 'dart:ui';
import 'package:flutter_riverpod/legacy.dart';
import '../../core/immutable_collections.dart';
import '../application/persisted_state_reloader.dart';
import '../../features/settings/application/app_preferences.dart';

final subtitleSettingsProvider =
    StateNotifierProvider<SubtitleSettingsNotifier, SubtitleSettingsState>((
      ref,
    ) {
      return SubtitleSettingsNotifier();
    });

class SubtitleSettingsState {
  final Map<String, bool> showSubtitlesMap;
  final Map<String, bool> globalSubtitlesMap;
  final Map<String, double> positions;

  final String fontFamily;
  final Color? fontColor;
  final double backgroundOpacity;
  final Color? backgroundColor;
  final double borderDepth;
  final double fontSize;

  SubtitleSettingsState({
    Map<String, bool> showSubtitlesMap = const {},
    Map<String, bool> globalSubtitlesMap = const {},
    Map<String, double> positions = const {},
    this.fontFamily = '',
    this.fontColor,
    this.backgroundOpacity = 0.2,
    this.backgroundColor,
    this.borderDepth = 0.5,
    this.fontSize = 16,
  }) : showSubtitlesMap = immutableMap(showSubtitlesMap),
       globalSubtitlesMap = immutableMap(globalSubtitlesMap),
       positions = immutableMap(positions);

  bool isShowEnabled(String sessionId) => showSubtitlesMap[sessionId] ?? true;
  bool isGlobalEnabled(String sessionId) =>
      globalSubtitlesMap[sessionId] ?? false;

  SubtitleSettingsState copyWith({
    Map<String, bool>? showSubtitlesMap,
    Map<String, bool>? globalSubtitlesMap,
    Map<String, double>? positions,
    String? fontFamily,
    Color? fontColor,
    double? backgroundOpacity,
    Color? backgroundColor,
    double? borderDepth,
    double? fontSize,
    bool clearFontColor = false,
    bool clearBackgroundColor = false,
  }) {
    return SubtitleSettingsState(
      showSubtitlesMap: showSubtitlesMap ?? this.showSubtitlesMap,
      globalSubtitlesMap: globalSubtitlesMap ?? this.globalSubtitlesMap,
      positions: positions ?? this.positions,
      fontFamily: fontFamily ?? this.fontFamily,
      fontColor: clearFontColor ? null : (fontColor ?? this.fontColor),
      backgroundOpacity: backgroundOpacity ?? this.backgroundOpacity,
      backgroundColor: clearBackgroundColor
          ? null
          : (backgroundColor ?? this.backgroundColor),
      borderDepth: borderDepth ?? this.borderDepth,
      fontSize: fontSize ?? this.fontSize,
    );
  }
}

class SubtitleSettingsNotifier extends StateNotifier<SubtitleSettingsState>
    implements PersistedStateReloader, PersistedStateExportPreparer {
  SubtitleSettingsNotifier() : super(SubtitleSettingsState()) {
    _loadFuture = _load();
  }

  late Future<void> _loadFuture;

  Future<void> _load() async {
    final showList =
        await AppPreferences.getStringList('subtitle_show_map') ?? [];
    final Map<String, bool> showMap = {};
    for (var s in showList) {
      final parts = s.split('|');
      if (parts.length == 2) showMap[parts[0]] = parts[1] == 'true';
    }

    final globalList =
        await AppPreferences.getStringList('subtitle_global_map') ?? [];
    final Map<String, bool> globalMap = {};
    for (var s in globalList) {
      final parts = s.split('|');
      if (parts.length == 2) globalMap[parts[0]] = parts[1] == 'true';
    }

    final positionsList =
        await AppPreferences.getStringList('subtitle_positions') ?? [];
    final Map<String, double> positions = {};
    for (var p in positionsList) {
      final parts = p.split('|');
      if (parts.length == 2) {
        positions[parts[0]] = double.tryParse(parts[1]) ?? -1.0;
      }
    }

    final opacityStr = await AppPreferences.getString(
      'subtitle_background_opacity',
    );
    final backgroundOpacity = double.tryParse(opacityStr ?? '') ?? 0.2;

    final fontFamily =
        await AppPreferences.getString('subtitle_font_family') ?? '';

    Color? fontColor;
    final fontColorStr = await AppPreferences.getString('subtitle_font_color');
    if (fontColorStr != null && fontColorStr.isNotEmpty) {
      final c = int.tryParse(fontColorStr, radix: 16);
      if (c != null) fontColor = Color(c);
    }

    Color? backgroundColor;
    final bgColorStr = await AppPreferences.getString(
      'subtitle_background_color',
    );
    if (bgColorStr != null && bgColorStr.isNotEmpty) {
      final c = int.tryParse(bgColorStr, radix: 16);
      if (c != null) backgroundColor = Color(c);
    }

    final borderDepthStr = await AppPreferences.getString(
      'subtitle_border_depth',
    );
    final borderDepth = double.tryParse(borderDepthStr ?? '') ?? 0.5;

    final fontSizeStr = await AppPreferences.getString('subtitle_font_size');
    final fontSize = double.tryParse(fontSizeStr ?? '') ?? 16;

    state = SubtitleSettingsState(
      showSubtitlesMap: showMap,
      globalSubtitlesMap: globalMap,
      positions: positions,
      fontFamily: fontFamily,
      fontColor: fontColor,
      backgroundOpacity: backgroundOpacity,
      backgroundColor: backgroundColor,
      borderDepth: borderDepth,
      fontSize: fontSize,
    );
  }

  @override
  Future<void> prepareForPersistedStateExport() async {
    await _loadFuture;
    final showList = state.showSubtitlesMap.entries
        .map((entry) => '${entry.key}|${entry.value}')
        .toList(growable: false);
    final globalList = state.globalSubtitlesMap.entries
        .map((entry) => '${entry.key}|${entry.value}')
        .toList(growable: false);
    final positions = state.positions.entries
        .map((entry) => '${entry.key}|${entry.value}')
        .toList(growable: false);
    await Future.wait<bool>(<Future<bool>>[
      AppPreferences.setStringList('subtitle_show_map', showList),
      AppPreferences.setStringList('subtitle_global_map', globalList),
      AppPreferences.setStringList('subtitle_positions', positions),
      AppPreferences.setString('subtitle_font_family', state.fontFamily),
      AppPreferences.setString(
        'subtitle_font_color',
        state.fontColor?.toARGB32().toRadixString(16).padLeft(8, '0') ?? '',
      ),
      AppPreferences.setString(
        'subtitle_background_opacity',
        state.backgroundOpacity.toString(),
      ),
      AppPreferences.setString(
        'subtitle_background_color',
        state.backgroundColor?.toARGB32().toRadixString(16).padLeft(8, '0') ??
            '',
      ),
      AppPreferences.setString(
        'subtitle_border_depth',
        state.borderDepth.toString(),
      ),
      AppPreferences.setString('subtitle_font_size', state.fontSize.toString()),
    ]);
  }

  @override
  Future<void> reloadPersistedState() {
    _loadFuture = _load();
    return _loadFuture;
  }

  void toggleShowSubtitles(String sessionId) {
    final next = !state.isShowEnabled(sessionId);
    final newShowMap = Map<String, bool>.from(state.showSubtitlesMap);
    newShowMap[sessionId] = next;

    // When disabling subtitles, also turn off global display so the overlay
    // is hidden immediately without requiring a separate tap.
    Map<String, bool>? newGlobalMap;
    if (!next && state.isGlobalEnabled(sessionId)) {
      newGlobalMap = Map<String, bool>.from(state.globalSubtitlesMap);
      newGlobalMap[sessionId] = false;
    }

    var newPositions = state.positions;
    if (next) {
      newPositions = Map<String, double>.from(state.positions);
      newPositions.remove(sessionId);
    }

    state = state.copyWith(
      showSubtitlesMap: newShowMap,
      globalSubtitlesMap: newGlobalMap,
      positions: newPositions,
    );

    final strList = newShowMap.entries
        .map((e) => '${e.key}|${e.value}')
        .toList();
    AppPreferences.setStringList('subtitle_show_map', strList);

    if (newGlobalMap != null) {
      final globalList = newGlobalMap.entries
          .map((e) => '${e.key}|${e.value}')
          .toList();
      AppPreferences.setStringList('subtitle_global_map', globalList);
    }

    if (next) {
      final posList = newPositions.entries
          .map((e) => '${e.key}|${e.value}')
          .toList();
      AppPreferences.setStringList('subtitle_positions', posList);
    }
  }

  void toggleGlobalSubtitles(String sessionId) {
    setGlobalEnabled(sessionId, !state.isGlobalEnabled(sessionId));
  }

  void setGlobalEnabled(String sessionId, bool enabled) {
    if (state.isGlobalEnabled(sessionId) == enabled) return;
    final newMap = Map<String, bool>.from(state.globalSubtitlesMap);
    newMap[sessionId] = enabled;
    state = state.copyWith(globalSubtitlesMap: newMap);

    final strList = newMap.entries.map((e) => '${e.key}|${e.value}').toList();
    AppPreferences.setStringList('subtitle_global_map', strList);
  }

  void resetForSession(String sessionId) {
    final newShowMap = Map<String, bool>.from(state.showSubtitlesMap);
    final newGlobalMap = Map<String, bool>.from(state.globalSubtitlesMap);
    newShowMap.remove(sessionId);
    newGlobalMap.remove(sessionId);
    state = state.copyWith(
      showSubtitlesMap: newShowMap,
      globalSubtitlesMap: newGlobalMap,
    );

    final showList = newShowMap.entries
        .map((e) => '${e.key}|${e.value}')
        .toList();
    AppPreferences.setStringList('subtitle_show_map', showList);

    final globalList = newGlobalMap.entries
        .map((e) => '${e.key}|${e.value}')
        .toList();
    AppPreferences.setStringList('subtitle_global_map', globalList);
  }

  void turnOffAllSubtitles() {
    state = state.copyWith(showSubtitlesMap: {});
    AppPreferences.setStringList('subtitle_show_map', []);
  }

  void updatePosition(String sessionId, double y) {
    final newPos = Map<String, double>.from(state.positions);
    newPos[sessionId] = y;
    state = state.copyWith(positions: newPos);

    final strList = newPos.entries.map((e) => '${e.key}|${e.value}').toList();
    AppPreferences.setStringList('subtitle_positions', strList);
  }

  void setFontFamily(String fontFamily) {
    state = state.copyWith(fontFamily: fontFamily);
    AppPreferences.setString('subtitle_font_family', fontFamily);
  }

  void setFontColor(Color? color) {
    if (color == null) {
      state = state.copyWith(clearFontColor: true);
      AppPreferences.remove('subtitle_font_color');
    } else {
      state = state.copyWith(fontColor: color);
      AppPreferences.setString(
        'subtitle_font_color',
        color.toARGB32().toRadixString(16).padLeft(8, '0'),
      );
    }
  }

  void setBackgroundOpacity(double opacity) {
    state = state.copyWith(backgroundOpacity: opacity);
    AppPreferences.setString('subtitle_background_opacity', opacity.toString());
  }

  void setFontSize(double fontSize) {
    state = state.copyWith(fontSize: fontSize);
    AppPreferences.setString('subtitle_font_size', fontSize.toString());
  }

  void setBorderDepth(double depth) {
    state = state.copyWith(borderDepth: depth);
    AppPreferences.setString('subtitle_border_depth', depth.toString());
  }

  void setBackgroundColor(Color? color) {
    if (color == null) {
      state = state.copyWith(clearBackgroundColor: true);
      AppPreferences.remove('subtitle_background_color');
    } else {
      state = state.copyWith(backgroundColor: color);
      AppPreferences.setString(
        'subtitle_background_color',
        color.toARGB32().toRadixString(16).padLeft(8, '0'),
      );
    }
  }
}
