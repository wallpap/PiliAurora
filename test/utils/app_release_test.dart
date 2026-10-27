import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/utils/app_release.dart';

Map<String, Object?> release(String tag, {List<String> assets = const []}) => {
  'tag_name': tag,
  'created_at': '2030-01-01T00:00:00Z',
  'draft': false,
  'prerelease': false,
  'assets': [
    for (final name in assets)
      {
        'name': name,
        'state': 'uploaded',
        'browser_download_url': 'https://example.test/$name',
      },
  ],
};

void main() {
  test('按数字版本选择正式发布，忽略接口顺序、草稿和预发布', () {
    final latest = AppRelease.latestStable([
      {...release('v9.0.0'), 'draft': true},
      {...release('v3.0.0'), 'prerelease': true},
      release('v2.0.0-beta.1'),
      release('nightly'),
      release('v1.9.0'),
      release('v1.10.0'),
      release('v1.8.9'),
    ])!;
    expect(latest.tag, 'v1.10.0');
    expect(latest.isNewerThan('1.9.9'), isTrue);
  });

  test('新建旧发布、重打包和构建号变化不会触发降级或重复提示', () {
    final latest = AppRelease.latestStable([release('v1.6.2')])!;
    expect(latest.isNewerThan('1.6.2+452'), isFalse);
    expect(latest.isNewerThan('1.7.0'), isFalse);
    expect(latest.isNewerThan('1.6.1'), isTrue);
    expect(latest.isNewerThan('1.6.2-97fb3d4ff'), isTrue);
    expect(latest.isNewerThan('1.7.0-beta.1'), isFalse);
  });

  test('空发布列表、接口错误和未知本机版本分别处理', () {
    expect(AppRelease.latestStable([]), isNull);
    expect(AppRelease.latestStable([release('nightly')]), isNull);
    expect(
      () => AppRelease.latestStable({'message': 'rate limited'}),
      throwsFormatException,
    );
    final latest = AppRelease.latestStable([release('v1.6.2')])!;
    expect(() => latest.isNewerThan('SNAPSHOT'), throwsFormatException);
  });

  test('Windows 下载按架构和扩展名匹配，缺少附件返回空', () {
    final latest = AppRelease.latestStable([
      release(
        'v1.6.2',
        assets: [
          'PiliAurora_android_1.6.2+452_arm64-v8a.apk',
          'PiliAurora_windows_1.6.2+452_arm64_setup.exe',
          'PiliAurora_windows_1.6.2+452_x64_setup.exe',
          'PiliAurora_windows_1.6.2+452_x64_portable.zip',
        ],
      ),
    ])!;
    expect(
      latest.downloadUrl(platform: 'windows', extension: 'exe'),
      endsWith('x64_setup.exe'),
    );
    expect(
      latest.downloadUrl(platform: 'windows', extension: 'zip'),
      endsWith('x64_portable.zip'),
    );
    expect(
      AppRelease.latestStable([release('v1.6.2')])!
          .downloadUrl(platform: 'windows'),
      isNull,
    );
  });

  test('Android 沿 supportedAbis 选择兼容包，不依赖附件顺序', () {
    final latest = AppRelease.latestStable([
      release(
        'v1.6.2',
        assets: [
          'PiliAurora_android_1.6.2+452_armeabi-v7a.apk',
          'PiliAurora_android_1.6.2+452_x86_64.apk',
        ],
      ),
    ])!;
    expect(
      latest.downloadUrl(
        platform: 'android',
        supportedAbis: ['arm64-v8a', 'armeabi-v7a'],
      ),
      endsWith('armeabi-v7a.apk'),
    );
    expect(
      latest.downloadUrl(
        platform: 'android',
        supportedAbis: ['x86_64', 'armeabi-v7a'],
      ),
      endsWith('x86_64.apk'),
    );
    expect(
      latest.downloadUrl(platform: 'android', supportedAbis: ['arm64-v8a']),
      isNull,
    );
  });

  test('尚未上传完成的附件和无效下载地址不作为下载入口', () {
    final latest = AppRelease.latestStable([
      {
        ...release('v1.6.2'),
        'assets': [
          {
            'name': 'PiliAurora_windows_v1.6.2_x64_setup.exe',
            'state': 'new',
            'browser_download_url': 'https://example.test/pending.exe',
          },
          {
            'name': 'PiliAurora_windows_v1.6.2_x64_setup.exe',
            'browser_download_url': 'file:///old.exe',
          },
        ],
      },
    ])!;
    expect(latest.downloadUrl(platform: 'windows'), isNull);
  });
}
