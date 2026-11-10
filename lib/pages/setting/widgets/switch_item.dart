import 'dart:async' show FutureOr;

import 'package:pili_aurora/common/widgets/dialog/dialog.dart';
import 'package:pili_aurora/common/widgets/flutter/list_tile.dart';
import 'package:pili_aurora/common/widgets/route_aware_mixin.dart';
import 'package:pili_aurora/services/logger.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:material_ui/material_ui.dart' hide ListTile;

class SetSwitchItem extends StatefulWidget {
  final String title;
  final String? subtitle;
  final String setKey;
  final bool defaultVal;
  final FutureOr<void> Function(bool)? onChanged;
  final bool needReboot;
  final Widget? leading;
  final void Function(BuildContext context)? onTap;
  final EdgeInsetsGeometry? contentPadding;
  final TextStyle? titleStyle;
  final bool isSplit;
  final List<Widget> children;

  const SetSwitchItem({
    super.key,
    required this.title,
    this.subtitle,
    required this.setKey,
    this.defaultVal = false,
    this.onChanged,
    this.needReboot = false,
    this.leading,
    this.onTap,
    this.contentPadding,
    this.titleStyle,
    this.isSplit = false,
    this.children = const [],
  });

  @override
  State<SetSwitchItem> createState() => _SetSwitchItemState();
}

class _SetSwitchItemState extends State<SetSwitchItem> {
  late bool val;
  bool _busy = false;
  int _generation = 0;

  void _setVal() {
    val = GStorage.setting.get(widget.setKey, defaultValue: widget.defaultVal);
  }

  @override
  void didUpdateWidget(SetSwitchItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.setKey != widget.setKey) {
      _generation++;
      _busy = false;
      _setVal();
    }
  }

  @override
  void initState() {
    super.initState();
    _setVal();
  }

  Future<void> switchChange([bool? value]) async {
    if (_busy) return;
    final source = widget;
    final generation = _generation;
    final next = value ?? !val;
    final route = ModalRoute.of(context);
    var invalidated = false;
    void onNavigation() {
      if (!identical(routeObserver.currentRoute, route)) invalidated = true;
    }

    bool ownsSource() => mounted && generation == _generation;
    bool canPresent() =>
        ownsSource() && !invalidated && (route?.isCurrent ?? true);
    routeObserver.addNavigationListener(onNavigation);
    setState(() => _busy = true);
    try {
      if (next && source.setKey == SettingBoxKey.badCertificateCallback) {
        final confirmed = await showConfirmDialog(
          context: context,
          title: const Text('确定禁用 SSL 证书验证？'),
          content: const Text('禁用容易受到中间人攻击'),
        );
        if (!confirmed || !canPresent()) return;
      }
      try {
        await GStorage.setting.put(source.setKey, next);
      } catch (error, stackTrace) {
        logger.w('保存设置开关失败', error: error.runtimeType, stackTrace: stackTrace);
        if (canPresent()) SmartDialog.showToast('设置保存失败，请重试');
        return;
      }
      if (ownsSource()) setState(() => val = next);
      // 保存已经确认，应用捕获的原设置回调；新 Widget 不接收旧操作。
      try {
        await source.onChanged?.call(next);
      } catch (error, stackTrace) {
        logger.w('应用设置开关失败', error: error.runtimeType, stackTrace: stackTrace);
        if (canPresent()) SmartDialog.showToast('设置已保存，应用失败，请重启后重试');
        return;
      }
      if (source.needReboot && canPresent()) SmartDialog.showToast('重启生效');
    } finally {
      routeObserver.removeNavigationListener(onNavigation);
      if (ownsSource()) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final titleStyle =
        widget.titleStyle ??
        theme.textTheme.titleMedium!.copyWith(
          color: widget.onTap != null && !val
              ? theme.colorScheme.outline
              : null,
        );
    final subTitleStyle = theme.textTheme.labelMedium!.copyWith(
      color: theme.colorScheme.outline,
    );

    final switchBtn = Transform.scale(
      scale: 0.8,
      alignment: .centerRight,
      child: Switch(
        value: val,
        onChanged: _busy ? null : switchChange,
      ),
    );

    Widget child(Widget? trailing) => ListTile(
      contentPadding: widget.contentPadding,
      enabled: widget.onTap == null ? true : val,
      onTap: _busy
          ? null
          : widget.onTap == null
          ? switchChange
          : () => widget.onTap!(context),
      title: Text(widget.title, style: titleStyle),
      subtitle: widget.subtitle != null
          ? Text(widget.subtitle!, style: subTitleStyle)
          : null,
      leading: widget.leading,
      trailing: trailing,
    );

    final tile = widget.isSplit
        ? Row(
            children: [
              Expanded(child: child(null)),
              SizedBox(
                height: 25,
                child: VerticalDivider(
                  width: 1,
                  color: theme.colorScheme.outline.withValues(alpha: .3),
                ),
              ),
              Padding(
                padding: const .only(left: 4, right: 24),
                child: switchBtn,
              ),
            ],
          )
        : child(switchBtn);
    return widget.children.isEmpty
        ? tile
        : Column(
            children: [tile, if (val) ...widget.children],
          );
  }
}
