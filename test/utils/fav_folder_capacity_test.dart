import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/utils/bili_utils.dart';

void main() {
  test('default and custom favorites use their respective capacity limits', () {
    expect(BiliUtils.isFavFolderFull(0, 49999), isFalse);
    expect(BiliUtils.isFavFolderFull(0, 50000), isTrue);
    expect(BiliUtils.isFavFolderFull(2, 999), isFalse);
    expect(BiliUtils.isFavFolderFull(2, 1000), isTrue);
  });
}
