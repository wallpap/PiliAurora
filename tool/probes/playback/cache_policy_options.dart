import 'dart:convert';
import 'dart:io';

import 'package:pili_aurora/plugin/pl_player/models/video_buffer_policy.dart';

/// 为原生缓存探针导出生产策略，避免在 Python 中维护另一份算法。
void main(List<String> arguments) {
  if (arguments.length != 1 ||
      !VideoBufferPolicy.values.any((policy) => policy.name == arguments[0])) {
    stderr.writeln('Usage: cache_policy_options.dart memory|balanced|smooth');
    exitCode = 2;
    return;
  }
  stdout.writeln(
    jsonEncode(
      VideoBufferPolicy.fromName(arguments[0]).options(
        baseMiB: 4,
        seconds: 16,
        byteHysteresisSupported: Platform.isWindows,
      ),
    ),
  );
}
