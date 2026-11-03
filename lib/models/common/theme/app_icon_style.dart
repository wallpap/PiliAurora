import 'package:pili_aurora/models/common/enum_with_label.dart';

enum AppIconStyle implements EnumWithLabel {
  chibi('星光斜向（默认）'),
  upright('星光竖向'),
  tilted('星光侧倾'),
  portrait('原版头像');

  const AppIconStyle(this.label);
  @override
  final String label;
}
