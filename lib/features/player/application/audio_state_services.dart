import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import '../../../core/immutable_collections.dart';
import '../../../core/logging/app_log_service.dart';
import '../domain/playback_mode.dart';
import 'playback_session.dart';
import 'native_playback_bridge.dart';
import '../../../app/application/audio_state_slice.dart';

part 'audio_state_models.dart';
part 'audio_state_playback_timer_services.dart';
part 'audio_state_notification_settings_services.dart';
