import 'package:pili_aurora/models/remote/video/video_detail/page.dart';
import 'package:pili_aurora/models/remote/video/video_detail/data.dart';
import 'package:pili_aurora/models/common/video/video_quality.dart';
import 'package:pili_aurora/models/common/video/audio_quality.dart';

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/models/remote/download/bili_download_entry_info.dart';
import 'package:pili_aurora/models/remote/download/bili_download_media_file_info.dart';
import 'package:pili_aurora/services/download/download_repository.dart';
import 'package:pili_aurora/services/download/download_service.dart';
import 'package:pili_aurora/utils/path_utils.dart';
import 'package:path/path.dart' as path;

import 'download_fixtures.dart';

class _SchedulingDownloadService extends DownloadService {
  _SchedulingDownloadService({
    required super.repository,
    required super.downloadClient,
  });

  final started = <int>[];

  @override
  Future<void> startDownload(BiliDownloadEntryInfo entry) async {
    started.add(entry.cid);
  }
}

class _MediaAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromBytes(
    [1, 2, 3],
    200,
    headers: {
      'content-length': ['3'],
    },
  );

  @override
  void close({bool force = false}) {}
}

class _PendingCommitRepository extends DownloadRepository {
  _PendingCommitRepository({required super.rootPath});
  final committed = Completer<void>();
  final release = Completer<void>();

  @override
  Future<String> saveMediaInfo(
    BiliDownloadEntryInfo entry,
    BiliDownloadMediaInfo media,
  ) async {
    final result = await super.saveMediaInfo(entry, media);
    committed.complete();
    await release.future;
    return result;
  }
}

class _BarrierRepository extends DownloadRepository {
  _BarrierRepository({required super.rootPath});
  final gate = Completer<void>();
  final finished = Completer<void>();
  int count = 0;
  @override
  Future<void> create(BiliDownloadEntryInfo entry) async {
    count++;
    await gate.future;
    await super.create(entry);
    if (!finished.isCompleted) finished.complete();
  }
}

void main() {
  late Directory directory;
  late DownloadRepository repository;
  late DownloadService service;
  late Dio client;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('pili-download-service-');
    repository = DownloadRepository(rootPath: () => directory.path);
    client = Dio();
    service = DownloadService(repository: repository, downloadClient: client);
  });

  tearDown(() async {
    client.close(force: true);
    await directory.delete(recursive: true);
  });

  Future<void> reload() async {
    service.initDownloadList();
    await service.waitForInitialization;
  }

  test('持久化期间同一 CID 仅创建一次', () async {
    final repo = _BarrierRepository(rootPath: () => directory.path);
    final pending = _SchedulingDownloadService(
      repository: repo,
      downloadClient: client,
    );
    final video = VideoDetailData(
      aid: 1,
      bvid: 'BV-test',
      title: 'test',
      pic: 'https://example.test/cover.jpg',
    );
    for (var i = 0; i < 2; i++) {
      pending.downloadVideo(
        Part(cid: 11, page: 1, duration: 60),
        video,
        null,
        VideoQuality.high1080,
        AudioQuality.k192,
      );
    }
    repo.gate.complete();
    await repo.finished.future;
    await Future<void>.delayed(Duration.zero);
    expect(pending.waitDownloadQueue, hasLength(1));
    expect(repo.count, 1);
  });

  for (final status in [
    DownloadStatus.getDanmaku,
    DownloadStatus.getPlayUrl,
    DownloadStatus.audioDownloading,
  ]) {
    test('删除 $status 当前任务后继续调度', () async {
      final entry = downloadEntry()..status = status;
      final next = downloadEntry(cid: 22);
      final pending = _SchedulingDownloadService(
        repository: repository,
        downloadClient: client,
      );
      await repository.create(entry);
      pending.waitDownloadQueue.addAll([entry, next]);
      pending.curDownload.value = entry;
      await pending.deleteDownload(
        entry: entry,
        removeQueue: true,
        downloadNext: entry.status.isDownloading,
      );
      expect(pending.started, [22]);
      expect(pending.curDownload.value, isNull);
    });
  }

  test('暂停不等待准备阶段网络请求', () async {
    final entry = downloadEntry();
    await repository.create(entry);
    final started = Completer<void>();
    final preparation = Completer<List<int>>();
    final pending = DownloadService(
      repository: repository,
      downloadClient: client,
      prepareDanmaku: (_) {
        started.complete();
        return preparation.future;
      },
    );
    pending.waitDownloadQueue.add(entry);
    final start = pending.startDownload(entry);
    await started.future;
    final cancel = pending.cancelDownload(isDelete: false, downloadNext: false);
    try {
      await cancel.timeout(const Duration(milliseconds: 200));
      expect(entry.status, DownloadStatus.pause);
    } finally {
      preparation.complete([]);
      await start;
      await cancel;
    }
  });

  test('删除后旧准备结果不能重建下载文件', () async {
    final entry = downloadEntry();
    await repository.create(entry);
    final started = Completer<void>();
    final preparation = Completer<List<int>>();
    final pending = DownloadService(
      repository: repository,
      downloadClient: client,
      prepareDanmaku: (_) {
        started.complete();
        return preparation.future;
      },
    );
    pending.waitDownloadQueue.add(entry);
    final start = pending.startDownload(entry);
    await started.future;
    await pending.deleteDownload(
      entry: entry,
      removeQueue: true,
      downloadNext: false,
    );
    preparation.complete([1, 2, 3]);
    await start;
    expect(Directory(entry.entryDirPath).existsSync(), false);
  });

  test('暂停播放地址请求后旧结果不能修改记录或提交媒体索引', () async {
    final entry = downloadEntry();
    await repository.create(entry);
    await File(path.join(entry.entryDirPath, PathUtils.danmakuName))
        .writeAsBytes([]);
    final started = Completer<void>();
    final media = Completer<BiliDownloadMediaInfo>();
    final pending = DownloadService(
      repository: repository,
      downloadClient: client,
      prepareMedia: (snapshot) {
        snapshot.typeTag = '999';
        started.complete();
        return media.future;
      },
    );
    pending.waitDownloadQueue.add(entry);
    final start = pending.startDownload(entry);
    await started.future;
    await pending.cancelDownload(isDelete: false, downloadNext: false);
    media.complete(Type2(duration: 60, video: [], audio: []));
    await start;
    expect(entry.status, DownloadStatus.pause);
    expect(entry.typeTag, '80');
    expect(Directory(path.join(entry.entryDirPath, '999')).existsSync(), false);
  });

  test('准备完成后提交媒体信息并正常完成下载', () async {
    final entry = downloadEntry();
    await repository.create(entry);
    await File(path.join(entry.entryDirPath, PathUtils.danmakuName))
        .writeAsBytes([]);
    await File(path.join(entry.entryDirPath, PathUtils.coverName))
        .writeAsBytes([]);
    client.httpClientAdapter = _MediaAdapter();
    final pending = DownloadService(
      repository: repository,
      downloadClient: client,
      prepareMedia: (snapshot) async {
        snapshot
          ..mediaType = 2
          ..typeTag = '64'
          ..videoQuality = 64;
        return Type2(
          video: [
            Type2File(
              id: 64,
              baseUrl: 'https://example.test/video',
              bandwidth: 1,
              codecid: 1,
              size: 3,
              md5: '',
              noRexcode: false,
              width: 1920,
              height: 1080,
            ),
          ],
        );
      },
    );
    pending.waitDownloadQueue.add(entry);
    await pending.startDownload(entry);
    await Future<void>(() async {
      while (pending.downloadList.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
    }).timeout(const Duration(seconds: 5));
    expect(entry.isCompleted, true);
    expect(entry.typeTag, '64');
    expect(entry.pageData!.width, 1920);
    expect(
      await File(path.join(entry.entryDirPath, '64', PathUtils.videoNameType2))
          .readAsBytes(),
      [1, 2, 3],
    );
    expect((await repository.load()).single.isCompleted, true);
  });

  test('删除等待已开始的文件提交结束，随后清理目录', () async {
    final entry = downloadEntry();
    final pendingRepository = _PendingCommitRepository(
      rootPath: () => directory.path,
    );
    await pendingRepository.create(entry);
    await File(path.join(entry.entryDirPath, PathUtils.danmakuName))
        .writeAsBytes([]);
    await File(path.join(entry.entryDirPath, PathUtils.coverName))
        .writeAsBytes([]);
    client.httpClientAdapter = _MediaAdapter();
    final pending = DownloadService(
      repository: pendingRepository,
      downloadClient: client,
      prepareMedia: (_) async => Type2(
        video: [
          Type2File(
            id: 80,
            baseUrl: 'https://example.test/video',
            bandwidth: 1,
            codecid: 1,
            size: 3,
            md5: '',
            noRexcode: false,
          ),
        ],
      ),
    );
    pending.waitDownloadQueue.add(entry);
    final start = pending.startDownload(entry);
    await pendingRepository.committed.future;
    var deleted = false;
    final deletion = pending
        .deleteDownload(entry: entry, removeQueue: true, downloadNext: false)
        .then((_) => deleted = true);
    await Future<void>.delayed(Duration.zero);
    expect(deleted, false);
    pendingRepository.release.complete();
    await start;
    await deletion;
    expect(Directory(entry.entryDirPath).existsSync(), false);
  });

  test('切换任务后旧准备错误不改变新任务状态', () async {
    final oldEntry = downloadEntry();
    final newEntry = downloadEntry(cid: 22);
    await repository.create(oldEntry);
    await repository.create(newEntry);
    final pendingRequests = <int, Completer<List<int>>>{};
    final pending = DownloadService(
      repository: repository,
      downloadClient: client,
      prepareDanmaku: (entry) =>
          (pendingRequests[entry.cid] = Completer<List<int>>()).future,
    );
    pending.waitDownloadQueue.addAll([oldEntry, newEntry]);
    final oldStart = pending.startDownload(oldEntry);
    while (!pendingRequests.containsKey(oldEntry.cid)) {
      await Future<void>.delayed(Duration.zero);
    }
    final newStart = pending.startDownload(newEntry);
    while (!pendingRequests.containsKey(newEntry.cid)) {
      await Future<void>.delayed(Duration.zero);
    }
    pendingRequests[oldEntry.cid]!.completeError(StateError('旧请求失败'));
    await oldStart;
    expect(pending.curDownload.value, same(newEntry));
    expect(newEntry.status, DownloadStatus.getDanmaku);
    await pending.cancelDownload(isDelete: false, downloadNext: false);
    pendingRequests[newEntry.cid]!.complete([]);
    await newStart;
    expect(newEntry.status, DownloadStatus.pause);
  });

  test(
    'restores completed records in reverse update order and queues pending',
    () async {
      await repository.create(downloadEntry(completed: true, updatedAt: 1));
      await repository.create(
        downloadEntry(cid: 22, completed: true, updatedAt: 3),
      );
      await repository.create(downloadEntry(cid: 33));
      await reload();
      expect(service.downloadList.map((entry) => entry.cid), [22, 11]);
      expect(service.waitDownloadQueue.map((entry) => entry.cid), [33]);
      expect(service.waitDownloadQueue.single.status, DownloadStatus.wait);
      expect(service.curDownload.value, isNull);
    },
  );

  test(
    'reloading replaces the snapshot instead of duplicating pending tasks',
    () async {
      final entry = downloadEntry();
      await repository.create(entry);
      await reload();
      await reload();
      expect(service.waitDownloadQueue, hasLength(1));
      entry.isCompleted = true;
      await repository.save(entry);
      await reload();
      expect(service.waitDownloadQueue, isEmpty);
      expect(service.downloadList, hasLength(1));
    },
  );

  test(
    'reloading preserves the identity and state of an active task',
    () async {
      await repository.create(downloadEntry());
      await reload();
      final current = service.waitDownloadQueue.single
        ..status = DownloadStatus.downloading
        ..downloadedBytes = 42;
      service.curDownload.value = current;
      await reload();
      expect(service.waitDownloadQueue.single, same(current));
      expect(service.waitDownloadQueue.single.downloadedBytes, 42);
      expect(
        service.waitDownloadQueue.single.status,
        DownloadStatus.downloading,
      );
    },
  );

  test(
    'removing a completed task delegates storage without touching siblings',
    () async {
      await repository.create(downloadEntry(completed: true));
      await repository.create(downloadEntry(cid: 22, completed: true));
      await reload();
      final removed = service.downloadList.firstWhere(
        (entry) => entry.cid == 11,
      );
      await service.deleteDownload(entry: removed, removeList: true);
      expect(service.downloadList.map((entry) => entry.cid), [22]);
      expect((await repository.load()).map((entry) => entry.cid), [22]);
    },
  );

  test('删除当前下载组后继续调度其他组', () async {
    final active = downloadEntry()..status = DownloadStatus.downloading;
    final sibling = downloadEntry(cid: 12);
    final remaining = downloadEntry(aid: 2, cid: 22);
    await repository.create(active);
    await repository.create(sibling);
    await repository.create(remaining);
    final schedulingService = _SchedulingDownloadService(
      repository: repository,
      downloadClient: client,
    );
    schedulingService.waitDownloadQueue.addAll([active, sibling, remaining]);
    schedulingService.curDownload.value = active;

    await schedulingService.deletePage(pageDirPath: active.pageDirPath);

    expect(schedulingService.waitDownloadQueue.map((entry) => entry.cid), [22]);
    expect(schedulingService.started, [22]);
    expect((await repository.load()).map((entry) => entry.cid), [22]);
  });

  test('删除其他下载组时保留当前任务', () async {
    final active = downloadEntry()..status = DownloadStatus.downloading;
    final removed = downloadEntry(aid: 2, cid: 22, completed: true);
    await repository.create(active);
    await repository.create(removed);
    final schedulingService = _SchedulingDownloadService(
      repository: repository,
      downloadClient: client,
    );
    schedulingService.waitDownloadQueue.add(active);
    schedulingService.curDownload.value = active;

    await schedulingService.deletePage(pageDirPath: removed.pageDirPath);

    expect(schedulingService.curDownload.value, same(active));
    expect(schedulingService.started, isEmpty);
    expect((await repository.load()).map((entry) => entry.cid), [11]);
  });
}
