/// 日志仅保留诊断所需信息。结构化字段和字符串都经过此入口。
abstract final class DiagnosticRedactor {
  static final _secretKey = RegExp(
    r'authorization|cookie|token|password|passwd|secret|credential|private.?key|api.?key|access.?key|sessdata|bili_jct|csrf|buvid|dedeuserid',
    caseSensitive: false,
  );
  static final _url = RegExp(r'https?://[^\s<>"\x27]+', caseSensitive: false);
  // mpv 的音轨标题可能只含文件名和签名查询串，没有 URL scheme。
  // 整段查询一并移除，不能只枚举已知 token 名称而漏掉其他签名参数。
  static final _query = RegExp(r'''\?[^\s<>"']+''');
  static final _assignment = RegExp(
    r'''((?:authorization|cookie|set-cookie|token|access_token|refresh_token|access[_-]?key|api[_-]?key|password|passwd|secret|credential|private[_-]?key|SESSDATA|bili_jct|csrf|buvid\w*|DedeUserID)["']?\s*[=:]\s*)([^\r\n,;}]+)''',
    caseSensitive: false,
  );
  static final _bearer = RegExp(r'\bBearer\s+[^\s,;]+', caseSensitive: false);
  static final _header = RegExp(
    r'''((?:authorization|cookie|set-cookie)["']?\s*[:=]\s*)[^\r\n]+''',
    caseSensitive: false,
  );
  static final _privateKey = RegExp(
    r'-----BEGIN (?:[A-Z]+ )*PRIVATE KEY-----[\s\S]*?(?:-----END (?:[A-Z]+ )*PRIVATE KEY-----|$)',
  );

  static String text(Object? value) {
    final input = value.toString();
    var result = (input.length > 16384 ? input.substring(0, 16384) : input)
        .replaceAll(_privateKey, '<private-key>')
        .replaceAllMapped(_url, (match) {
          final uri = Uri.tryParse(match[0]!);
          if (uri == null) return '<url>';
          return '${uri.scheme}://${uri.host}${uri.path}${uri.hasQuery ? '?<redacted>' : ''}';
        })
        .replaceAll(_query, '?<redacted>')
        .replaceAllMapped(_header, (match) => '${match[1]}<redacted>')
        .replaceAllMapped(_assignment, (match) => '${match[1]}<redacted>')
        .replaceAll(_bearer, 'Bearer <redacted>');
    // 本机用户名及目录不是诊断指标。
    result = result.replaceAll(
      RegExp(r'\b[A-Za-z]:[\\/][^\r\n"<>]+'),
      '<local-path>',
    );
    result = result.replaceAll(
      RegExp(r'/(?:Users|home)/[^\s/]+'),
      '/<user>',
    );
    return result.length <= 4096 ? result : '${result.substring(0, 4096)}…';
  }

  static Object? clean(Object? value) => _clean(value, _Budget(), 0);

  static Object? _clean(Object? value, _Budget budget, int depth) {
    if (depth > 8 || budget.nodes-- <= 0 || budget.characters <= 0) {
      return '<truncated>';
    }
    if (value == null || value is bool || value is int) return value;
    if (value is double) return value.isFinite ? value : null;
    if (value is Map) {
      return {
        for (final entry in value.entries.take(64))
          text(entry.key).substring(
            0,
            text(entry.key).length.clamp(0, 96),
          ): _secretKey.hasMatch(entry.key.toString())
              ? '<redacted>'
              : _clean(entry.value, budget, depth + 1),
      };
    }
    if (value is Iterable) {
      return value
          .take(64)
          .map((item) => _clean(item, budget, depth + 1))
          .toList();
    }
    final result = text(value);
    final length = result.length.clamp(0, budget.characters);
    budget.characters -= length;
    return length == result.length ? result : '${result.substring(0, length)}…';
  }
}

class _Budget {
  int nodes = 256;
  int characters = 8192;
}
