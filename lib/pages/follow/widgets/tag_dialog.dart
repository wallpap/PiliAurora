import 'package:flutter/services.dart' show LengthLimitingTextInputFormatter;
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/widgets/dialog/dialog.dart';

Future<String?> showFollowTagNameDialog(
  BuildContext context, {
  String? name,
}) async {
  var value = name ?? '';
  final confirmed = await showConfirmDialog(
    context: context,
    title: Text(name == null ? '新建分组' : '编辑分组名称'),
    content: TextFormField(
      autofocus: true,
      initialValue: value,
      onChanged: (text) => value = text,
      inputFormatters: [LengthLimitingTextInputFormatter(16)],
      decoration: const InputDecoration(border: OutlineInputBorder()),
    ),
  );
  return confirmed && value.trim().isNotEmpty ? value.trim() : null;
}
