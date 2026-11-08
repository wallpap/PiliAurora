import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/models/common/video/cdn_type.dart';
import 'package:pili_aurora/models/remote/live/live_room_play_info/codec.dart';
import 'package:pili_aurora/models/remote/live/live_room_play_info/url_info.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';
import 'package:pili_aurora/utils/storage_pref.dart';
import 'package:pili_aurora/utils/video_utils.dart';

import '../support/memory_box.dart';

void main() {
  late bool previousDisableAudioCdn;
  late String? previousLiveCdnUrl;

  setUpAll(() {
    GStorage.setting = MemoryBox<dynamic>();
  });

  setUp(() async {
    await GStorage.setting.clear();
    previousDisableAudioCdn = VideoUtils.disableAudioCDN;
    previousLiveCdnUrl = VideoUtils.liveCdnUrl;
    VideoUtils.disableAudioCDN = false;
  });

  tearDown(() {
    VideoUtils.disableAudioCDN = previousDisableAudioCdn;
    VideoUtils.liveCdnUrl = previousLiveCdnUrl;
  });

  test('接口没有 Akamai 地址时不使用其它 CDN 的签名构造地址', () async {
    const original =
        'https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/video?sign=cos';
    const backup =
        'https://upos-sz-mirrorali.bilivideo.com/upgcxcode/video?sign=ali';
    expect(
      VideoUtils.getCdnUrl(
        [original, backup],
        defaultCDNService: CDNService.akamai,
      ),
      original,
    );

    await GStorage.setting.put(SettingBoxKey.enableMultiCdn, true);
    final urls = VideoUtils.getCdnUrls(
      [original, backup],
      defaultCDNService: CDNService.cos,
    );
    expect(
      urls,
      isNot(
        contains(
          original.replaceFirst(
            'upos-sz-mirrorcos.bilivideo.com',
            'upos-hz-mirrorakam.akamaized.net',
          ),
        ),
      ),
    );
  });

  test('其它 CDN 保持首个镜像地址的改写优先级', () {
    const original =
        'https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/video?sign=cos';
    const other =
        'https://foo.szbdyd.com/video?xy_usource=upos-sz-mirrorali.bilivideo.com';
    expect(
      VideoUtils.getCdnUrl(
        [original, other],
        defaultCDNService: CDNService.hw,
      ),
      original.replaceFirst('mirrorcos', 'mirrorhw'),
    );
  });

  test('各镜像主机优先使用接口原文，签名和来源顺序均保留', () {
    const legacy = 'https://foo.szbdyd.com/video?xy_usource=legacy.example.com';
    for (final service in CDNService.values.where(
      (service) => service.host?.startsWith('upos-') == true,
    )) {
      final signed =
          'https://${service.host}/upgcxcode/video?sign=A%2bb%2F&key=1&key=2';
      expect(
        VideoUtils.getCdnUrl([
          legacy,
          signed,
          signed.replaceFirst('sign=A', 'sign=other'),
        ], defaultCDNService: service),
        signed,
        reason: service.name,
      );
    }
    expect(
      VideoUtils.getCdnUrl([
        legacy,
        'https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/video?sign=cos',
      ], defaultCDNService: CDNService.hw),
      'https://legacy.example.com/video?xy_usource=legacy.example.com',
    );
  });

  test('mcdn 回退优先使用最后一个 upgcxcode 来源，否则包装资源地址', () {
    const resource = 'https://a.mcdn.bilivideo.cn:4483/v1/resource?token=x';
    const upgcxcode =
        'https://cn-bcache.bilivideo.com/upgcxcode/video?sign=original';
    expect(
      VideoUtils.getCdnUrl([
        resource,
        '$upgcxcode&old=1',
        upgcxcode,
      ], defaultCDNService: CDNService.hw),
      'https://upos-sz-mirrorhw.bilivideo.com/upgcxcode/video?sign=original',
    );
    final proxy = Uri.parse(
      VideoUtils.getCdnUrl([resource], defaultCDNService: CDNService.backupUrl),
    );
    expect(proxy.host, 'proxy-tf-all-ws.bilivideo.com');
    expect(proxy.queryParameters['url'], resource);
  });

  test('签名来源在首选和回退中保持原文、有序且不重复', () async {
    await GStorage.setting.put(SettingBoxKey.enableMultiCdn, true);
    await GStorage.setting.put(SettingBoxKey.cdnFallbackOrder, ['hw']);
    const cos =
        'https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/video?sign=cos';
    const ali =
        'https://upos-sz-mirrorali.bilivideo.com/upgcxcode/video?sign=ali';
    const akamai =
        'https://upos-hz-mirrorakam.akamaized.net/upgcxcode/video?hdnts=A%2Bb';
    const hw =
        'https://upos-sz-mirrorhw.bilivideo.com/upgcxcode/video?sign=cos';
    for (final (service, expected) in [
      (CDNService.cos, [cos, hw, akamai, ali]),
      (CDNService.ali, [ali, hw, cos, akamai]),
      (CDNService.akamai, [akamai, hw, cos, ali]),
      (CDNService.hw, [hw, cos, akamai, ali]),
    ]) {
      const sources = [cos, akamai, ali, cos];
      expect(
        VideoUtils.getCdnUrl(sources, defaultCDNService: service),
        expected.first,
        reason: service.name,
      );
      expect(
        VideoUtils.getCdnUrls(sources, defaultCDNService: service),
        expected,
        reason: service.name,
      );
    }
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

  test('默认单源，启用和关闭回退只改变候选列表，空来源没有候选', () async {
    const cos =
        'https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/video?sign=cos';
    const hw =
        'https://upos-sz-mirrorhw.bilivideo.com/upgcxcode/video?sign=cos';
    await GStorage.setting.put(SettingBoxKey.cdnFallbackOrder, ['hw']);
    for (final enabled in [null, true, false]) {
      if (enabled != null) {
        await GStorage.setting.put(SettingBoxKey.enableMultiCdn, enabled);
      }
      expect(
        VideoUtils.getCdnUrls([cos], defaultCDNService: CDNService.cos),
        enabled == true ? [cos, hw] : [cos],
        reason: 'enableMultiCdn=$enabled',
      );
      for (final empty in [
        <String>[],
        ['', ''],
      ]) {
        expect(VideoUtils.getCdnUrls(empty), isEmpty);
      }
    }
  });

  for (final multiCdn in [false, true]) {
    test('音频 CDN 开关在多源=$multiCdn 时保留首选与原始备用', () async {
      await GStorage.setting.put(SettingBoxKey.enableMultiCdn, multiCdn);
      await GStorage.setting.put(SettingBoxKey.cdnFallbackOrder, ['hw']);
      const cos =
          'https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/audio?deadline=1';
      const ali =
          'https://upos-sz-mirrorali.bilivideo.com/upgcxcode/audio?deadline=1';
      const hw =
          'https://upos-sz-mirrorhw.bilivideo.com/upgcxcode/audio?deadline=1';
      for (final disabled in [false, true]) {
        VideoUtils.disableAudioCDN = disabled;
        expect(
          VideoUtils.getCdnUrls(
            [cos, ali],
            defaultCDNService: CDNService.ali,
            isAudio: true,
          ),
          disabled
              ? (multiCdn ? [cos, ali] : [cos])
              : (multiCdn ? [ali, hw, cos] : [ali]),
          reason: 'disableAudioCDN=$disabled',
        );
      }
    });
  }
}
