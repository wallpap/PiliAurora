import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';
import 'package:pili_aurora/utils/storage_pref.dart';

/// 本地入口与角标共用偏好，独立于账号的远端消息接收设置。
final disableLikeMessagesProvider = NotifierProvider<DisableLikeMessages, bool>(
  DisableLikeMessages.new,
  isAutoDispose: true,
);

class DisableLikeMessages extends Notifier<bool> {
  @override
  bool build() {
    final subscription = GStorage.setting
        .watch(key: SettingBoxKey.disableLikeMsg)
        .listen((_) => state = Pref.disableLikeMsg);
    ref.onDispose(subscription.cancel);
    return Pref.disableLikeMsg;
  }
}
