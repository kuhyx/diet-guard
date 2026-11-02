// coverage:ignore-file
import 'package:audioplayers/audioplayers.dart';

AudioPlayer? _player;

final _mixOverMusicWithoutFocus = AudioContext(
  android: const AudioContextAndroid(
    contentType: AndroidContentType.sonification,
    usageType: AndroidUsageType.assistanceSonification,
    audioFocus: AndroidAudioFocus.none,
  ),
);

/// Plays the bundled `confirm` cue through the audioplayers plugin.
Future<void> playConfirmCueAsset() async {
  final player = _player ??= AudioPlayer();
  await player.play(
    AssetSource('sounds/log_confirm.ogg'),
    ctx: _mixOverMusicWithoutFocus,
    mode: PlayerMode.lowLatency,
  );
}
