import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:pili_aurora/services/diagnostics/redact.dart';

/// [files] 由当前日志到最旧轮转文件排列，结果按时间正序返回。
Future<List<Map<String, Object?>>> readDiagnosticHistory(
  List<File> files,
) async {
  final recent = <Map<String, Object?>>[];
  for (final file in files) {
    final records = Queue<Map<String, Object?>>();
    try {
      // 每个轮转文件仅扫描末尾，避免加载完整日志到内存。
      final length = file.lengthSync();
      final offset = length > 262144 ? length - 262144 : 0;
      var skipPartialLine = offset > 0;
      await for (final line
          in file
              .openRead(offset)
              .transform(const Utf8Decoder(allowMalformed: true))
              .transform(const LineSplitter())) {
        if (skipPartialLine) {
          skipPartialLine = false;
          continue;
        }
        try {
          final record = Map<String, Object?>.from(
            DiagnosticRedactor.clean(jsonDecode(line)) as Map,
          );
          records.add(record);
          while (records.length > 200) {
            records.removeFirst();
          }
        } catch (_) {
          /* 忽略中断写入留下的不完整行。 */
        }
      }
    } catch (_) {
      // 文件可能在轮转期间消失或读取中断；保留已读完整记录，并继续向旧文件补齐。
    }
    if (records.isEmpty) continue;

    // 从最新文件向旧文件读取；旧记录放到前面，达到上限后即可停止磁盘扫描。
    recent.insertAll(0, records);
    if (recent.length > 200) {
      recent.removeRange(0, recent.length - 200);
    }
    if (recent.length == 200) break;
  }
  return recent;
}
