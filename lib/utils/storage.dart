import 'dart:io' show File;
import 'dart:typed_data';

import 'package:pili_aurora/models/model_owner.dart';
import 'package:pili_aurora/models/user/danmaku_rule_adapter.dart';
import 'package:pili_aurora/models/user/info.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/encrypted_hive.dart';
import 'package:pili_aurora/utils/accounts/account_adapter.dart';
import 'package:pili_aurora/utils/accounts/account_type_adapter.dart';
import 'package:pili_aurora/utils/accounts/cookie_jar_adapter.dart';
import 'package:pili_aurora/utils/path_utils.dart';
import 'package:pili_aurora/utils/set_int_adapter.dart';
import 'package:pili_aurora/utils/storage_key.dart';
import 'package:pili_aurora/utils/storage_pref.dart';
import 'package:pili_aurora/services/settings/settings_backup.dart';
import 'package:hive_ce/hive.dart';
import 'package:path/path.dart' as path;

abstract final class GStorage {
  static late final Box<UserInfoData> userInfo;
  static late final Box<dynamic> historyWord;
  static late final Box<dynamic> localCache;
  static late final Box<dynamic> setting;
  static late final Box<dynamic> credentials;
  static late final Box<dynamic> video;
  static late final Box<int> watchProgress;
  static late final Box<Uint8List>? reply;

  /// encryptionKey 供无平台安全存储的测试注入；应用启动使用系统密钥。
  static Future<void> init({
    Map<String, Uint8List>? memorySnapshot,
    List<int>? encryptionKey,
  }) async {
    Hive.init(path.join(appSupportDirPath, 'hive'));
    regAdapter();
    final root = path.join(appSupportDirPath, 'hive');
    final secure = encryptionKey == null
        ? await EncryptedHive.initialize(root)
        : EncryptedHive(root, encryptionKey);
    Uint8List? bytes(String name) => memorySnapshot == null
        ? null
        : memorySnapshot[name.toLowerCase()] ?? Uint8List(0);

    await Future.wait([
      // 登录用户信息
      Hive.openBox<UserInfoData>(
        'userInfo',
        bytes: bytes('userInfo'),
        compactionStrategy: (int entries, int deletedEntries) {
          return deletedEntries > 2;
        },
      ).then((res) => userInfo = res),
      // 本地缓存
      Hive.openBox(
        'localCache',
        bytes: bytes('localCache'),
        compactionStrategy: (int entries, int deletedEntries) {
          return deletedEntries > 4;
        },
      ).then((res) => localCache = res),
      // 设置
      Hive.openBox(
        'setting',
        bytes: bytes('setting'),
      ).then((res) => setting = res),
      // 搜索历史
      Hive.openBox(
        'historyWord',
        bytes: bytes('historyWord'),
        compactionStrategy: (int entries, int deletedEntries) {
          return deletedEntries > 10;
        },
      ).then((res) => historyWord = res),
      // 视频设置
      Hive.openBox('video', bytes: bytes('video')).then((res) => video = res),
      Accounts.init(secure, bytes: bytes('account')),
      secure
          .openBox<dynamic>('credentials', bytes: bytes('credentials'))
          .then((res) => credentials = res),
      Hive.openBox<int>(
        'watchProgress',
        bytes: bytes('watchProgress'),
        keyComparator: _intStrDescKeyComparator,
        compactionStrategy: (entries, deletedEntries) {
          return deletedEntries > 4;
        },
      ).then((res) => watchProgress = res),
    ]);

    if (setting.containsKey(SettingBoxKey.webdavPassword)) {
      await credentials.put(
        SettingBoxKey.webdavPassword,
        setting.get(SettingBoxKey.webdavPassword),
      );
      await credentials.flush();
      await setting.delete(SettingBoxKey.webdavPassword);
      // 删除 Hive 日志中的旧密码，而不只追加删除记录。
      await setting.compact();
    }

    if (setting.containsKey(
      LegacySettingBoxKey.androidFullscreenCalibration,
    )) {
      await setting.delete(LegacySettingBoxKey.androidFullscreenCalibration);
    }

    if (Pref.saveReply) {
      reply = await Hive.openBox<Uint8List>(
        'reply',
        bytes: bytes('reply'),
        keyComparator: _intStrDescKeyComparator,
        compactionStrategy: (entries, deletedEntries) {
          return deletedEntries > 10;
        },
      );
    } else {
      reply = null;
    }
  }

  /// 子进程通过内存 Box 读取快照，避免争用主进程的 Hive 文件锁。
  static Future<Map<String, Uint8List>> playbackSnapshot() async {
    final boxes = <Box>[
      userInfo,
      localCache,
      setting,
      video,
      Accounts.account,
      credentials,
      watchProgress,
    ];
    await Future.wait(boxes.map((box) => box.flush()));
    return {
      for (final box in boxes) box.name: File(box.path!).readAsBytesSync(),
    };
  }

  static SettingsBackup get settingsBackup =>
      SettingsBackup(setting: setting, video: video, credentials: credentials);

  static void regAdapter() {
    Hive
      ..registerAdapter(OwnerAdapter())
      ..registerAdapter(UserInfoDataAdapter())
      ..registerAdapter(LevelInfoAdapter())
      ..registerAdapter(BiliCookieJarAdapter())
      ..registerAdapter(LoginAccountAdapter())
      ..registerAdapter(AccountTypeAdapter())
      ..registerAdapter(SetIntAdapter())
      ..registerAdapter(RuleFilterAdapter());
  }

  static Future<List<void>> compact() {
    return Future.wait([
      userInfo.compact(),
      historyWord.compact(),
      localCache.compact(),
      setting.compact(),
      credentials.compact(),
      video.compact(),
      Accounts.account.compact(),
      watchProgress.compact(),
      ?reply?.compact(),
    ]);
  }

  static Future<List<void>> close() {
    return Future.wait([
      userInfo.close(),
      historyWord.close(),
      localCache.close(),
      setting.close(),
      credentials.close(),
      video.close(),
      Accounts.account.close(),
      watchProgress.close(),
      ?reply?.close(),
    ]);
  }

  static Future<List<void>> clear() {
    return Future.wait([
      userInfo.clear(),
      historyWord.clear(),
      localCache.clear(),
      setting.clear(),
      credentials.clear(),
      video.clear(),
      Accounts.clear(),
      watchProgress.clear(),
      ?reply?.clear(),
    ]);
  }

  static int _intStrDescKeyComparator(dynamic k1, dynamic k2) {
    if (k1 is int) {
      if (k2 is int) {
        return k2.compareTo(k1);
      } else {
        return -1;
      }
    } else if (k2 is String) {
      final lenCompare = k2.length.compareTo((k1 as String).length);
      if (lenCompare == 0) {
        return k2.compareTo(k1);
      } else {
        return lenCompare;
      }
    } else {
      return 1;
    }
  }
}
