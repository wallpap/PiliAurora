import 'dart:math';

import 'package:flutter/foundation.dart';

/// 日志页面和异常报告共用堆栈过滤，只保留实际消费的格式化行为。
abstract final class ReportStackFormatter {
  /// see [FlutterError.defaultStackFilter].
  static List<String>? formatStackString(
    String? stackTrace, [
    int methodCount = -1,
    List<String> stackFilters = const [],
  ]) {
    if (stackTrace == null) return null;
    final removedPackagesAndClasses = <String, int>{
      'dart:async-patch': 0,
      'dart:async': 0,
      'package:catcher_2': 0,
      'package:logger': 0,
      'package:stack_trace': 0,
      'class _AssertionError': 0,
      'class _FakeAsync': 0,
      'class _FrameCallbackEntry': 0,
      'class _Timer': 0,
      'class _RawReceivePortImpl': 0,
      'class _RawReceivePort': 0,
      ...{for (var i in stackFilters) i: 0},
    };
    var skipped = 0;

    final parsedFrames = StackFrame.fromStackString(stackTrace);
    final result = <String>[];

    final length = methodCount > 0
        ? min(methodCount, parsedFrames.length)
        : parsedFrames.length;

    for (var index = 0; index < length; index++) {
      final frame = parsedFrames[index];

      String name = 'class ${frame.className}';
      int? count = removedPackagesAndClasses[name];

      if (count == null) {
        name = '${frame.packageScheme}:${frame.package}';
        count = removedPackagesAndClasses[name];
      }

      if (count != null) {
        skipped++;
        removedPackagesAndClasses[name] = count + 1;
      } else {
        result.add(frame.source.trimRight());
      }
    }

    // Only include packages we actually elided from.
    final where = <String>[
      for (final MapEntry<String, int> entry
          in removedPackagesAndClasses.entries)
        if (entry.value > 0) entry.key,
    ]..sort();
    if (skipped == 1) {
      result.add('(elided one frame from ${where.single})');
    } else if (skipped > 1) {
      if (where.length > 1) {
        where[where.length - 1] = 'and ${where.last}';
      }
      if (where.length > 2) {
        result.add('(elided $skipped frames from ${where.join(", ")})');
      } else {
        result.add('(elided $skipped frames from ${where.join(" ")})');
      }
    }
    return result.isEmpty ? null : result;
  }
}
