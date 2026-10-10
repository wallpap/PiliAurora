import 'package:hive_ce/hive.dart';

/// 隐藏记录按账号、订阅类型和订阅 ID 隔离，不修改远端合集。
class HiddenSubscriptionMedia {
  const HiddenSubscriptionMedia(this.box, this.mid);

  final Box<dynamic> box;
  final int mid;

  String _key(int type, int id) => 'subscriptionHiddenMedia:$mid:$type:$id';

  Set<String> read(int type, int id) => Set<String>.from(
    box.get(_key(type, id), defaultValue: const <String>[]),
  );

  Future<int> add(int type, int id, Set<(int, int)> media) async {
    final hidden = read(type, id);
    final previousCount = hidden.length;
    hidden.addAll(media.map((item) => '${item.$2}:${item.$1}'));
    await box.put(_key(type, id), hidden.toList());
    return hidden.length - previousCount;
  }

  Future<void> remove(int type, int id) => box.delete(_key(type, id));
}
