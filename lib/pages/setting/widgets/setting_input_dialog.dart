import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/style.dart';
import 'package:pili_aurora/services/logger.dart';

/// 输入与保存由弹窗持有，失败时保留草稿供用户修改或重试。
class SettingInputDialog<T> extends StatefulWidget {
  const SettingInputDialog({
    super.key,
    required this.title,
    required this.initialValue,
    required this.parse,
    required this.validationMessage,
    required this.save,
    required this.isCurrent,
    this.description,
    this.suffix,
    this.numeric = false,
  });

  final String title;
  final String initialValue;
  final T Function(String) parse;
  final String validationMessage;
  final Future<void> Function(T) save;
  final bool Function() isCurrent;
  final String? description;
  final String? suffix;
  final bool numeric;

  @override
  State<SettingInputDialog<T>> createState() => _SettingInputDialogState<T>();
}

class _SettingInputDialogState<T> extends State<SettingInputDialog<T>> {
  late String _draft = widget.initialValue;
  String? _error;
  bool _busy = false;

  Future<void> _save() async {
    if (_busy) return;
    if (!widget.isCurrent()) {
      setState(() => _error = '页面已变化，请重新打开设置');
      return;
    }
    final T value;
    try {
      value = widget.parse(_draft);
    } on FormatException {
      setState(() => _error = widget.validationMessage);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.save(value);
      if (mounted && (ModalRoute.of(context)?.isCurrent ?? false)) {
        Navigator.of(context).pop();
      }
    } catch (error, stackTrace) {
      logger.w('保存设置输入失败', error: error.runtimeType, stackTrace: stackTrace);
      if (mounted && widget.isCurrent()) {
        setState(() => _error = '保存失败，请重试');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      constraints: Style.dialogFixedConstraints,
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.description case final description?) Text(description),
          TextFormField(
            initialValue: widget.initialValue,
            autofocus: true,
            enabled: !_busy,
            minLines: 1,
            maxLines: widget.numeric ? 1 : 4,
            keyboardType: widget.numeric ? TextInputType.number : null,
            inputFormatters: widget.numeric
                ? [FilteringTextInputFormatter.digitsOnly]
                : null,
            decoration: InputDecoration(
              suffixText: widget.suffix,
              errorText: _error,
            ),
            onChanged: (value) => _draft = value,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: _busy ? null : _save,
          child: const Text('保存'),
        ),
      ],
    ),
  );
}
