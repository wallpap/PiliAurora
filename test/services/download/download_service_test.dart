import 'package:pili_aurora/models/remote/video/video_detail/page.dart';
import 'package:pili_aurora/models/remote/video/video_detail/data.dart';
import 'package:pili_aurora/models/common/video/video_quality.dart';
import 'package:pili_aurora/models/common/video/audio_quality.dart';

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/http/loading_state.dart';
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
  Future<LoadingState<void>> startDownload(BiliDownloadEntryInfo entry) async {
    started.add(entry.cid);
    return const Success(null);
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

class _DeletionRepository extends DownloadRepository {
  _DeletionRepository({required super.rootPath});

  final started = Completer<void>();
  final release = Completer<void>();
  Object? failure;

  Future<void> _wait() async {
    if (!started.isCompleted) started.complete();
    await release.future;
    if (failure case final error?) throw error;
  }

  @override
  Future<void> remove(BiliDownloadEntryInfo entry) async {
    await _wait();
    await super.remove(entry);
  }

  @override
  Future<void> removePage(String pageDirPath) async {
    await _wait();
    await super.removePage(pageDirPath);
  }
}

class _ControlledRepository extends DownloadRepository {
  _ControlledRepository({required super.rootPath});
  Future<List<BiliDownloadEntryInfo>> Function()? read;
  Object? saveFailure;

  @override
  Future<List<BiliDownloadEntryInfo>> load() => read?.call() ?? super.load();

  @override
  Future<void> save(BiliDownloadEntryInfo entry) async {
    if (saveFailure case final error?) throw error;
    await super.save(entry);
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

  test('初始化失败返回可诊断结果并可重试，不伪装为空列表', () async {
    const failure = FileSystemException('private-initialization');
    final repo = _ControlledRepository(rootPath: () => directory.path)
      ..read = () async => throw failure;
    final pending = DownloadService(repository: repo, downloadClient: client);
    final old = downloadEntry(completed: true);
    pending.downloadList.add(old);
    final result = await pending.initDownloadList();
    expect(result, isA<Error>());
    expect((result as Error).cause, same(failure));
    expect(result.stackTrace, isNotNull);
    expect(result.toString(), isNot(contains('private-initialization')));
    expect(pending.initializationState.value, same(result));
    expect(pending.downloadList, [old]);
    final fresh = downloadEntry(cid: 22, completed: true);
    repo.read = () async => [fresh];
    expect((await pending.initDownloadList()).isSuccess, true);
    expect(pending.initializationState.value.isSuccess, true);
    expect(pending.downloadList, [fresh]);
  });

  test('目录重读只接受最新快照，旧读取结果不覆盖新目录', () async {
    final reads = <Completer<List<BiliDownloadEntryInfo>>>[];
    final repo = _ControlledRepository(rootPath: () => directory.path)
      ..read = () {
        final reply = Completer<List<BiliDownloadEntryInfo>>();
        reads.add(reply);
        return reply.future;
      };
    final pending = DownloadService(repository: repo, downloadClient: client);
    final old = pending.initDownloadList();
    final fresh = pending.initDownloadList();
    expect(reads, hasLength(1));
    reads[0].complete([downloadEntry(completed: true)]);
    expect(await old, isA<DownloadCancelled>());
    await Future<void>.delayed(Duration.zero);
    final entry = downloadEntry(cid: 22, completed: true);
    reads[1].complete([entry]);
    expect((await fresh).isSuccess, true);
    expect(pending.downloadList, [entry]);
    expect(pending.initializationState.value.isSuccess, true);
  });

  test('切换目录时相同 CID 不继承旧目录的当前任务状态', () async {
    final repo = _ControlledRepository(rootPath: () => directory.path);
    final old = downloadEntry()..status = DownloadStatus.downloading;
    await repo.create(old);
    old.downloadedBytes = 42;
    final fresh = downloadEntry()
      ..pageDirPath = path.join(directory.path, 'new')
      ..entryDirPath = path.join(directory.path, 'new', 'entry');
    repo.read = () async => [fresh];
    final pending = DownloadService(repository: repo, downloadClient: client);
    pending.waitDownloadQueue.add(old);
    pending.curDownload.value = old;
    expect((await pending.initDownloadList()).isSuccess, true);
    expect(old.status, DownloadStatus.pause);
    expect(pending.curDownload.value, isNull);
    expect(pending.curCid, isNull);
    expect(pending.waitDownloadQueue.single, same(fresh));
    expect(fresh.downloadedBytes, 0);
    expect(fresh.status, DownloadStatus.wait);
  });

  test('初始化读取期间删除等待快照发布，删除后旧记录不复活', () async {
    final entry = downloadEntry(completed: true);
    await repository.create(entry);
    final readStarted = Completer<void>();
    final release = Completer<void>();
    final repo = _ControlledRepository(rootPath: () => directory.path)
      ..read = () async {
        final entries = await repository.load();
        readStarted.complete();
        await release.future;
        return entries;
      };
    final pending = DownloadService(repository: repo, downloadClient: client);
    final initialization = pending.initDownloadList();
    await readStarted.future;
    var deleted = false;
    final deletion = pending
        .deleteDownload(entry: entry, removeList: true)
        .then((result) {
          deleted = true;
          return result;
        });
    await Future<void>.delayed(Duration.zero);
    expect(deleted, false);
    release.complete();
    expect((await initialization).isSuccess, true);
    expect((await deletion).isSuccess, true);
    expect(pending.downloadList, isEmpty);
    expect(await repository.load(), isEmpty);
  });

  test('初始化等待在途创建落盘，旧创建不回写新快照且记录可恢复', () async {
    final repo = _BarrierRepository(rootPath: () => directory.path);
    final pending = _SchedulingDownloadService(
      repository: repo,
      downloadClient: client,
    );
    final creating = pending.downloadVideo(
      Part(cid: 11, page: 1, duration: 60),
      VideoDetailData(
        aid: 1,
        bvid: 'BV-test',
        title: 'test',
        pic: 'https://example.test/cover.jpg',
      ),
      null,
      VideoQuality.high1080,
      AudioQuality.k192,
    );
    final initialization = pending.initDownloadList();
    repo.gate.complete();
    expect(await creating, isA<DownloadCancelled>());
    expect((await initialization).isSuccess, true);
    expect(pending.waitDownloadQueue, hasLength(1));
    expect(pending.started, isEmpty);
  });

  test('创建落盘失败返回失败，重试成功后才进入队列', () async {
    const failure = FileSystemException('private-create');
    final repo = _ControlledRepository(rootPath: () => directory.path)
      ..saveFailure = failure;
    final pending = _SchedulingDownloadService(
      repository: repo,
      downloadClient: client,
    );
    Future<LoadingState<void>> create() => pending.downloadVideo(
      Part(cid: 11, page: 1, duration: 60),
      VideoDetailData(
        aid: 1,
        bvid: 'BV-test',
        title: 'test',
        pic: 'https://example.test/cover.jpg',
      ),
      null,
      VideoQuality.high1080,
      AudioQuality.k192,
    );
    final result = await create();
    expect(result, isA<Error>());
    expect((result as Error).cause, same(failure));
    expect(result.stackTrace, isNotNull);
    expect(result.toString(), isNot(contains('private-create')));
    expect(pending.waitDownloadQueue, isEmpty);
    expect(pending.started, isEmpty);
    repo.saveFailure = null;
    expect((await create()).isSuccess, true);
    expect(pending.waitDownloadQueue, hasLength(1));
    expect(pending.started, [11]);
  });

  for (final switching in [false, true]) {
    test('${switching ? '切换任务' : '暂停'}保存失败后原任务显示暂停且返回失败', () async {
      const failure = FileSystemException('private-save');
      final repo = _ControlledRepository(rootPath: () => directory.path);
      final old = downloadEntry()..status = DownloadStatus.downloading;
      final next = downloadEntry(cid: 22);
      await repo.create(old);
      await repo.create(next);
      repo.saveFailure = failure;
      final pending = DownloadService(repository: repo, downloadClient: client);
      pending.waitDownloadQueue.addAll([old, next]);
      pending.curDownload.value = old;
      final result = switching
          ? await pending.startDownload(next)
          : await pending.cancelDownload(isDelete: false, downloadNext: false);
      expect(result, isA<Error>());
      expect((result as Error).cause, same(failure));
      expect(result.stackTrace, isNotNull);
      expect(result.toString(), isNot(contains('private-save')));
      expect(old.status, DownloadStatus.pause);
      expect(pending.curDownload.value, same(old));
      expect(pending.waitDownloadQueue, [old, next]);
    });
  }

  for (final danmaku in [true, false]) {
    test('${danmaku ? '弹幕' : '媒体'}准备失败返回原始原因及安全提示', () async {
      final entry = downloadEntry();
      await repository.create(entry);
      if (!danmaku) {
        await File(path.join(entry.entryDirPath, PathUtils.danmakuName))
            .writeAsBytes([]);
      }
      final failure = StateError('private-preparation');
      final pending = DownloadService(
        repository: repository,
        downloadClient: client,
        prepareDanmaku: (_) async => throw failure,
        prepareMedia: (_) async => throw failure,
      );
      pending.waitDownloadQueue.add(entry);
      final result = await pending.startDownload(entry);
      expect(result, isA<Error>());
      expect((result as Error).cause, same(failure));
      expect(result.stackTrace, isNotNull);
      expect(result.toString(), isNot(contains('private-preparation')));
      expect(
        entry.status,
        danmaku ? DownloadStatus.failDanmaku : DownloadStatus.failPlayUrl,
      );
    });
  }

  test('手动弹幕失败保留原文件并返回失败原因', () async {
    final entry = downloadEntry(completed: true);
    await repository.create(entry);
    final file = File(path.join(entry.entryDirPath, PathUtils.danmakuName));
    await file.writeAsBytes([1]);
    final failure = StateError('private-danmaku');
    final pending = DownloadService(
      repository: repository,
      downloadClient: client,
      prepareDanmaku: (_) async => throw failure,
    );
    final result = await pending.downloadDanmaku(entry: entry, isUpdate: true);
    expect(result, isA<Error>());
    expect((result as Error).cause, same(failure));
    expect(result.stackTrace, isNotNull);
    expect(result.toString(), isNot(contains('private-danmaku')));
    expect(await file.readAsBytes(), [1]);
  });

  test('删除后同路径重建，旧弹幕结果不能写入新任务', () async {
    final entry = downloadEntry(completed: true);
    await repository.create(entry);
    final reply = Completer<List<int>>();
    final pending = DownloadService(
      repository: repository,
      downloadClient: client,
      prepareDanmaku: (_) => reply.future,
    );
    pending.downloadList.add(entry);
    final updating = pending.downloadDanmaku(entry: entry, isUpdate: true);
    expect(
      (await pending.deleteDownload(entry: entry, removeList: true)).isSuccess,
      true,
    );
    final fresh = downloadEntry(completed: true);
    await repository.create(fresh);
    pending.downloadList.add(fresh);
    reply.complete([1]);
    expect((await updating).isSuccess, false);
    expect(
      File(path.join(fresh.entryDirPath, PathUtils.danmakuName)).existsSync(),
      false,
    );
  });

  for (final lateFailure in [false, true]) {
    test('较新弹幕更新成功后，旧${lateFailure ? '异常' : '响应'}返回取消且不覆盖', () async {
      final entry = downloadEntry(completed: true);
      await repository.create(entry);
      final replies = <Completer<List<int>>>[];
      final pending = DownloadService(
        repository: repository,
        downloadClient: client,
        prepareDanmaku: (_) {
          final reply = Completer<List<int>>();
          replies.add(reply);
          return reply.future;
        },
      );
      final old = pending.downloadDanmaku(entry: entry, isUpdate: true);
      final fresh = pending.downloadDanmaku(entry: entry, isUpdate: true);
      replies[1].complete([2]);
      expect((await fresh).isSuccess, true);
      if (lateFailure) {
        replies[0].completeError(StateError('private-old-danmaku'));
      } else {
        replies[0].complete([1]);
      }
      expect(await old, isA<DownloadCancelled>());
      expect(
        await File(path.join(entry.entryDirPath, PathUtils.danmakuName))
            .readAsBytes(),
        [2],
      );
    });
  }

  for (final wholePage in [false, true]) {
    test('${wholePage ? '整组' : '单条'}删除失败保留队列及完成列表，允许重试', () async {
      const failure = FileSystemException('private path');
      final repo = _DeletionRepository(rootPath: () => directory.path)
        ..failure = failure;
      final pending = _SchedulingDownloadService(
        repository: repo,
        downloadClient: client,
      );
      final entry = downloadEntry();
      final completed = downloadEntry(cid: 22, completed: true);
      final next = downloadEntry(aid: 2, cid: 33);
      await repo.create(entry);
      await repo.create(completed);
      await repo.create(next);
      pending.waitDownloadQueue.addAll([entry, next]);
      pending.downloadList.add(completed);
      pending.curDownload.value = entry;
      entry.status = DownloadStatus.downloading;
      Future<LoadingState<void>> remove() => wholePage
          ? pending.deletePage(pageDirPath: entry.pageDirPath)
          : pending.deleteDownload(entry: entry, removeQueue: true);
      final deletion = remove();
      await repo.started.future;
      expect(pending.waitDownloadQueue, [entry, next]);
      expect(pending.downloadList, [completed]);
      repo.release.complete();
      final result = await deletion;
      expect(result, isA<Error>());
      expect((result as Error).cause, same(failure));
      expect(result.stackTrace, isNotNull);
      expect(result.toString(), isNot(contains('private path')));
      expect(pending.waitDownloadQueue, [entry, next]);
      expect(pending.downloadList, [completed]);
      expect(entry.status, DownloadStatus.pause);
      expect(pending.started, isEmpty);
      repo.failure = null;
      expect((await remove()).isSuccess, isTrue);
      expect(pending.waitDownloadQueue, [next]);
      expect(pending.downloadList, wholePage ? isEmpty : [completed]);
    });
  }

  test('删除成功不会因列表订阅回调失败而变成删除失败', () async {
    final entry = downloadEntry(completed: true);
    await repository.create(entry);
    service.downloadList.add(entry);
    var notified = false;
    service.flagNotifier.addAll([
      () => throw StateError('observer failure'),
      () => notified = true,
    ]);
    expect(
      (await service.deleteDownload(entry: entry, removeList: true)).isSuccess,
      isTrue,
    );
    expect(service.downloadList, isEmpty);
    expect(notified, isTrue);
  });

  test('删除期间的重新启动等待删除确认，不会重建已删除任务', () async {
    final repo = _DeletionRepository(rootPath: () => directory.path);
    final entry = downloadEntry();
    await repo.create(entry);
    final pending = DownloadService(repository: repo, downloadClient: client);
    pending.waitDownloadQueue.add(entry);
    final deletion = pending.deleteDownload(entry: entry, removeQueue: true);
    await repo.started.future;
    final start = pending.startDownload(entry);
    repo.release.complete();
    expect((await deletion).isSuccess, isTrue);
    await start;
    expect(pending.curDownload.value, isNull);
    expect(Directory(entry.entryDirPath).existsSync(), isFalse);
  });

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
    final completed = pending.curDownload.stream.firstWhere(
      (current) => current == null && pending.downloadList.isNotEmpty,
    );
    await pending.startDownload(entry);
    await completed.timeout(const Duration(seconds: 5));
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
    final oldStarted = Completer<void>();
    final newStarted = Completer<void>();
    final pending = DownloadService(
      repository: repository,
      downloadClient: client,
      prepareDanmaku: (entry) {
        final request = pendingRequests[entry.cid] = Completer<List<int>>();
        (entry.cid == oldEntry.cid ? oldStarted : newStarted).complete();
        return request.future;
      },
    );
    pending.waitDownloadQueue.addAll([oldEntry, newEntry]);
    final oldStart = pending.startDownload(oldEntry);
    await oldStarted.future;
    final newStart = pending.startDownload(newEntry);
    await newStarted.future;
    pendingRequests[oldEntry.cid]!.completeError(StateError('旧请求失败'));
    expect(await oldStart, isA<DownloadCancelled>());
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
