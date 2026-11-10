import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show FlutterError;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:pili_aurora/utils/asset_utils.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temporary;
  final assets = <String, List<int>>{};
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('asset-preparation-');
    assets.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', (message) async {
          final name = utf8.decode(
            message!.buffer.asUint8List(
              message.offsetInBytes,
              message.lengthInBytes,
            ),
          );
          final bytes = assets[name];
          if (bytes == null) return null;
          final padded = Uint8List.fromList([99, ...bytes, 98]);
          return ByteData.view(padded.buffer, 1, bytes.length);
        });
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', null);
    await temporary.delete(recursive: true);
  });
  test('部分资源失败不能返回可用目录，重试补齐且不遗留暂存目录', () async {
    assets['review-assets/one'] = [1, 2, 3];
    final dst = path.join(temporary.path, 'output');
    await expectLater(
      AssetUtils.getOrCopy('review-assets', ['one', 'two'], dst),
      throwsA(isA<FlutterError>()),
    );
    expect(await File(path.join(dst, 'one')).readAsBytes(), [1, 2, 3]);
    expect(File(path.join(dst, 'two')).existsSync(), false);
    assets['review-assets/two'] = [4, 5];
    expect(
      await AssetUtils.getOrCopy('review-assets', ['one', 'two'], dst),
      dst,
    );
    expect(await File(path.join(dst, 'two')).readAsBytes(), [4, 5]);
    expect(
      await Directory(dst).list().where((entry) => entry is Directory).isEmpty,
      true,
    );
  });
  test('重建旧的不完整文件，写入只使用资源ByteData有效范围', () async {
    final dst = temporary.path;
    assets['review-assets/one'] = [1, 2, 3];
    await File(path.join(dst, 'one')).writeAsBytes([1]);
    await AssetUtils.getOrCopy('review-assets', ['one'], dst);
    expect(await File(path.join(dst, 'one')).readAsBytes(), [1, 2, 3]);
  });
  test('目标目录创建失败保留文件系统原因', () async {
    final file = await File(path.join(temporary.path, 'blocked'))
        .writeAsString('occupied');
    await expectLater(
      AssetUtils.getOrCopy('review-assets', ['one'], file.path),
      throwsA(isA<FileSystemException>()),
    );
  });
}
