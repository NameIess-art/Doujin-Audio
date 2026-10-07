import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../media/cover_image_resolution.dart';

final coverImageResolutionProvider = Provider<CoverImageResolution>(
  (_) => CoverImageResolution.balanced,
);
