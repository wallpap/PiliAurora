import 'dart:convert';
import 'dart:io';

import 'package:media_kit/src/player/native/player/seek_command.dart';

// 原生烟测复用正式命令构造器，避免 Python 另写一份跳转策略。
void main(List<String> args) {
  stdout.writeln(
    jsonEncode(
      nativeSeekCommand(
        Duration(milliseconds: (double.parse(args[0]) * 1000).round()),
        keyframe: true,
        mediaExtras: args.contains('--keyframes-control')
            ? null
            : {'audio-files-append': 'generated.wav'},
      ),
    ),
  );
}
