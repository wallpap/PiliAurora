import 'dart:async';

import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:pili_aurora/services/logger.dart';
import 'package:pili_aurora/pages/setting/widgets/setting_save.dart';

import 'package:pili_aurora/common/widgets/flutter/list_tile.dart';
import 'package:material_ui/material_ui.dart' hide ListTile;

class NormalItem extends StatefulWidget {
  final String? title;
  final ValueGetter<String>? getTitle;
  final String? subtitle;
  final ValueGetter<String>? getSubtitle;
  final Widget? leading;
  final Widget Function(ThemeData theme)? getTrailing;
  final FutureOr<void> Function(BuildContext context, VoidCallback setState)?
  onTap;
  final EdgeInsetsGeometry? contentPadding;
  final TextStyle? titleStyle;

  const NormalItem({
    this.title,
    this.getTitle,
    this.subtitle,
    this.getSubtitle,
    this.leading,
    this.getTrailing,
    this.onTap,
    this.contentPadding,
    this.titleStyle,
    super.key,
  }) : assert(title != null || getTitle != null);

  @override
  State<NormalItem> createState() => _NormalItemState();
}

class _NormalItemState extends State<NormalItem> {
  bool _busy = false;

  Future<void> _activate() async {
    if (_busy) return;
    final source = widget;
    setState(() => _busy = true);
    try {
      bool isCurrent() =>
          mounted &&
          identical(widget, source) &&
          (ModalRoute.of(context)?.isCurrent ?? false);
      await withSettingPresentation(
        isCurrent,
        () => source.onTap!(context, () {
          if (mounted && identical(widget, source)) refresh();
        }),
      );
    } catch (error, stackTrace) {
      logger.w('执行设置操作失败', error: error.runtimeType, stackTrace: stackTrace);
      if (mounted &&
          identical(widget, source) &&
          (ModalRoute.of(context)?.isCurrent ?? false)) {
        SmartDialog.showToast('设置保存失败，请重试');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    late final theme = Theme.of(context);
    Widget? subtitle;
    if ((widget.subtitle ?? widget.getSubtitle?.call()) case final text?) {
      subtitle = Text(
        text,
        style: theme.textTheme.labelMedium!.copyWith(
          color: theme.colorScheme.outline,
        ),
      );
    }
    return ListTile(
      contentPadding: widget.contentPadding,
      onTap: widget.onTap == null || _busy ? null : _activate,
      title: Text(
        widget.title ?? widget.getTitle!(),
        style: widget.titleStyle ?? theme.textTheme.titleMedium!,
      ),
      subtitle: subtitle,
      leading: widget.leading,
      trailing: widget.getTrailing?.call(theme),
    );
  }

  void refresh() {
    if (mounted) {
      setState(() {});
    }
  }
}
