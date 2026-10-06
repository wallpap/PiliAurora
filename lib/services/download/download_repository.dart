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
        if (!file.existsSync()) continue;
        try {
          entries.add(
            BiliDownloadEntryInfo.fromJson(
                jsonDecode(await file.readAsString()) as Map<String, dynamic>,
              )
              ..pageDirPath = pageDir.path
              ..entryDirPath = entryDir.path,
          );
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
    return _lock.synchronized(() async {
      await file.writeAsString(contents);
    });
  }

  Future<String> saveMediaInfo(
    BiliDownloadEntryInfo entry,
    BiliDownloadMediaInfo media,
  ) async {
    final contents = jsonEncode(media.toJson());
    final directory = Directory(path.join(entry.entryDirPath, entry.typeTag));
    await _lock.synchronized(() async {
      await directory.create(recursive: true);
      await File(path.join(directory.path, _indexFile)).writeAsString(contents);
    });
    return directory.path;
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
