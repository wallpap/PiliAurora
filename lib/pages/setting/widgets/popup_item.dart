import 'dart:async';

import 'package:pili_aurora/pages/setting/widgets/setting_save.dart';

import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:pili_aurora/services/logger.dart';
import 'package:pili_aurora/common/widgets/app_select_field.dart';
import 'package:pili_aurora/common/widgets/flutter/list_tile.dart';
import 'package:material_ui/material_ui.dart' hide ListTile;

typedef PopupMenuItemSelected<T> = FutureOr<void> Function(
  T value,
  VoidCallback setState,
);

class PopupListTile<T> extends StatefulWidget {
  const PopupListTile({
    super.key,
    this.dense,
    this.safeArea = true,
    this.enabled = true,
    this.leading,
    required this.title,
    required this.value,
    required this.options,
    required this.onSelected,
    this.contentPadding,
    this.titleStyle,
  });

  final bool? dense;
  final bool safeArea;
  final bool enabled;
  final Widget? leading;
  final String title;

  final ValueGetter<(T, String)> value;
  final List<(T, String)> options;
  final PopupMenuItemSelected<T> onSelected;
  final EdgeInsetsGeometry? contentPadding;
  final TextStyle? titleStyle;

  @override
  State<PopupListTile<T>> createState() => _PopupListTileState<T>();
}

class _PopupListTileState<T> extends State<PopupListTile<T>> {
  final _menuController = MenuController();
  bool _busy = false;

  Future<void> _select(T value) async {
    if (_busy) return;
    final source = widget;
    setState(() => _busy = true);
    try {
      bool isCurrent() =>
          mounted &&
          identical(widget, source) &&
          (ModalRoute.of(context)?.isCurrent ?? true);
      await withSettingPresentation(
        isCurrent,
        () => source.onSelected(value, () {
          if (mounted && identical(widget, source)) _refresh();
        }),
      );
    } catch (error, stack) {
      logger.w('设置选择失败', error: error.runtimeType, stackTrace: stack);
      if (mounted &&
          identical(widget, source) &&
          (ModalRoute.of(context)?.isCurrent ?? true)) {
        SmartDialog.showToast('设置保存失败，请重试');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _refresh() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (value, descStr) = widget.value();
    final enabled = widget.enabled && !_busy && widget.options.isNotEmpty;
    return ListTile(
      dense: widget.dense,
      safeArea: widget.safeArea,
      enabled: enabled,
      contentPadding: widget.contentPadding,
      onTap: enabled
          ? () {
              if (_menuController.isOpen) {
                _menuController.close();
              } else {
                _menuController.open();
              }
            }
          : null,
      leading: widget.leading,
      title: Text(widget.title),
      titleTextStyle: widget.titleStyle ?? theme.textTheme.titleMedium,
      trailing: AppSelectField<T>(
        controller: _menuController,
        consumeOutsideTap: true,
        value: value,
        label: widget.title,
        selectedLabel: descStr,
        options: widget.options,
        enabled: enabled,
        onSelected: (newValue) {
          if (newValue != value) _select(newValue);
        },
      ),
    );
  }
}
