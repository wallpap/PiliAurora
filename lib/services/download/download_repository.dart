import 'dart:convert';
import 'dart:io';

import 'package:pili_aurora/models/remote/download/bili_download_entry_info.dart';
import 'package:pili_aurora/models/remote/download/bili_download_media_file_info.dart';
import 'package:pili_aurora/utils/extension/file_ext.dart';
import 'package:path/path.dart' as path;
import 'package:synchronized/synchronized.dart';

/// 下载目录布局及记录持久化的唯一写入口，不依赖 GetX、网络或全局偏好。
class DownloadRepository {
  DownloadRepository({required this._rootPath, this._onReadError});

  static const _entryFile = 'entry.json';
  static const _indexFile = 'index.json';
  final String Function() _rootPath;
  final void Function(String, Object, StackTrace)? _onReadError;
  final _lock = Lock();

  Future<List<BiliDownloadEntryInfo>> load() => _lock.synchronized(() async {
    final root = await Directory(_rootPath()).create(recursive: true);
    final entries = <BiliDownloadEntryInfo>[];
    await for (final pageDir in root.list(followLinks: false)) {
      if (pageDir is! Directory) continue;
      await for (final entryDir in pageDir.list(followLinks: false)) {
        if (entryDir is! Directory) continue;
        final file = File(path.join(entryDir.path, _entryFile));
        try {
          final entry = await _readRecord(
            file,
            BiliDownloadEntryInfo.fromJson,
          );
          if (entry == null) continue;
          entry
            ..pageDirPath = pageDir.path
            ..entryDirPath = entryDir.path;
          // 索引仍保留既有路径和格式；启动时修复上次未完成的替换。
          if (entry.typeTag case final tag?) {
            await _readRecord<BiliDownloadMediaInfo>(
              File(path.join(entryDir.path, tag, _indexFile)),
              entry.mediaType == 1 ? Type1.fromJson : Type2.fromJson,
            );
          }
          entries.add(entry);
        } catch (error, stackTrace) {
          // 单条损坏记录不能阻止其余任务恢复，诊断由装配层决定。
          _onReadError?.call(file.path, error, stackTrace);
        }
      }
    }
    return entries;
  });

  Future<void> create(BiliDownloadEntryInfo entry) async {
    final String pageName, entryName;
    if (entry.ep case final ep?) {
      pageName = 's_${entry.seasonId}';
      entryName = ep.episodeId.toString();
    } else if (entry.pageData case final page?) {
      pageName = entry.avid.toString();
      entryName = 'c_${page.cid}';
    } else {
      throw ArgumentError('下载记录必须包含视频分 P 或剧集信息');
    }
    final directory = await Directory(
      path.join(_rootPath(), pageName, entryName),
    ).create(recursive: true);
    entry
      ..pageDirPath = directory.parent.path
      ..entryDirPath = directory.path;
    await save(entry);
  }

  Future<void> save(BiliDownloadEntryInfo entry) {
    // 在排队前拍下当前状态，避免可变模型在等待期间改变本次写入的含义。
    final contents = jsonEncode(entry.toJson());
    final file = File(path.join(entry.entryDirPath, _entryFile));
    return _lock.synchronized(
      () => _writeJson(file, contents, BiliDownloadEntryInfo.fromJson),
    );
  }

  Future<String> saveMediaInfo(
    BiliDownloadEntryInfo entry,
    BiliDownloadMediaInfo media,
  ) async {
    final contents = jsonEncode(media.toJson());
    final directory = Directory(path.join(entry.entryDirPath, entry.typeTag));
    await _lock.synchronized(() async {
      await directory.create(recursive: true);
      await _writeJson(
        File(path.join(directory.path, _indexFile)),
        contents,
        media is Type1 ? Type1.fromJson : Type2.fromJson,
      );
    });
    return directory.path;
  }

  /// 临时文件与目标位于同一目录，flush/close 后才重命名。
  /// Windows 文件占用或替换失败时直接报错，绝不先删除正式文件。
  void _writeString(File file, String contents) {
    file.writeAsStringSync(contents, flush: true);
  }

  Future<void> _writeJson(
    File file,
    String contents,
    Object Function(Map<String, dynamic>) decode,
  ) async {
    decode(jsonDecode(contents) as Map<String, dynamic>);
    final temporary = File('${file.path}.tmp');
    _writeString(temporary, contents);
    if (file.existsSync()) {
      String? previous;
      try {
        final candidate = file.readAsStringSync();
        decode(jsonDecode(candidate) as Map<String, dynamic>);
        previous = candidate;
      } catch (error, stack) {
        _onReadError?.call(file.path, error, stack);
      }
      // 损坏的正式文件不能覆盖上次可恢复的备份。
      if (previous != null) {
        final backup = File('${file.path}.bak.tmp');
        _writeString(backup, previous);
        await backup.rename('${file.path}.bak');
      }
    }
    await temporary.rename(file.path);
  }

  Future<T?> _readRecord<T>(
    File file,
    T Function(Map<String, dynamic>) decode,
  ) async {
    // 已提交的正式文件优先，其次是旧记录，最后才是首次写入的临时文件。
    for (final candidate in [
      file,
      File('${file.path}.bak'),
      File('${file.path}.tmp'),
    ]) {
      if (!candidate.existsSync()) continue;
      late final String contents;
      late final T record;
      try {
        contents = candidate.readAsStringSync();
        record = decode(jsonDecode(contents) as Map<String, dynamic>);
      } catch (error, stack) {
        _onReadError?.call(candidate.path, error, stack);
        continue;
      }
      if (candidate.path != file.path) {
        try {
          final recovery = File('${file.path}.recover');
          _writeString(recovery, contents);
          await recovery.rename(file.path);
        } catch (error, stack) {
          // 可读记录仍可用于恢复队列，但不能把落盘失败伪装成成功。
          _onReadError?.call(file.path, error, stack);
        }
      }
      return record;
    }
    return null;
  }

  Future<void> remove(BiliDownloadEntryInfo entry) =>
      _lock.synchronized(() async {
        final pageDir = Directory(entry.pageDirPath);
        if (!pageDir.existsSync()) return;
        if (!await pageDir.lengthGte(2)) {
          await pageDir.tryDel(recursive: true);
        } else {
          final entryDir = Directory(entry.entryDirPath);
          if (entryDir.existsSync()) {
            await entryDir.tryDel(recursive: true);
          }
        }
      });

  Future<void> removePage(String pageDirPath) => _lock.synchronized(
    () => Directory(pageDirPath).tryDel(recursive: true),
  );
}
