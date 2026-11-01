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
  static final _assignment = RegExp(
    r'''((?:authorization|cookie|set-cookie|\b[\w-]*token|access[_-]?key|api[_-]?key|password|passwd|secret|credential|private[_-]?key|SESSDATA|bili_jct|csrf|buvid\w*|DedeUserID|sign(?:ature)?|w_rid|upsig|auth[_-]?(?:code|key)|ticket)["']?\s*[=:]\s*)([^\r\n,;}]+)''',
    caseSensitive: false,
  );
  static final _bearer = RegExp(
    r'\b(?:Bearer|Basic)\s+[^\s,;]+',
    caseSensitive: false,
  );
  static final _header = RegExp(
    r'''((?:authorization|cookie|set-cookie)["']?\s*[:=]\s*)[^\r\n]+''',
    caseSensitive: false,
  );
  static final _privateKey = RegExp(
    r'-----BEGIN (?:[A-Z]+ )*PRIVATE KEY-----[\s\S]*?(?:-----END (?:[A-Z]+ )*PRIVATE KEY-----|$)',
  );

  static String text(Object? value, {int maxLength = 4096}) {
    final input = value.toString();
    var result = (input.length > 1048576 ? input.substring(0, 1048576) : input)
        .replaceAll(_privateKey, '<private-key>')
        .replaceAllMapped(_url, (match) {
          final uri = Uri.tryParse(match[0]!);
          if (uri == null) return '<url>';
          final endpoint = Uri(
            scheme: uri.scheme,
            host: uri.host,
            port: uri.hasPort ? uri.port : null,
            path: uri.path,
          );
          return '$endpoint${uri.hasQuery ? '?<redacted>' : ''}';
        })
        .replaceAll(_query, '?<redacted>')
        .replaceAllMapped(_header, (match) => '${match[1]}<redacted>')
        .replaceAllMapped(_assignment, (match) => '${match[1]}<redacted>')
        .replaceAllMapped(
          _bearer,
          (match) => '${match[0]!.split(RegExp(r'\s')).first} <redacted>',
        );
    // 本机用户名及目录不是诊断指标。
    result = result.replaceAll(
      RegExp(r'\b[A-Za-z]:[\\/][^\r\n"<>]+'),
      '<local-path>',
    );
    result = result.replaceAll(
      RegExp(r'/(?:Users|home)/[^\s/]+'),
      '/<user>',
    );
    return result.length <= maxLength
        ? result
        : '${result.substring(0, maxLength)}…<truncated>';
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

  /// sample 的各字段与来源独立限界，不能让内存明细耗尽后续来源预算。
  static Map<String, Object?> exportRecord(Map<String, Object?> record) {
    if (record['type'] == 'sample') {
      final sources = record['sources'] as Map? ?? const {};
      return {
        for (final entry in record.entries)
          if (entry.key != 'sources') entry.key: clean(entry.value),
        'sources': {
          for (final entry in sources.entries.take(64))
            ...Map<String, Object?>.from(
              clean({entry.key: entry.value}) as Map,
            ),
        },
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
