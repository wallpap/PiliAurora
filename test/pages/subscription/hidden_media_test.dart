import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:pili_aurora/pages/subscription/hidden_media.dart';

void main() {
  late Directory directory;
  late Box<dynamic> box;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'subscription_hidden_test',
    );
    box = await Hive.openBox<dynamic>('hidden_media', path: directory.path);
  });
  tearDown(() async {
    await box.close();
    await directory.delete(recursive: true);
  });

  test('hidden media persists and is isolated by account, subscription type and id', () async {
    final store = HiddenSubscriptionMedia(box, 100);
    expect(await store.add(21, 1, {(101, 2)}), 1);
    expect(await store.add(21, 1, {(101, 2), (102, 2)}), 1);
    expect(HiddenSubscriptionMedia(box, 200).read(21, 1), isEmpty);
    expect(store.read(11, 1), isEmpty);
    expect(store.read(21, 2), isEmpty);
    await box.close();
    box = await Hive.openBox<dynamic>('hidden_media', path: directory.path);
    expect(HiddenSubscriptionMedia(box, 100).read(21, 1), {'2:101', '2:102'});
  });

  test('cancelling a subscription removes its hidden records without affecting others', () async {
    final store = HiddenSubscriptionMedia(box, 100);
    await store.add(21, 1, {(101, 2)});
    await store.add(21, 2, {(102, 2)});
    await store.remove(21, 1);
    expect(store.read(21, 1), isEmpty);
    expect(store.read(21, 2), {'2:102'});
  });
}
