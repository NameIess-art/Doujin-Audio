import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/player/application/listening_activity_service.dart';
import '../../features/player/domain/listening_activity.dart';

export '../../features/player/domain/listening_activity.dart';

final listeningActivityServiceProvider = Provider<ListeningActivityService?>(
  (ref) => null,
);

final listeningActivityProvider = StreamProvider<ListeningActivityView>(
  (ref) =>
      ref.watch(listeningActivityServiceProvider)?.states ??
      Stream.value(const ListeningActivityView()),
);
