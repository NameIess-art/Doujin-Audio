import 'dart:io';
import 'package:media_kit/media_kit.dart';

void main() async {
  MediaKit.ensureInitialized();
  final player = Player();
  try {
    final nativePlayer = player.platform as NativePlayer;
    await nativePlayer.setProperty('af', '@channel_swap:lavfi=[pan=stereo|c0=c1|c1=c0]');
    print('setProperty success');
    await nativePlayer.command([
      'af',
      'add',
      '@channel_swap:lavfi=[pan=stereo|c0=c1|c1=c0]'
    ]);
    print('command success');
  } catch(e) {
    print('Error: $e');
  }
  exit(0);
}
