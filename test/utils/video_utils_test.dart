import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:pili_aurora/models/common/video/cdn_type.dart';
import 'package:pili_aurora/models/remote/live/live_room_play_info/codec.dart';
import 'package:pili_aurora/models/remote/live/live_room_play_info/url_info.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';
import 'package:pili_aurora/utils/storage_pref.dart';
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

  setUp(() async {
    await GStorage.setting.delete(SettingBoxKey.enableMultiCdn);
    await GStorage.setting.delete(SettingBoxKey.cdnFallbackOrder);
    VideoUtils.disableAudioCDN = false;
  });

  test('直播备用源保留当前选择，按当前编码提供原始备用 host', () async {
    final codec = CodecItem(
      currentQn: 10000,
      acceptQn: [10000],
      baseUrl: '/stream.flv',
      urlInfo: [
        UrlInfo(host: 'https://a.example.com', extra: '?a=1'),
        UrlInfo(host: 'https://b.example.com', extra: '?b=2'),
      ],
    );
    VideoUtils.liveCdnUrl = null;
    expect(VideoUtils.getLiveCdnUrls(codec, index: 1), [
      'https://b.example.com/stream.flv?b=2',
    ]);
    await GStorage.setting.put(SettingBoxKey.enableMultiCdn, true);
    VideoUtils.liveCdnUrl = 'https://custom.example.com';
    expect(VideoUtils.getLiveCdnUrls(codec, index: 1), [
      'https://custom.example.com/stream.flv?b=2',
      'https://a.example.com/stream.flv?a=1',
      'https://b.example.com/stream.flv?b=2',
    ]);
    VideoUtils.liveCdnUrl = null;
  });

  test('single CDN is the default and preserves the original selection', () {
    const urls = [
      'https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/video?deadline=1',
      'https://upos-sz-mirrorali.bilivideo.com/upgcxcode/video?deadline=1',
    ];

    expect(Pref.enableMultiCdn, isFalse);
    expect(VideoUtils.getCdnUrls(urls, defaultCDNService: CDNService.hw), [
      VideoUtils.getCdnUrl(urls, defaultCDNService: CDNService.hw),
    ]);
  });

  test(
    'default fallback uses CDN list order after the preferred source',
    () async {
      await GStorage.setting.put(SettingBoxKey.enableMultiCdn, true);
      const primary =
          'https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/video?deadline=1';
      const backup =
          'https://upos-sz-mirrorali.bilivideo.com/upgcxcode/video?deadline=1';

      final urls = VideoUtils.getCdnUrls(
        [primary, backup, primary],
        defaultCDNService: CDNService.hw,
      );

      expect(urls.take(5), [
        'https://upos-sz-mirrorhw.bilivideo.com/upgcxcode/video?deadline=1',
        primary,
        backup,
        'https://upos-sz-mirroralib.bilivideo.com/upgcxcode/video?deadline=1',
        'https://upos-sz-mirroralio1.bilivideo.com/upgcxcode/video?deadline=1',
      ]);
      expect(urls.toSet().length, urls.length);
      expect(
        urls.first,
        VideoUtils.getCdnUrl([
          primary,
          backup,
        ], defaultCDNService: CDNService.hw),
      );
    },
  );

  test(
    'custom fallback order persists and deduplicates the preferred CDN',
    () async {
      await GStorage.setting.put(SettingBoxKey.enableMultiCdn, true);
      await GStorage.setting.put(
        SettingBoxKey.cdnFallbackOrder,
        ['hw', 'ali', 'removed-cdn', 'hw', 'cos'],
      );
      expect(Pref.cdnFallbackOrder, [
        CDNService.hw,
        CDNService.ali,
        CDNService.cos,
      ]);
      const primary =
          'https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/video?deadline=1';
      const backup = 'https://backup.example.com/video?deadline=1';
      expect(
        VideoUtils.getCdnUrls([
          primary,
          backup,
        ], defaultCDNService: CDNService.ali),
        [
          'https://upos-sz-mirrorali.bilivideo.com/upgcxcode/video?deadline=1',
          'https://upos-sz-mirrorhw.bilivideo.com/upgcxcode/video?deadline=1',
          primary,
          backup,
        ],
      );

      await GStorage.setting.put(SettingBoxKey.enableMultiCdn, false);
      expect(
        VideoUtils.getCdnUrls([
          primary,
          backup,
        ], defaultCDNService: CDNService.ali),
        [
          'https://upos-sz-mirrorali.bilivideo.com/upgcxcode/video?deadline=1',
        ],
      );
    },
  );

  test(
    'audio opt-out retains API sources without rewriting fallback hosts',
    () async {
      await GStorage.setting.put(SettingBoxKey.enableMultiCdn, true);
      await GStorage.setting.put(SettingBoxKey.cdnFallbackOrder, ['hw']);
      VideoUtils.disableAudioCDN = true;
      const urls = [
        'https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/audio?deadline=1',
        'https://upos-sz-mirrorali.bilivideo.com/upgcxcode/audio?deadline=1',
      ];
      expect(VideoUtils.getCdnUrls(urls, isAudio: true), urls);
    },
  );

  test(
    'audio CDN preference behavior is retained for the primary URL',
    () async {
      await GStorage.setting.put(SettingBoxKey.enableMultiCdn, true);
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
    },
  );

  test('disabling multi CDN restores single-source generation', () async {
    const urls = [
      'https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/video?deadline=1',
      'https://upos-sz-mirrorali.bilivideo.com/upgcxcode/video?deadline=1',
    ];
    await GStorage.setting.put(SettingBoxKey.enableMultiCdn, true);
    expect(VideoUtils.getCdnUrls(urls).length, greaterThan(1));

    await GStorage.setting.put(SettingBoxKey.enableMultiCdn, false);
    expect(VideoUtils.getCdnUrls(urls), [VideoUtils.getCdnUrl(urls)]);
  });

  test('empty URL lists have no candidates', () {
    expect(VideoUtils.getCdnUrls(const []), isEmpty);
  });
}
