/// 导出时清洗敏感字段；采集时只复制有界快照，避免正则处理阻塞播放。
abstract final class DiagnosticRedactor {
  static final _secretKey = RegExp(
    r'authorization|cookie|token|password|passwd|secret|credential|private.?key|api.?key|access.?key|sessdata|bili_jct|csrf|buvid|dedeuserid|identifierforvendor|android.?id|device.?id|fingerprint|signature|^sign$|^w_rid$|^upsig$|auth.?code|auth.?key|ticket',
    caseSensitive: false,
  );
  static final _url = RegExp(
    r'(?:https?|wss?)://[^\s<>"\x27]+(?:<redacted>)?',
    caseSensitive: false,
  );
  // mpv 的音轨标题可能只含文件名和签名查询串，没有 URL scheme。
  // 整段查询一并移除，不能只枚举已知 token 名称而漏掉其他签名参数。
  static final _query = RegExp(r'''\?[^\s<>"']+''');
  // 先定位固定敏感词，再检查赋值尾部，避免长键名和连字符触发重复回溯。
  static final _assignmentKey = RegExp(
    r'authorization|cookie|set-cookie|token|access[_-]?key|api[_-]?key|password|passwd|secret|credential|private[_-]?key|SESSDATA|bili_jct|csrf|(buvid)|DedeUserID|sign(?:ature)?|w_rid|upsig|auth[_-]?(?:code|key)|ticket',
    caseSensitive: false,
  );
  static final _keySuffix = RegExp(r'\w*', caseSensitive: false);
  static final _assignmentValue = RegExp(
    r'''(["']?\s*[=:]\s*)([^\r\n,;}]+)''',
  );
  static final _bearer = RegExp(
    r'\b(Bearer|Basic)\s+[^\s,;]+',
    caseSensitive: false,
  );
  static final _header = RegExp(
    r'''((?:authorization|cookie|set-cookie)["']?\s*[:=]\s*)[^\r\n]+''',
    caseSensitive: false,
  );
  static final _privateKey = RegExp(
    r'-----BEGIN (?:[A-Z]+ )*PRIVATE KEY-----[\s\S]*?(?:-----END (?:[A-Z]+ )*PRIVATE KEY-----|$)',
  );
  static final _windowsPath = RegExp(r'\b[A-Za-z]:[\\/][^\r\n"<>]+');
  static final _unixUserPath = RegExp(r'/(?:Users|home)/[^\s/]+');
  // 覆盖所有规则的必要入口；普通字段只扫描一次，后续仍按原顺序脱敏。
  static final _textMarker = RegExp(
    r'[:=?/]|-----BEGIN |\b(?:Bearer|Basic)\s',
    caseSensitive: false,
  );

  static String text(Object? value, {int maxLength = 4096}) {
    final input = value.toString();
    var result = input.length > 1048576 ? input.substring(0, 1048576) : input;
    if (!_textMarker.hasMatch(result)) {
      return boundedText(result, maxLength: maxLength);
    }
    if (result.contains('-----BEGIN ')) {
      result = result.replaceAll(_privateKey, '<private-key>');
    }
    if (result.contains('://')) {
      result = result.replaceAllMapped(_url, (match) {
        final uri = Uri.tryParse(match[0]!);
        if (uri == null) return '<url>';
        final endpoint = Uri(
          scheme: uri.scheme,
          host: uri.host,
          port: uri.hasPort ? uri.port : null,
          path: uri.path,
        );
        return '$endpoint${uri.hasQuery ? '?<redacted>' : ''}';
      });
    }
    if (result.contains('?')) {
      result = result.replaceAll(_query, '?<redacted>');
    }
    final hasColon = result.contains(':');
    if (hasColon || result.contains('=')) {
      result = result.replaceAllMapped(
        _header,
        (match) => '${match[1]}<redacted>',
      );
      result = _redactAssignments(result);
    }
    result = result.replaceAllMapped(
      _bearer,
      (match) => '${match[1]} <redacted>',
    );
    // 本机用户名及目录不是诊断指标。
    if (hasColon) {
      result = result.replaceAll(_windowsPath, '<local-path>');
    }
    if (result.contains('/')) {
      result = result.replaceAll(_unixUserPath, '/<user>');
    }
    return boundedText(result, maxLength: maxLength);
  }

  static String _redactAssignments(String input) {
    StringBuffer? output;
    var copied = 0;
    var cursor = 0;
    var buvidEnd = -1;
    Match? buvidValue;
    while (cursor < input.length) {
      final key = _assignmentKey.allMatches(input, cursor).firstOrNull;
      if (key == null) break;
      cursor = key.end;
      var valueStart = cursor;
      final Match? value;
      if (key[1] != null) {
        // 同一词的后缀和赋值只检查一次，仍保留 buvidapi-key 等重叠候选。
        if (cursor > buvidEnd) {
          buvidEnd = _keySuffix.matchAsPrefix(input, cursor)!.end;
          buvidValue = _assignmentValue.matchAsPrefix(input, buvidEnd);
        }
        valueStart = buvidEnd;
        value = buvidValue;
      } else {
        value = _assignmentValue.matchAsPrefix(input, cursor);
      }
      if (value == null) {
        // 固定词也可能重叠，例如 secretoken；失败后仅推进一个字符。
        cursor = key.start + 1;
        continue;
      }
      (output ??= StringBuffer())
        ..write(input.substring(copied, valueStart))
        ..write(value[1])
        ..write('<redacted>');
      cursor = copied = value.end;
    }
    if (output == null) return input;
    output.write(input.substring(copied));
    return output.toString();
  }

  static Object? clean(
    Object? value, {
    int maxCharacters = 8192,
    int maxStringLength = 4096,
  }) => _clean(value, _Budget(maxCharacters, maxStringLength), 0);

  static Object? snapshot(
    Object? value, {
    int maxCharacters = 8192,
    int maxStringLength = 4096,
  }) =>
      _clean(value, _Budget(maxCharacters, maxStringLength, redact: false), 0);

  static String boundedText(Object? value, {int maxLength = 4096}) {
    final input = value.toString();
    return input.length <= maxLength
        ? input
        : '${input.substring(0, maxLength)}…<truncated>';
  }

  static Map<String, Object?> snapshotNativeMemory(
    Map<String, Object?> value,
  ) => _resourceOwners(value, 'owners', redact: false);

  static Map<String, Object?> _resourceOwners(
    Map value,
    String ownerKey, {
    bool redact = true,
  }) {
    Object? copy(Object? item) => redact ? clean(item) : snapshot(item);
    return {
      ...Map<String, Object?>.from(
        copy({
          for (final entry in value.entries)
            if (entry.key != ownerKey && entry.key != 'resources')
              entry.key: entry.value,
        }) as Map,
      ),
      if (value.containsKey('resources')) 'resources': copy(value['resources']),
      if (value[ownerKey] is List)
        ownerKey: [
          for (final owner in (value[ownerKey] as List).take(8)) copy(owner),
        ],
    };
  }

  /// sample 的各字段与来源独立限界，不能让内存明细耗尽后续来源预算。
  static Map<String, Object?> exportRecord(Map<String, Object?> record) {
    if (record['type'] == 'memoryAttribution') {
      final owners = record['owners'];
      return {
        for (final entry in record.entries)
          if (entry.key != 'owners') entry.key: clean(entry.value),
        if (owners is Map)
          'owners': {
            for (final entry in owners.entries.take(16))
              entry.key: entry.key == 'plugin.video' && entry.value is Map
                  ? _resourceOwners(entry.value as Map, 'outputs')
                  : clean(entry.value),
          },
      };
    }
    if (record['type'] == 'sample') {
      final sources = record['sources'] ?? const {};
      return {
        for (final entry in record.entries)
          if (entry.key != 'sources')
            entry.key: entry.key == 'nativeMemory' && entry.value is Map
                ? _resourceOwners(entry.value as Map, 'owners')
                : clean(entry.value),
        'sources': sources is Map
            ? {
                for (final entry in sources.entries.take(64))
                  ...Map<String, Object?>.from(
                    clean({entry.key: entry.value}) as Map,
                  ),
              }
            : clean(sources),
      };
    }
    // 日志顶层、正文和详情分别处理，保留播放器的长日志和内存分块。
    final player = record['channel'] == 'player';
    return {
      ...Map<String, Object?>.from(
        clean({
          for (final entry in record.entries)
            if (entry.key != 'details' &&
                entry.key != 'message' &&
                entry.key != 'stack')
              entry.key: entry.value,
        }) as Map,
      ),
      if (record.containsKey('message'))
        'message': text(
          record['message'] is Map || record['message'] is Iterable
              ? clean(record['message'])
              : record['message'],
          maxLength: player ? 65536 : 16384,
        ),
      if (record.containsKey('stack'))
        'stack': text(record['stack'], maxLength: player ? 65536 : 4096),
      if (record.containsKey('details'))
        'details': clean(
          record['details'],
          maxCharacters: player ? 262144 : 8192,
          maxStringLength: player ? 65536 : 4096,
        ),
    };
  }

  static Object? _clean(Object? value, _Budget budget, int depth) {
    if (depth > 8 || budget.nodes-- <= 0 || budget.characters <= 0) {
      return '<truncated>';
    }
    if (value == null || value is bool || value is int) return value;
    if (value is double) return value.isFinite ? value : null;
    if (value is Map) {
      final result = <String, Object?>{};
      for (final entry in value.entries.take(64)) {
        final key = budget.redact ? text(entry.key) : entry.key.toString();
        // 原键保留到导出，避免截掉敏感键后缀后失去识别依据。
        final outputKey = budget.redact
            ? key.substring(0, key.length.clamp(0, 96))
            : key;
        result[outputKey] =
            budget.redact && _secretKey.hasMatch(entry.key.toString())
            ? '<redacted>'
            : _clean(entry.value, budget, depth + 1);
      }
      return result;
    }
    if (value is Iterable) {
      return value
          .take(64)
          .map((item) => _clean(item, budget, depth + 1))
          .toList();
    }
    final result = (budget.redact ? text : boundedText)(
      value,
      maxLength: budget.characters.clamp(0, budget.maxStringLength),
    );
    final length = result.length.clamp(0, budget.characters);
    budget.characters -= length;
    return length == result.length ? result : '${result.substring(0, length)}…';
  }
}

class _Budget {
  _Budget(this.characters, this.maxStringLength, {this.redact = true});
  final bool redact;
  final int maxStringLength;
  int nodes = 256;
  int characters;
}
