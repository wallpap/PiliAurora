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

  for (final malformed in ['{broken', '[]']) {
    test('损坏记录 $malformed 不影响合法记录，缺少记录的目录被跳过', () async {
      await repository.create(downloadEntry());
      final badDirectory = await Directory(path.join(rootPath, '2', 'c_22'))
          .create(recursive: true);
      final badFile = File(path.join(badDirectory.path, 'entry.json'));
      await badFile.writeAsString(malformed);
      final missingDirectory = await Directory(path.join(rootPath, '3', 'c_33'))
          .create(recursive: true);
      await File(path.join(missingDirectory.path, 'cover.jpg'))
          .writeAsString('');
      expect((await repository.load()).map((entry) => entry.cid), [11]);
      expect(corruptPaths, [badFile.path]);
    });
  }

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

  test('recovers a corrupt record from the last committed backup', () async {
    final entry = downloadEntry();
    await repository.create(entry);
    entry.downloadedBytes = 12;
    await repository.save(entry);
    final file = File(path.join(entry.entryDirPath, 'entry.json'));
    await file.writeAsString('{interrupted');
    final restored = (await repository.load()).single;
    expect(restored.downloadedBytes, 10);
    expect(jsonDecode(file.readAsStringSync()), restored.toJson());
    expect(corruptPaths, contains(file.path));
  });

  test('committed record wins over a leftover newer temporary file', () async {
    final entry = downloadEntry();
    await repository.create(entry);
    entry.isCompleted = true;
    await File(path.join(entry.entryDirPath, 'entry.json.tmp'))
        .writeAsString(jsonEncode(entry.toJson()), flush: true);
    expect((await repository.load()).single.isCompleted, isFalse);
  });

  test(
    'first interrupted creation can recover a complete temporary file',
    () async {
      final entry = downloadEntry();
      await repository.create(entry);
      final file = File(path.join(entry.entryDirPath, 'entry.json'));
      await file.rename('${file.path}.tmp');
      expect((await repository.load()).single.cid, entry.cid);
      expect(file.existsSync(), isTrue);
    },
  );

  test('failed replacement preserves the committed record and media', () async {
    final entry = downloadEntry();
    await repository.create(entry);
    final file = File(path.join(entry.entryDirPath, 'entry.json'));
    final original = await file.readAsString();
    final media = File(path.join(entry.entryDirPath, 'video.m4s'));
    await media.writeAsBytes([1, 2, 3]);
    await Directory('${file.path}.tmp').create();
    entry.downloadedBytes = 20;
    await expectLater(
      repository.save(entry),
      throwsA(isA<FileSystemException>()),
    );
    expect(await file.readAsString(), original);
    expect(await media.readAsBytes(), [1, 2, 3]);
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

  test('重复删除不存在的分 P 不会删除唯一剩余分 P', () async {
    final first = downloadEntry();
    final sibling = downloadEntry(cid: 22);
    await repository.create(first);
    await repository.create(sibling);
    await repository.remove(first);
    await repository.remove(first);
    expect((await repository.load()).map((entry) => entry.cid), [22]);
  });

  test('删除路径被普通文件占用时返回文件系统错误', () async {
    final entry = downloadEntry();
    await repository.create(entry);
    await Directory(entry.entryDirPath).delete(recursive: true);
    await File(entry.entryDirPath).writeAsString('unexpected file');
    await expectLater(
      repository.remove(entry),
      throwsA(isA<FileSystemException>()),
    );
    await expectLater(
      repository.removePage(entry.entryDirPath),
      throwsA(isA<FileSystemException>()),
    );
    expect(await File(entry.entryDirPath).readAsString(), 'unexpected file');
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
