import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/services/diagnostics/diagnostics.dart';
import 'package:pili_aurora/utils/platform_utils.dart';
import 'package:share_plus/share_plus.dart';

Future<void> showDiagnosticLogLevelDialog(
  BuildContext context, {
  Diagnostics? diagnostics,
  bool player = false,
}) async {
  final service = diagnostics ?? Diagnostics.instance;
  final selected = await showDialog<DiagnosticLogLevel>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text(player ? '播放器与解码日志等级' : '日志等级'),
      children: [
        for (final level in DiagnosticLogLevel.values)
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(level),
            child: ListTile(
              title: Text(level.label),
              subtitle: Text(level.description),
              trailing: level == (player ? service.playerLevel : service.level)
                  ? const Icon(Icons.check)
                  : null,
            ),
          ),
      ],
    ),
  );
  if (selected != null) {
    try {
      await service.configure(
        level: player ? null : selected,
        playerLevel: player ? selected : null,
      );
    } catch (_) {
      if (context.mounted) _message(context, '日志等级已调整，但设置保存失败');
    }
  }
}

void _message(BuildContext context, String message) =>
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));

class DiagnosticsPage extends StatefulWidget {
  const DiagnosticsPage({super.key, this.diagnostics});
  final Diagnostics? diagnostics;

  @override
  State<DiagnosticsPage> createState() => _DiagnosticsPageState();
}

class _DiagnosticsPageState extends State<DiagnosticsPage> {
  late final service = widget.diagnostics ?? Diagnostics.instance;
  bool _exporting = false;

  Future<void> _configure({bool? tracing, int? intervalMs}) async {
    try {
      await service.configure(tracing: tracing, intervalMs: intervalMs);
    } catch (_) {
      if (mounted) _message(context, '设置保存失败');
    }
  }

  Future<void> _export() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    File? file;
    try {
      file = await service.exportArchive();
      if (!mounted) return;
      if (PlatformUtils.isDesktop) {
        final destination = await FilePicker.saveFile(
          bytes: Uint8List(0),
          fileName:
              'PiliAurora-diagnostics-${DateTime.now().millisecondsSinceEpoch}.zip',
          type: FileType.custom,
          allowedExtensions: const ['zip'],
        );
        if (destination != null) {
          await file.copy(destination.toFilePath());
          if (mounted) _message(context, '诊断包已导出');
        }
      } else {
        await SharePlus.instance.share(ShareParams(files: [XFile(file.path)]));
      }
    } catch (_) {
      if (mounted) _message(context, '导出失败，请检查存储空间和目标目录');
    } finally {
      // 只清理本次导出创建的临时目录。
      try {
        if (file != null) await file.parent.delete(recursive: true);
      } catch (_) {
        if (mounted) _message(context, '临时诊断包清理失败');
      }
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清除诊断记录'),
        content: const Text('停止性能跟踪，并清除本机保存的性能记录和运行日志？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      try {
        await service.clear();
      } catch (_) {
        if (mounted) _message(context, '清除失败');
      }
    }
  }

  String _number(Object? value, String suffix, {double divisor = 1}) =>
      value is num ? '${(value / divisor).toStringAsFixed(1)}$suffix' : '不可用';
  Widget _metric(String title, String value) => SizedBox(
    width: 180,
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title),
            const SizedBox(height: 4),
            Text(value, style: const TextStyle(fontSize: 20)),
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: service,
    builder: (context, _) {
      final latest = service.latest;
      final process = latest?['process'] as Map? ?? const {};
      final frames = latest?['frames'] as Map? ?? const {};
      final images = latest?['images'] as Map? ?? const {};
      final logs = service.recentLogs;
      return Scaffold(
        appBar: AppBar(
          title: const Text('性能与诊断'),
          actions: [
            IconButton(
              tooltip: '导出诊断包',
              onPressed: _exporting ? null : _export,
              icon: _exporting
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.file_upload_outlined),
            ),
            IconButton(
              tooltip: '清除诊断记录',
              onPressed: _clear,
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ),
        body: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('记录性能'),
                      subtitle: Text(
                        service.tracing ? '正在记录，可返回其他页面复现问题' : '关闭时不进行定时采样',
                      ),
                      value: service.tracing,
                      onChanged: (value) => _configure(tracing: value),
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('采样间隔'),
                      trailing: DropdownButton<int>(
                        value: service.intervalMs,
                        onChanged: (value) => _configure(intervalMs: value),
                        items: const [
                          DropdownMenuItem(value: 250, child: Text('250 毫秒')),
                          DropdownMenuItem(value: 1000, child: Text('1 秒（推荐）')),
                          DropdownMenuItem(value: 5000, child: Text('5 秒')),
                        ],
                      ),
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('日志等级'),
                      subtitle: Text(service.level.description),
                      trailing: Text(service.level.label),
                      onTap: () => showDiagnosticLogLevelDialog(
                        context,
                        diagnostics: service,
                      ),
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('播放器与解码日志等级'),
                      subtitle: Text(
                        '${service.playerLevel.description}；独立保存为 player.jsonl，不受通用日志等级影响。调试含 2 秒快照，跟踪含 250 毫秒快照。',
                      ),
                      trailing: Text(service.playerLevel.label),
                      onTap: () => showDiagnosticLogLevelDialog(
                        context,
                        diagnostics: service,
                        player: true,
                      ),
                    ),
                    const Text(
                      '仅保存在本机。通用日志 32 MiB、播放器/解码日志 128 MiB、性能记录 64 MiB。'
                      '达到各自上限后轮转最旧文件；突发写入队列最多 32768 条/32 MiB，单条最多 1 MiB。'
                      '导出包含三个通道及丢弃原因、轮转计数。详细等级会增加磁盘占用和采样开销。',
                    ),
                    const SizedBox(height: 16),
                    if (service.storageError != null ||
                        service.droppedRecords > 0)
                      Text(
                        '写入异常：${service.storageError ?? '无'}；丢弃记录：${service.droppedRecords}',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    if (latest == null)
                      const Text('开启后显示采样结果')
                    else ...[
                      Text(
                        '${service.tracing ? '最新采样' : '已停止 · 最后采样'}  #${latest['sequence']}  ${latest['route']}',
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _metric(
                            '进程工作集',
                            _number(
                              process['rssBytes'],
                              ' MiB',
                              divisor: 1048576,
                            ),
                          ),
                          _metric(
                            '启动以来峰值',
                            _number(
                              process['peakRssBytes'],
                              ' MiB',
                              divisor: 1048576,
                            ),
                          ),
                          _metric(
                            '私有提交',
                            _number(
                              process['privateBytes'],
                              ' MiB',
                              divisor: 1048576,
                            ),
                          ),
                          _metric(
                            '进程 CPU / 全机',
                            _number(process['cpuPercentMachine'], '%'),
                          ),
                          _metric(
                            '图片 LRU',
                            _number(
                              images['cacheBytes'],
                              ' MiB',
                              divisor: 1048576,
                            ),
                          ),
                          _metric(
                            '本周期慢帧',
                            '${frames['slowFrames'] ?? 0} / ${frames['count'] ?? 0}',
                          ),
                          _metric(
                            'UI 构建峰值',
                            _number(frames['maxBuildMs'], ' ms'),
                          ),
                          _metric(
                            '光栅化峰值',
                            _number(frames['maxRasterMs'], ' ms'),
                          ),
                        ],
                      ),
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          '缓存值属于进程内存的一部分，不可相加。GPU、Dart 堆及各模块独占内存不可直接测量；“不可用”不表示为零。',
                        ),
                      ),
                      ExpansionTile(
                        title: const Text('各部分详细指标'),
                        children: [
                          Padding(
                            padding: const EdgeInsets.all(12),
                            // 折叠时子树不在树上；用 Builder 把美化 JSON 推迟到展开时再做，
                            // 否则每 250ms 一次的重绘都会序列化整份采样。
                            child: Builder(
                              builder: (_) =>
                                  SelectableText(service.snapshotText()),
                            ),
                          ),
                        ],
                      ),
                    ],
                    const Divider(height: 32),
                    Text(
                      '最近运行日志（${logs.length} 条）',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    if (logs.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: Text('暂无记录。可调高日志详细程度后复现问题。'),
                      ),
                  ],
                ),
              ),
            ),
            SliverList.builder(
              itemCount: logs.length,
              itemBuilder: (context, index) {
                final log = logs[index];
                return ExpansionTile(
                  title: Text(
                    '[${log['level']}] ${log['category']} · ${log['message']}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text('${log['time']}'),
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      // 同上：折叠时不序列化整条日志。
                      child: Builder(
                        builder: (_) => SelectableText(
                          const JsonEncoder.withIndent('  ').convert(log),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 80)),
          ],
        ),
      );
    },
  );
}
