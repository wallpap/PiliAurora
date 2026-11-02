import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/services/settings/backup_cipher.dart';

Future<String?> requestBackupPassword(
  BuildContext context, {
  required bool creating,
}) => showDialog<String>(
  context: context,
  builder: (_) => _BackupPasswordDialog(creating: creating),
);

class _BackupPasswordDialog extends StatefulWidget {
  const _BackupPasswordDialog({required this.creating});
  final bool creating;

  @override
  State<_BackupPasswordDialog> createState() => _BackupPasswordDialogState();
}

class _BackupPasswordDialogState extends State<_BackupPasswordDialog> {
  final controller = TextEditingController();
  final confirmation = TextEditingController();
  final form = GlobalKey<FormState>();
  @override
  void dispose() {
    controller.dispose();
    confirmation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.creating ? '设置备份密码' : '输入备份密码'),
    content: Form(
      key: form,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('跨设备恢复时需要此密码，请妥善保存。'),
          TextFormField(
            controller: controller,
            obscureText: true,
            autofocus: true,
            decoration: const InputDecoration(labelText: '备份密码'),
            validator: (value) => widget.creating && (value?.length ?? 0) < 8
                ? '至少输入 8 个字符'
                : null,
          ),
          if (widget.creating)
            TextFormField(
              controller: confirmation,
              obscureText: true,
              decoration: const InputDecoration(labelText: '确认密码'),
              validator: (value) => value != controller.text ? '两次密码不一致' : null,
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      TextButton(
        onPressed: () {
          if (form.currentState!.validate()) {
            Navigator.pop(context, controller.text);
          }
        },
        child: const Text('确定'),
      ),
    ],
  );
}

Future<dynamic> decodeBackup(
  BuildContext context,
  dynamic document,
  String kind,
) async {
  if (!BackupCipher.isEncrypted(document)) return document;
  final password = await requestBackupPassword(context, creating: false);
  if (password == null) throw StateError('已取消导入');
  return BackupCipher.decrypt(document as Map, password, kind);
}
