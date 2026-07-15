import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as path;
import '../../../core/app_language.dart';
import '../../../core/logging/app_log_service.dart';
import '../../../core/media/card_info_field.dart';
import '../domain/audio_effects.dart';
import '../../asmr/domain/asmr_download.dart';
import '../../library/domain/library_node.dart';
import '../../library/domain/library_entry.dart';
import '../../../core/media/music_track.dart';
import '../../../core/media/path_display.dart';
import '../domain/playback_mode.dart';
import 'playback_session.dart';
import '../../library/application/library_organizer.dart';
import '../../library/application/library_scan_models.dart';
import 'native_playback_bridge.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/media/subtitle_parser.dart';
import '../../../core/ui/warmup_scheduler.dart';

part 'audio_state_models.dart';
part 'audio_state_library_service.dart';
part 'audio_state_playback_timer_services.dart';
part 'audio_state_notification_settings_services.dart';
