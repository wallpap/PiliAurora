import 'package:pili_aurora/models/common/enum_with_label.dart';

enum ReplyLevelFilter implements EnumWithLabel {
  off('不屏蔽'),
  lv1('Lv1 及以上'),
  lv2('Lv2 及以上'),
  lv3('Lv3 及以上'),
  lv4('Lv4 及以上'),
  lv5('Lv5 及以上'),
  lv6('Lv6 及以上');

  const ReplyLevelFilter(this.label);

  @override
  final String label;
}
