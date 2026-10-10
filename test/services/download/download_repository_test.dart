import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:pili_aurora/models/remote/download/bili_download_entry_info.dart';
import 'package:pili_aurora/models/remote/download/bili_download_media_file_info.dart';
import 'package:pili_aurora/services/download/download_repository.dart';

import 'download_fixtures.dart';

void main() {
  late Directory directory;
  late String rootPath;
  late DownloadRepository repository;
  late List<String> corruptPaths;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'pili-download-repository-',
    );
    rootPath = path.join(directory.path, 'downloads');
    corruptPaths = [];
    repository = DownloadRepository(
      rootPath: () => rootPath,
      onReadError: (file, _, _) => corruptPaths.add(file),
    );
  });

  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test('missing download directory yields an empty snapshot', () async {
    expect(await repository.load(), isEmpty);
    expect(Directory(rootPath).existsSync(), isTrue);
  });

  for (final episode in [false, true]) {
    test('creates and restores ${episode ? 'PGC' : 'UGC'} records', () async {
      final entry = downloadEntry(episode: episode, audioQuality: 30251);
      await repository.create(entry);
      final expectedPath = episode
          ? path.join(rootPath, 's_22', '33')
          : path.join(rootPath, '1', 'c_11');
      expect(entry.entryDirPath, expectedPath);
      expect(entry.pageDirPath, path.dirname(expectedPath));
      final restored = (await repository.load()).single;
      expect(restored.toJson(), entry.toJson());
      expect(restored.cid, 11);
      expect(restored.entryDirPath, expectedPath);
      expect(restored.pageDirPath, path.dirname(expectedPath));
      expect(restored.status, DownloadStatus.wait);
    });
  }

  test('bad records do not discard valid records', () async {
    await repository.create(downloadEntry());
    final badDirectory = await Directory(
      path.join(rootPath, '2', 'c_22'),
    ).create(recursive: true);
    final badFile = File(path.join(badDirectory.path, 'entry.json'));
    await badFile.writeAsString('{broken');
    final missingDirectory = await Directory(
      path.join(rootPath, '3', 'c_33'),
    ).create(recursive: true);
    await File(path.join(missingDirectory.path, 'cover.jpg')).writeAsString('');
    expect((await repository.load()).map((entry) => entry.cid), [11]);
    expect(corruptPaths, [badFile.path]);
  });

  test('invalid record shape is isolated like invalid JSON', () async {
    final entry = downloadEntry();
    await repository.create(entry);
    await File(path.join(entry.entryDirPath, 'entry.json')).writeAsString('[]');
    expect(await repository.load(), isEmpty);
    expect(corruptPaths, hasLength(1));
  });

  test('serializes saves and restores the final snapshot', () async {
    final entry = downloadEntry();
    await repository.create(entry);
    final writes = <Future<void>>[];
    for (var progress = 1; progress <= 30; progress++) {
      entry.downloadedBytes = progress;
      writes.add(repository.save(entry));
    }
    // 尚未保存的后续修改不能污染排队中的快照。
    entry.downloadedBytes = 99;
    await Future.wait(writes);
    expect((await repository.load()).single.downloadedBytes, 30);
  });

  test('download root is resolved again after a settings change', () async {
    await repository.create(downloadEntry());
    final oldRoot = rootPath;
    rootPath = path.join(directory.path, 'new-downloads');
    expect(await repository.load(), isEmpty);
    final entry = downloadEntry(cid: 22);
    await repository.create(entry);
    expect(path.isWithin(rootPath, entry.entryDirPath), isTrue);
    expect(
      File(path.join(oldRoot, '1', 'c_11', 'entry.json')).existsSync(),
      isTrue,
    );
  });

  test('media index and media directory are owned by the repository', () async {
    final entry = downloadEntry();
    await repository.create(entry);
    final media = Type2(duration: 60, video: [], audio: []);
    final mediaDirectory = await repository.saveMediaInfo(entry, media);
    expect(mediaDirectory, path.join(entry.entryDirPath, '80'));
    final json = jsonDecode(
      await File(path.join(mediaDirectory, 'index.json')).readAsString(),
    );
    expect(json, media.toJson());
  });

  test(
    'removing one part preserves siblings and removes an empty page',
    () async {
      final first = downloadEntry();
      final second = downloadEntry(cid: 22);
      await repository.create(first);
      await repository.create(second);
      await repository.remove(first);
      expect(Directory(first.entryDirPath).existsSync(), isFalse);
      expect((await repository.load()).map((entry) => entry.cid), [22]);
      await repository.remove(second);
      expect(Directory(second.pageDirPath).existsSync(), isFalse);
      await repository.remove(second);
    },
  );

  test('removing a page leaves other pages intact', () async {
    final first = downloadEntry();
    final second = downloadEntry(aid: 2, cid: 22);
    await repository.create(first);
    await repository.create(second);
    await repository.removePage(first.pageDirPath);
    expect((await repository.load()).map((entry) => entry.cid), [22]);
  });

  test(
    'a record without a page or episode fails before creating files',
    () async {
      final entry = downloadEntry()..pageData = null;
      await expectLater(repository.create(entry), throwsArgumentError);
      expect(Directory(rootPath).existsSync(), isFalse);
    },
  );
}
