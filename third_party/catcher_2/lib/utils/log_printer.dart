import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';

/// Output looks like this:
/// ```
/// ┌──────────────────────────
/// │ Error info
/// ├┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄
/// │ Method stack history
/// ├┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄
/// │ Log message
/// └──────────────────────────
/// ```
class PrettyLogPrinter extends LogPrinter {
  /// Controls the method count in stack traces
  /// when [LogEvent.error] was provided.
  ///
  /// In case no [LogEvent.stackTrace] was provided,
  /// [StackTrace.current] will be used to create one.
  ///
  /// * Set to `0` in order to disable printing a stack trace
  /// in case of an error parameter.
  /// * Set to `null` to remove the method count limit all together.
  final int errorMethodCount;

  /// Controls the length of the divider lines.
  final int lineLength;

  /// Whether ansi colors are used to color the output.
  final bool colors;

  /// Whether emojis are prefixed to the log line.
  final bool printEmojis;

  /// Controls the format of [LogEvent.time].
  final DateTimeFormatter dateTimeFormat;

  /// Controls the ascii 'boxing' of different [Level]s.
  ///
  /// By default all levels are 'boxed',
  /// to prevent 'boxing' of a specific level,
  /// include it with `true` in the map.
  ///
  /// Example to prevent boxing of [Level.trace] and [Level.info]:
  /// ```dart
  /// excludeBox: {
  ///   Level.trace: true,
  ///   Level.info: true,
  /// },
  /// ```
  ///
  /// See also:
  /// * [noBoxingByDefault]
  final Map<Level, bool> excludeBox;

  /// Whether the implicit `bool`s in [excludeBox] are `true` or `false` by default.
  ///
  /// By default all levels are 'boxed',
  /// this flips the default to no boxing for all levels.
  /// Individual boxing can still be turned on for specific
  /// levels by setting them manually to `false` in [excludeBox].
  ///
  /// Example to specifically activate 'boxing' of [Level.error]:
  /// ```dart
  /// noBoxingByDefault: true,
  /// excludeBox: {
  ///   Level.error: false,
  /// },
  /// ```
  ///
  /// See also:
  /// * [excludeBox]
  final bool noBoxingByDefault;

  /// See [FlutterError.defaultStackFilter].
  final List<String> stackFilters;

  /// Contains the parsed rules resulting from [excludeBox] and [noBoxingByDefault].
  late final List<bool> _includeBox;
  String _topBorder = '';
  String _middleBorder = '';
  String _bottomBorder = '';

  /// Controls the colors used for the different log levels.
  ///
  /// Default fallbacks are modifiable via [PrettyPrinter.defaultLevelColors].
  final Map<Level, AnsiColor>? levelColors;

  /// Controls the emojis used for the different log levels.
  ///
  /// Default fallbacks are modifiable via [PrettyPrinter.defaultLevelEmojis].
  final Map<Level, String>? levelEmojis;

  PrettyLogPrinter({
    this.errorMethodCount = 64,
    this.lineLength = 120,
    this.colors = true,
    this.printEmojis = true,
    this.dateTimeFormat = DateTimeFormat.none,
    this.excludeBox = const {},
    this.noBoxingByDefault = false,
    this.stackFilters = const [],
    this.levelColors,
    this.levelEmojis,
  }) {
    PrettyPrinter.startTime ??= DateTime.now();

    var doubleDividerLine = StringBuffer();
    var singleDividerLine = StringBuffer();
    for (var i = 0; i < lineLength - 1; i++) {
      doubleDividerLine.write(PrettyPrinter.doubleDivider);
      singleDividerLine.write(PrettyPrinter.singleDivider);
    }

    _topBorder = '${PrettyPrinter.topLeftCorner}$doubleDividerLine';
    _middleBorder = '${PrettyPrinter.middleCorner}$singleDividerLine';
    _bottomBorder = '${PrettyPrinter.bottomLeftCorner}$doubleDividerLine';

    // Translate excludeBox map (constant if default) to includeBox map with all Level enum possibilities
    _includeBox = List.filled(Level.values.length, !noBoxingByDefault);
    excludeBox.forEach((k, v) => _includeBox[k.index] = !v);
  }

  @override
  List<String> log(LogEvent event) {
    var messageStr = stringifyMessage(event.message);

    List<String>? stackTrace;
    if (event.error != null && errorMethodCount != 0) {
      stackTrace = formatStackString(
        event.stackTrace?.toString(),
        errorMethodCount,
        stackFilters,
      );
    }

    var errorStr = event.error?.toString();

    String? timeStr;
    if (dateTimeFormat != DateTimeFormat.none) {
      timeStr = dateTimeFormat(event.time);
    }

    return _formatAndPrint(
      event.level,
      messageStr,
      timeStr,
      errorStr,
      stackTrace,
    );
  }

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

  // Handles any object that is causing JsonEncoder() problems
  static String toEncodableFallback(dynamic object) {
    return object.toString();
  }

  static String? stringifyMessage(dynamic message) {
    final finalMessage = message is Function ? message() : message;
    if (finalMessage is Map || finalMessage is Iterable) {
      const encoder = JsonEncoder.withIndent('  ', toEncodableFallback);
      return encoder.convert(finalMessage);
    } else {
      return finalMessage?.toString();
    }
  }

  AnsiColor _getLevelColor(Level level) {
    AnsiColor? color;
    if (colors) {
      color = levelColors?[level] ?? PrettyPrinter.defaultLevelColors[level];
    }
    return color ?? const AnsiColor.none();
  }

  String _getEmoji(Level level) {
    if (printEmojis) {
      final String? emoji =
          levelEmojis?[level] ?? PrettyPrinter.defaultLevelEmojis[level];
      if (emoji != null) {
        return '$emoji ';
      }
    }
    return '';
  }

  List<String> _formatAndPrint(
    Level level,
    String? message,
    String? time,
    String? error,
    List<String>? stacktrace,
  ) {
    List<String> buffer = [];
    final included = _includeBox[level.index];
    var verticalLineAtLevel = included ? '${PrettyPrinter.verticalLine} ' : '';
    var color = _getLevelColor(level);
    if (included) buffer.add(color(_topBorder));

    if (error != null) {
      for (var line in error.split('\n')) {
        buffer.add(color('$verticalLineAtLevel$line'));
      }
      if (included) buffer.add(color(_middleBorder));
    }

    if (stacktrace != null) {
      for (var line in stacktrace) {
        buffer.add(color('$verticalLineAtLevel$line'));
      }
      if (included) buffer.add(color(_middleBorder));
    }

    if (time != null) {
      buffer.add(color('$verticalLineAtLevel$time'));
      if (included) buffer.add(color(_middleBorder));
    }

    if (message != null) {
      var emoji = _getEmoji(level);
      for (var line in message.split('\n')) {
        buffer.add(color('$verticalLineAtLevel$emoji$line'));
      }
    } else if (included) {
      buffer.removeLast();
    }

    if (included) buffer.add(color(_bottomBorder));

    return buffer;
  }
}
