import 'package:pili_aurora/services/audio_handler.dart';
import 'package:pili_aurora/services/audio_session.dart';

VideoPlayerServiceHandler? videoPlayerServiceHandler;
AudioSessionHandler? audioSessionHandler;

Future<void> setupServiceLocator() async {
  final audio = await initAudioService();
  final session = AudioSessionHandler();
  await session.initSession();
  videoPlayerServiceHandler = audio;
  audioSessionHandler = session;
}
