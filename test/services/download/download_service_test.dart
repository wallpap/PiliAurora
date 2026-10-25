import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/models/remote/download/bili_download_entry_info.dart';
import 'package:pili_aurora/services/download/download_repository.dart';
import 'package:pili_aurora/services/download/download_service.dart';

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
