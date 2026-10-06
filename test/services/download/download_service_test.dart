import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/models/remote/download/bili_download_entry_info.dart';
import 'package:pili_aurora/services/download/download_repository.dart';
import 'package:pili_aurora/services/download/download_service.dart';

import 'download_fixtures.dart';

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
}
