import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:pili_aurora/models/common/video/cdn_type.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/video_utils.dart';

void main() {
  late Directory directory;

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('pili-video-utils-');
    Hive.init(directory.path);
    GStorage.setting = await Hive.openBox('setting');
  });

  tearDownAll(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test('preferred CDN stays first, followed by unique API backup URLs', () {
    const primary =
        'https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/video?deadline=1';
    const backup =
        'https://upos-sz-mirrorali.bilivideo.com/upgcxcode/video?deadline=1';

    final urls = VideoUtils.getCdnUrls(
      [primary, backup, primary],
      defaultCDNService: CDNService.hw,
    );

    expect(urls, [
      'https://upos-sz-mirrorhw.bilivideo.com/upgcxcode/video?deadline=1',
      primary,
      backup,
    ]);
    expect(
      urls.first,
      VideoUtils.getCdnUrl([primary, backup], defaultCDNService: CDNService.hw),
    );
  });

  test('audio CDN preference behavior is retained for the primary URL', () {
    const primary =
        'https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/audio?deadline=1';
    const backup =
        'https://upos-sz-mirrorali.bilivideo.com/upgcxcode/audio?deadline=1';

    final urls = VideoUtils.getCdnUrls(
      [primary, backup],
      defaultCDNService: CDNService.ali,
      isAudio: true,
    );

    expect(
      urls.first,
      VideoUtils.getCdnUrl(
        [primary, backup],
        defaultCDNService: CDNService.ali,
        isAudio: true,
      ),
    );
    expect(urls, contains(backup));
  });

  test('empty URL lists have no candidates', () {
    expect(VideoUtils.getCdnUrls(const []), isEmpty);
  });
}
