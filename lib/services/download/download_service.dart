import 'dart:async';
import 'dart:io' show Directory, File;

import 'package:pili_aurora/grpc/dm.dart';
import 'package:pili_aurora/http/download.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/common/video/audio_quality.dart';
import 'package:pili_aurora/models/common/video/video_quality.dart';
import 'package:pili_aurora/models/remote/download/bili_download_entry_info.dart';
import 'package:pili_aurora/models/remote/download/bili_download_media_file_info.dart';
import 'package:pili_aurora/models/remote/pgc/pgc_info_model/episode.dart'
    as pgc;
import 'package:pili_aurora/models/remote/pgc/pgc_info_model/result.dart';
import 'package:pili_aurora/models/remote/video/video_detail/data.dart';
import 'package:pili_aurora/models/remote/video/video_detail/episode.dart'
    as ugc;
import 'package:pili_aurora/models/remote/video/video_detail/page.dart';
import 'package:pili_aurora/services/download/download_manager.dart';
import 'package:pili_aurora/services/download/download_repository.dart';
import 'package:pili_aurora/services/logger.dart';
import 'package:pili_aurora/utils/cache_manager.dart';
import 'package:pili_aurora/utils/danmaku_utils.dart';
import 'package:pili_aurora/utils/extension/string_ext.dart';
import 'package:pili_aurora/utils/id_utils.dart';
import 'package:pili_aurora/utils/path_utils.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:path/path.dart' as path;
import 'package:synchronized/synchronized.dart';

// ref https://github.com/10miaomiao/bilimiao2/blob/master/bilimiao-download/src/main/java/cn/a10miaomiao/bilimiao/download/DownloadService.kt

/// 已被暂停、切源或较新操作取代；调用方无需提示用户重试。
class DownloadCancelled extends Error {
  const DownloadCancelled() : super('下载操作已取消');
}

/// 管理下载记录、待下载队列和当前任务；DASH 的音视频流可并行传输。
///
/// 目录与 JSON 由 [DownloadRepository] 管理，单路媒体传输由
/// [DownloadManager] 管理。服务只维护一个当前下载项及其可选的音频任务。
class DownloadService extends GetxService {
  DownloadService({
    required this._repository,
    required this._downloadClient,
    @visibleForTesting
    Future<List<int>> Function(BiliDownloadEntryInfo)? prepareDanmaku,
    @visibleForTesting
    Future<BiliDownloadMediaInfo> Function(BiliDownloadEntryInfo)? prepareMedia,
  }) : _prepareDanmakuOverride = prepareDanmaku,
       _prepareMediaOverride = prepareMedia;

  final DownloadRepository _repository;
  final Dio _downloadClient;
  final Future<List<int>> Function(BiliDownloadEntryInfo)?
  _prepareDanmakuOverride;
  final Future<BiliDownloadMediaInfo> Function(BiliDownloadEntryInfo)?
  _prepareMediaOverride;
  static const _maxDanmakuConcurrency = 4;

  final _lock = Lock();
  final _creatingCids = <int>{};
  final _danmakuOperations = <String, Object>{};
  Object? _operation;
  int _initializationGeneration = 0;
  final initializationState = Rx<LoadingState<void>>(LoadingState.loading());

  final flagNotifier = SetNotifier();
  final waitDownloadQueue = RxList<BiliDownloadEntryInfo>();
  final downloadList = <BiliDownloadEntryInfo>[];

  int? _curCid;
  int? get curCid => _curCid;
  final curDownload = Rxn<BiliDownloadEntryInfo>();
  void _updateCurStatus(DownloadStatus status) {
    if (curDownload.value != null) {
      curDownload
        ..value!.status = status
        ..refresh();
    }
  }

  DownloadManager? _downloadManager;
  DownloadManager? _audioDownloadManager;
  final _completing = <BiliDownloadEntryInfo>{};

  void _saveProgress(BiliDownloadEntryInfo entry) {
    unawaited(
      _repository.save(entry).catchError((Object error, StackTrace stack) {
        logger.e('下载进度保存失败', error: error.runtimeType, stackTrace: stack);
        SmartDialog.showToast('下载进度保存失败，请检查磁盘空间和目录权限');
      }),
    );
  }

  /// 初始化与重读均返回结果；失败保留旧服务快照，由页面显示重试入口。
  late Future<LoadingState<void>> waitForInitialization;

  @override
  void onInit() {
    super.onInit();
    initDownloadList();
  }

  Future<LoadingState<void>> initDownloadList() {
    final generation = ++_initializationGeneration;
    initializationState.value = LoadingState.loading();
    return waitForInitialization = _readDownloadList(generation);
  }

  Future<LoadingState<void>> _readDownloadList(int generation) async {
    try {
      return await _lock.synchronized(() async {
        final entries = await _repository.load();
        for (final entry in entries.where((entry) => !entry.isCompleted)) {
          final name = entry.mediaType == 1
              ? PathUtils.videoNameType1
              : PathUtils.videoNameType2;
          final file = File(path.join(entry.entryDirPath, entry.typeTag, name));
          // 续传以真实文件长度为准，进程异常退出不依赖最后一次 UI 进度。
          entry.downloadedBytes = file.existsSync() ? file.lengthSync() : 0;
        }
        if (generation != _initializationGeneration) {
          return const DownloadCancelled();
        }
        final pending = entries.where((entry) => !entry.isCompleted).toList();
        var current = curDownload.value;
        if (current != null &&
            !pending.any(
              (entry) => entry.entryDirPath == current!.entryDirPath,
            )) {
          await _cancelCurrent(isDelete: false, downloadNext: false);
          if (generation != _initializationGeneration) {
            return const DownloadCancelled();
          }
          _curCid = null;
          curDownload.value = null;
          current = null;
        }
        downloadList
          ..clear()
          ..addAll(entries.where((entry) => entry.isCompleted))
          ..sort((a, b) => b.timeUpdateStamp.compareTo(a.timeUpdateStamp));
        // 同一目录重读复用当前对象；新目录不能继承同 CID 的旧任务状态。
        waitDownloadQueue.assignAll(
          pending.map(
            (entry) =>
                current?.entryDirPath == entry.entryDirPath ? current! : entry,
          ),
        );
        initializationState.value = const Success(null);
        _publishDeletion(true);
        return const Success<void>(null);
      });
    } catch (error, stack) {
      final result = _failure('下载记录读取失败，请检查目录权限后重试', error, stack);
      if (generation == _initializationGeneration) {
        initializationState.value = result;
        _publishDeletion(true);
      }
      return result;
    }
  }

  Error _failure(String message, Object error, StackTrace stack) {
    logger.e(message, error: error.runtimeType, stackTrace: stack);
    return Error(message, cause: error, stackTrace: stack);
  }

  Future<LoadingState<void>> downloadVideo(
    Part page,
    VideoDetailData? videoDetail,
    ugc.EpisodeItem? videoArc,
    VideoQuality videoQuality,
    AudioQuality audioQuality,
  ) async {
    try {
      final cid = page.cid!;
      final pageData = PageInfo(
        cid: cid,
        page: page.page!,
        from: page.from,
        part: page.part,
        vid: page.vid,
        hasAlias: false,
        tid: 0,
        width: 0,
        height: 0,
        rotate: 0,
        downloadTitle: '视频已缓存完成',
        downloadSubtitle: videoDetail?.title ?? videoArc!.title,
      );
      final currentTime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final entry = BiliDownloadEntryInfo(
        mediaType: 2,
        hasDashAudio: false,
        isCompleted: false,
        totalBytes: 0,
        downloadedBytes: 0,
        title: videoDetail?.title ?? videoArc!.title!,
        typeTag: videoQuality.code.toString(),
        cover: (videoDetail?.pic ?? videoArc!.cover!).http2https,
        preferedVideoQuality: videoQuality.code,
        preferredAudioQuality: audioQuality.code,
        qualityPithyDescription: videoQuality.desc,
        guessedTotalBytes: 0,
        totalTimeMilli: (page.duration ?? 0) * 1000,
        danmakuCount:
            videoDetail?.stat?.danmaku ?? videoArc?.arc?.stat?.danmaku ?? 0,
        timeUpdateStamp: currentTime,
        timeCreateStamp: currentTime,
        canPlayInAdvance: true,
        interruptTransformTempFile: false,
        avid: videoDetail?.aid ?? videoArc!.aid!,
        spid: 0,
        seasonId: null,
        ep: null,
        source: null,
        bvid: videoDetail?.bvid ?? videoArc!.bvid!,
        ownerId: videoDetail?.owner?.mid ?? videoArc?.arc?.author?.mid,
        ownerName: videoDetail?.owner?.name ?? videoArc?.arc?.author?.name,
        pageData: pageData,
      );
      return await _createDownload(entry);
    } catch (error, stack) {
      return _failure('创建下载失败，请检查视频信息后重试', error, stack);
    }
  }

  Future<LoadingState<void>> downloadBangumi(
    int index,
    PgcInfoModel pgcItem,
    pgc.EpisodeItem episode,
    VideoQuality quality,
    AudioQuality audioQuality,
  ) async {
    try {
      final cid = episode.cid!;
      final currentTime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final source = SourceInfo(
        avId: episode.aid!,
        cid: cid,
      );
      final ep = EpInfo(
        avId: source.avId,
        page: index,
        danmaku: source.cid,
        cover: episode.cover!,
        episodeId: episode.id!,
        index: episode.title!,
        indexTitle: episode.longTitle ?? '',
        showTitle: episode.showTitle,
        from: episode.from ?? 'bangumi',
        seasonType: pgcItem.type ?? (episode.from == 'pugv' ? -1 : 0),
        width: 0,
        height: 0,
        rotate: 0,
        link: episode.link ?? '',
        bvid: episode.bvid ?? IdUtils.av2bv(source.avId),
        sortIndex: index,
      );
      final entry = BiliDownloadEntryInfo(
        mediaType: 2,
        hasDashAudio: false,
        isCompleted: false,
        totalBytes: 0,
        downloadedBytes: 0,
        title: pgcItem.seasonTitle ?? pgcItem.title ?? '',
        typeTag: quality.code.toString(),
        cover: episode.cover!,
        preferedVideoQuality: quality.code,
        preferredAudioQuality: audioQuality.code,
        qualityPithyDescription: quality.desc,
        guessedTotalBytes: 0,
        totalTimeMilli:
            (episode.duration ?? 0) *
            (episode.from == 'pugv' ? 1000 : 1), // pgc millisec,, pugv sec
        danmakuCount: pgcItem.stat?.danmaku ?? 0,
        timeUpdateStamp: currentTime,
        timeCreateStamp: currentTime,
        canPlayInAdvance: true,
        interruptTransformTempFile: false,
        spid: 0,
        seasonId: pgcItem.seasonId!.toString(),
        bvid: episode.bvid ?? IdUtils.av2bv(source.avId),
        avid: source.avId,
        ep: ep,
        source: source,
        ownerId: pgcItem.upInfo?.mid,
        ownerName: pgcItem.upInfo?.uname,
        pageData: null,
      );
      return await _createDownload(entry);
    } catch (error, stack) {
      return _failure('创建下载失败，请检查剧集信息后重试', error, stack);
    }
  }

  Future<LoadingState<void>> _createDownload(
    BiliDownloadEntryInfo entry,
  ) async {
    if (_initializationGeneration > 0 && !initializationState.value.isSuccess) {
      return const Error('下载记录尚未读取成功，请先重试');
    }
    final generation = _initializationGeneration;
    final cid = entry.cid;
    if (_creatingCids.contains(cid)) return const Error('下载任务正在创建，请稍后查看');
    if (downloadList.any((e) => e.cid == cid) ||
        waitDownloadQueue.any((e) => e.cid == cid)) {
      return const Success(null);
    }
    // 在首次 await 前预留 CID，持久化失败时释放以允许重试。
    _creatingCids.add(cid);
    try {
      return await _lock.synchronized(() async {
        if (generation != _initializationGeneration) {
          return const DownloadCancelled();
        }
        await _repository.create(entry);
        if (generation != _initializationGeneration) {
          return const DownloadCancelled();
        }
        entry.status = DownloadStatus.wait;
        waitDownloadQueue.add(entry);
        if (curDownload.value?.status.isDownloading != true) {
          unawaited(_startAndNotify(entry));
        }
        return const Success<void>(null);
      });
    } catch (error, stackTrace) {
      return _failure('创建下载失败，请检查磁盘或目录权限后重试', error, stackTrace);
    } finally {
      _creatingCids.remove(cid);
    }
  }

  /// 成功表示准备完成并启动传输，最终完成状态由当前任务与列表通知交付。
  Future<LoadingState<void>> startDownload(BiliDownloadEntryInfo entry) async {
    try {
      if (_initializationGeneration > 0 &&
          !initializationState.value.isSuccess) {
        return const Error('下载记录尚未读取成功，请先重试');
      }
      final operation = await _lock.synchronized(() async {
        if (entry.isCompleted || !waitDownloadQueue.contains(entry)) {
          return null;
        }
        _operation = null;
        // 切换当前项前等待旧音视频流退出，避免两个任务同时写入同一状态。
        await _downloadManager?.cancel(isDelete: false);
        await _audioDownloadManager?.cancel(isDelete: false);
        _downloadManager = null;
        _audioDownloadManager = null;
        if (curDownload.value case final curEntry?) {
          if (curEntry.status.isDownloading) {
            _updateCurStatus(DownloadStatus.pause);
          }
          await _repository.save(curEntry);
        }

        _curCid = entry.cid;
        curDownload.value = entry;
        waitDownloadQueue.refresh();
        final operation = Object();
        _operation = operation;
        return operation;
      });
      if (operation == null) return const DownloadCancelled();
      final result = await _startDownload(entry, operation);
      if (!result.isSuccess) return result;
      if (!_owns(operation) && !entry.isCompleted) {
        return const DownloadCancelled();
      }
      return const Success(null);
    } catch (error, stack) {
      return _failure('下载任务启动失败，请检查目录后重试', error, stack);
    }
  }

  Future<void> _startAndNotify(BiliDownloadEntryInfo entry) async {
    final before = curDownload.value;
    final result = await startDownload(entry);
    if (!result.isSuccess &&
        result is! DownloadCancelled &&
        (identical(curDownload.value, entry) ||
            identical(curDownload.value, before))) {
      result.toast();
    }
  }

  bool _owns(Object operation) => identical(_operation, operation);

  Future<List<int>> _fetchDanmaku(
    BiliDownloadEntryInfo entry,
    bool Function() isActive,
  ) async {
    if (_prepareDanmakuOverride case final prepare?) return prepare(entry);
    final seg = (entry.totalTimeMilli / DmUtils.segLength).ceil();
    if (seg <= 0) throw StateError('Invalid danmaku segment count: $seg');
    final danmaku = (await DmGrpc.dmSegMobile(
      cid: entry.cid,
      segmentIndex: 1,
    )).data;
    for (
      var start = 2;
      start <= seg && isActive();
      start += _maxDanmakuConcurrency
    ) {
      final end = start + _maxDanmakuConcurrency - 1;
      final responses = await Future.wait([
        for (var index = start; index <= seg && index <= end; index++)
          DmGrpc.dmSegMobile(cid: entry.cid, segmentIndex: index),
      ]);
      for (final response in responses) {
        danmaku.elems.addAll(response.data.elems);
      }
    }
    return danmaku.writeToBuffer();
  }

  Future<LoadingState<void>> downloadDanmaku({
    required BiliDownloadEntryInfo entry,
    bool isUpdate = false,
  }) async {
    String? entryPath;
    final token = Object();
    final generation = _initializationGeneration;
    try {
      if (_initializationGeneration > 0 &&
          (!initializationState.value.isSuccess ||
              !(downloadList.contains(entry) ||
                  waitDownloadQueue.contains(entry)))) {
        return const Error('下载记录已变化，请重新读取后重试');
      }
      final cid = entry.pageData?.cid ?? entry.source?.cid;
      if (cid == null) return const Error('下载记录缺少弹幕信息');
      entryPath = entry.entryDirPath;
      _danmakuOperations[entryPath] = token;
      final danmakuFile = File(
        path.join(entry.entryDirPath, PathUtils.danmakuName),
      );
      if (isUpdate || !danmakuFile.existsSync()) {
        if (!isUpdate && identical(curDownload.value, entry)) {
          _updateCurStatus(DownloadStatus.getDanmaku);
        }
        bool active() =>
            generation == _initializationGeneration &&
            identical(_danmakuOperations[entryPath], token) &&
            entry.entryDirPath == entryPath &&
            Directory(entryPath!).existsSync();
        final bytes = await _fetchDanmaku(entry, active);
        return await _lock.synchronized(() async {
          if (!active()) return const DownloadCancelled();
          await _writeDanmaku(danmakuFile, bytes);
          return const Success<void>(null);
        });
      }
      return const Success(null);
    } catch (error, stack) {
      if (generation != _initializationGeneration ||
          (entryPath != null &&
              !identical(_danmakuOperations[entryPath], token))) {
        return const DownloadCancelled();
      }
      if (!isUpdate && identical(curDownload.value, entry)) {
        _updateCurStatus(DownloadStatus.failDanmaku);
      }
      return _failure('弹幕更新失败，请检查网络或目录权限后重试', error, stack);
    } finally {
      if (identical(_danmakuOperations[entryPath], token)) {
        _danmakuOperations.remove(entryPath);
      }
    }
  }

  Future<void> _writeDanmaku(File target, List<int> bytes) async {
    final temporary = File('${target.path}.tmp');
    try {
      // 写完后再替换，失败时保留上次可用的弹幕文件。
      await temporary.writeAsBytes(bytes, flush: true);
      await temporary.rename(target.path);
    } catch (_) {
      try {
        if (temporary.existsSync()) await temporary.delete();
      } catch (_) {}
      rethrow;
    }
  }

  Future<File?> _fetchCover(BiliDownloadEntryInfo entry) async {
    try {
      final filePath = path.join(entry.entryDirPath, PathUtils.coverName);
      if (File(filePath).existsSync()) {
        return null;
      }
      return await CacheManager.manager.getSingleFile(entry.cover);
    } catch (_) {
      return null;
    }
  }

  Future<LoadingState<void>> _startDownload(
    BiliDownloadEntryInfo entry,
    Object operation,
  ) async {
    if (!_owns(operation)) return const DownloadCancelled();
    try {
      final danmakuFile = File(
        path.join(entry.entryDirPath, PathUtils.danmakuName),
      );
      if (!danmakuFile.existsSync()) {
        _updateCurStatus(DownloadStatus.getDanmaku);
        try {
          final bytes = await _fetchDanmaku(entry, () => _owns(operation));
          await _lock.synchronized(() async {
            if (_owns(operation) && !danmakuFile.existsSync()) {
              await _writeDanmaku(danmakuFile, bytes);
            }
          });
        } catch (error, stack) {
          if (!_owns(operation)) return const DownloadCancelled();
          if (_owns(operation)) {
            _updateCurStatus(DownloadStatus.failDanmaku);
          }
          return _failure('弹幕准备失败，请检查网络或目录权限后重试', error, stack);
        }
      }
      if (!_owns(operation)) return const DownloadCancelled();
      _updateCurStatus(DownloadStatus.getPlayUrl);
      // 地址解析会修改画质字段；旧请求只能修改自己的快照。
      final snapshot = BiliDownloadEntryInfo.fromJson(entry.toJson())
        ..pageDirPath = entry.pageDirPath
        ..entryDirPath = entry.entryDirPath;
      final mediaFileInfo =
          await (_prepareMediaOverride?.call(snapshot) ??
              DownloadHttp.getVideoUrl(
                entry: snapshot,
                preferredAudioQuality: snapshot.preferredAudioQuality,
                ep: snapshot.ep,
                source: snapshot.source,
                pageData: snapshot.pageData,
              ));
      if (!_owns(operation)) return const DownloadCancelled();
      final cover = await _fetchCover(snapshot);
      await _lock.synchronized(() async {
        if (!_owns(operation)) return;
        entry
          ..mediaType = snapshot.mediaType
          ..hasDashAudio = snapshot.hasDashAudio
          ..typeTag = snapshot.typeTag
          ..videoQuality = snapshot.videoQuality
          ..preferedVideoQuality = snapshot.preferedVideoQuality
          ..qualityPithyDescription = snapshot.qualityPithyDescription;
        final videoDir = await _repository.saveMediaInfo(entry, mediaFileInfo);
        if (cover != null) {
          try {
            await cover.copy(
              path.join(entry.entryDirPath, PathUtils.coverName),
            );
          } catch (_) {
            // 封面失败不阻止媒体下载。
          }
        }

        if (mediaFileInfo is Type2) {
          final first = mediaFileInfo.video.first;
          entry.pageData
            ?..width = first.width
            ..height = first.height;
          entry.ep
            ?..width = first.width
            ..height = first.height;
        }
        await _repository.save(entry);

        switch (mediaFileInfo) {
          case Type1 mediaFileInfo:
            final first = mediaFileInfo.segmentList.first;
            _downloadManager = DownloadManager(
              client: _downloadClient,
              url: first.url,
              path: path.join(videoDir, PathUtils.videoNameType1),
              onReceiveProgress: (progress, total) {
                if (_owns(operation)) _onReceive(progress, total);
              },
              onDone: ([error]) {
                if (_owns(operation)) _onDone(operation, error);
              },
            );
            break;
          case Type2 mediaFileInfo:
            // DASH 音视频使用独立文件与传输器，构造后会各自开始流式下载。
            _downloadManager = DownloadManager(
              client: _downloadClient,
              url: mediaFileInfo.video.first.baseUrl,
              path: path.join(videoDir, PathUtils.videoNameType2),
              onReceiveProgress: (progress, total) {
                if (_owns(operation)) _onReceive(progress, total);
              },
              onDone: ([error]) {
                if (_owns(operation)) _onDone(operation, error);
              },
            );
            final audio = mediaFileInfo.audio;
            if (audio != null && audio.isNotEmpty) {
              _audioDownloadManager = DownloadManager(
                client: _downloadClient,
                url: audio.first.baseUrl,
                path: path.join(videoDir, PathUtils.audioNameType2),
                onReceiveProgress: null,
                onDone: ([error]) {
                  if (_owns(operation)) _onAudioDone(operation, error);
                },
              );
            }
            break;
          default:
            break;
        }
      });
      if (!_owns(operation) && !entry.isCompleted) {
        return const DownloadCancelled();
      }
      return const Success(null);
    } catch (error, stack) {
      if (!_owns(operation)) return const DownloadCancelled();
      _updateCurStatus(DownloadStatus.failPlayUrl);
      return _failure('下载准备失败，请检查网络或目录权限后重试', error, stack);
    }
  }

  void _onReceive(int progress, int total) {
    if (curDownload.value case final entry?) {
      entry
        ..downloadedBytes = progress
        ..status = DownloadStatus.downloading;
      if (total > 0 && entry.totalBytes != total) {
        entry.totalBytes = total;
        _saveProgress(entry);
      }
      curDownload.refresh();
    }
  }

  void _onDone(Object operation, [Object? error]) {
    if (error != null) {
      _updateCurStatus(_downloadManager?.status ?? DownloadStatus.pause);
      if (curDownload.value case final entry?) _saveProgress(entry);
      return;
    }

    final status = switch (_audioDownloadManager?.status) {
      DownloadStatus.downloading => DownloadStatus.audioDownloading,
      DownloadStatus.failDownload => DownloadStatus.failDownloadAudio,
      null || DownloadStatus.completed =>
        _downloadManager?.status ?? DownloadStatus.pause,
      _ => DownloadStatus.pause,
    };
    _updateCurStatus(status);

    if (curDownload.value case final curEntryInfo?) {
      curEntryInfo.downloadedBytes = curEntryInfo.totalBytes;
      if (status == DownloadStatus.completed) {
        _completeDownload(operation);
      } else {
        _saveProgress(curEntryInfo);
      }
    }
  }

  void _onAudioDone(Object operation, [Object? error]) {
    if (_downloadManager?.status == DownloadStatus.completed) {
      if (error == null) {
        _completeDownload(operation);
      } else {
        final status = _audioDownloadManager?.status ?? DownloadStatus.pause;
        _updateCurStatus(
          status == DownloadStatus.failDownload
              ? DownloadStatus.failDownloadAudio
              : status,
        );
        if (curDownload.value case final entry?) _saveProgress(entry);
      }
    }
  }

  Future<void> _completeDownload(Object operation) async {
    final entry = curDownload.value;
    if (entry == null || !_completing.add(entry)) {
      return;
    }
    await _lock.synchronized(() async {
      if (!_owns(operation) || !waitDownloadQueue.contains(entry)) {
        _completing.remove(entry);
        return;
      }
      // 视频与可选音轨都完成后才落完成标记，再从待下载队列移除。
      entry
        ..downloadedBytes = entry.totalBytes
        ..isCompleted = true;
      try {
        await _repository.save(entry);
        final queued = waitDownloadQueue.remove(entry);
        if (queued && !downloadList.contains(entry)) {
          downloadList.insert(0, entry);
        }
        _publishDeletion(true);
        // 保存期间可能已切换任务，旧完成回调不能清空新任务。
        if (identical(curDownload.value, entry)) {
          _operation = null;
          _curCid = null;
          curDownload.value = null;
          _downloadManager = null;
          _audioDownloadManager = null;
          nextDownload();
        }
      } catch (error, stack) {
        entry
          ..isCompleted = false
          ..status = DownloadStatus.failDownload;
        curDownload.refresh();
        logger.e('下载完成记录保存失败', error: error.runtimeType, stackTrace: stack);
        SmartDialog.showToast('下载文件已保留，但完成记录保存失败，请检查磁盘后重试');
      } finally {
        _completing.remove(entry);
      }
    });
  }

  void nextDownload() {
    if (waitDownloadQueue.isNotEmpty) {
      unawaited(_startAndNotify(waitDownloadQueue.first));
    }
  }

  Future<LoadingState<void>> deleteDownload({
    required BiliDownloadEntryInfo entry,
    bool removeList = false,
    bool removeQueue = false,
    bool refresh = true,
    bool downloadNext = true,
  }) => _lock.synchronized(() async {
    final current = curDownload.value;
    final isCurrent = current?.entryDirPath == entry.entryDirPath;
    try {
      if (isCurrent) {
        await _cancelCurrent(isDelete: true, downloadNext: false);
        current!.status = DownloadStatus.pause;
      }
      await _repository.remove(entry);
      _danmakuOperations.remove(entry.entryDirPath);
    } catch (error, stack) {
      return _deleteFailure(error, stack);
    }
    if (removeList) {
      downloadList.removeWhere(
        (item) =>
            item.cid == entry.cid && item.entryDirPath == entry.entryDirPath,
      );
    }
    if (removeQueue) {
      waitDownloadQueue.removeWhere(
        (item) =>
            item.cid == entry.cid && item.entryDirPath == entry.entryDirPath,
      );
    }
    _publishDeletion(refresh);
    if (isCurrent && downloadNext) nextDownload();
    return const Success(null);
  });

  Future<LoadingState<void>> deletePage({
    required String pageDirPath,
    bool refresh = true,
  }) => _lock.synchronized(() async {
    final current = curDownload.value;
    final isCurrent = current?.pageDirPath == pageDirPath;
    try {
      if (isCurrent) {
        await _cancelCurrent(isDelete: true, downloadNext: false);
        current!.status = DownloadStatus.pause;
      }
      await _repository.removePage(pageDirPath);
      _danmakuOperations.removeWhere(
        (key, _) => path.dirname(key) == pageDirPath,
      );
    } catch (error, stack) {
      return _deleteFailure(error, stack);
    }
    waitDownloadQueue.removeWhere((entry) => entry.pageDirPath == pageDirPath);
    downloadList.removeWhere((e) => e.pageDirPath == pageDirPath);
    _publishDeletion(refresh);
    if (isCurrent) nextDownload();
    return const Success(null);
  });

  Error _deleteFailure(Object error, StackTrace stack) {
    const message = '删除未完成，请检查文件占用或目录权限后重试';
    logger.e(message, error: error.runtimeType, stackTrace: stack);
    return Error(message, cause: error, stackTrace: stack);
  }

  void _publishDeletion(bool refresh) {
    if (!refresh) return;
    // 文件删除已确认，订阅方错误不能把成功结果改成可重试的删除失败。
    for (final listener in flagNotifier.toList()) {
      try {
        listener();
      } catch (error, stack) {
        logger.e('下载列表刷新失败', error: error.runtimeType, stackTrace: stack);
      }
    }
  }

  Future<LoadingState<void>> cancelDownload({
    required bool isDelete,
    bool downloadNext = true,
  }) => _lock.synchronized(() async {
    try {
      await _cancelCurrent(isDelete: isDelete, downloadNext: downloadNext);
      return const Success(null);
    } catch (error, stack) {
      return _failure('暂停未完成，请检查目录权限后重试', error, stack);
    }
  });

  Future<void> _cancelCurrent({
    required bool isDelete,
    required bool downloadNext,
  }) async {
    _operation = null;
    await _downloadManager?.cancel(isDelete: isDelete);
    await _audioDownloadManager?.cancel(isDelete: isDelete);
    _downloadManager = null;
    _audioDownloadManager = null;
    if (!isDelete) _updateCurStatus(DownloadStatus.pause);
    if (!isDelete) {
      // 暂停保留已写入的字节数，后续由 DownloadManager 发送 Range 请求续传。
      final entry = curDownload.value;
      if (entry != null) {
        await _repository.save(entry);
      }
    }
    if (isDelete) {
      _curCid = null;
      curDownload.value = null;
    } else {
      _updateCurStatus(DownloadStatus.pause);
    }
    if (downloadNext) {
      nextDownload();
    }
  }
}

typedef SetNotifier = Set<VoidCallback>;

extension SetNotifierExt on SetNotifier {
  void refresh() {
    for (final i in this) {
      i();
    }
  }
}
