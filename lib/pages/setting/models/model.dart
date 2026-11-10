import 'dart:async' show FutureOr;

import 'package:pili_aurora/common/widgets/route_aware_mixin.dart';
import 'package:pili_aurora/common/widgets/scaffold/simple_scaffold.dart';
import 'package:pili_aurora/models/common/enum_with_label.dart';
import 'package:pili_aurora/pages/setting/widgets/normal_item.dart';
import 'package:pili_aurora/pages/setting/widgets/popup_item.dart';
import 'package:pili_aurora/pages/setting/widgets/select_dialog.dart';
import 'package:pili_aurora/pages/setting/widgets/switch_item.dart';
import 'package:pili_aurora/pages/setting/widgets/setting_input_dialog.dart';
import 'package:pili_aurora/services/logger.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:material_ui/material_ui.dart' hide PopupMenuItemSelected;

@immutable
sealed class SettingsModel {
  final String? subtitle;
  final Widget? leading;
  final EdgeInsetsGeometry? contentPadding;
  final TextStyle? titleStyle;

  String? get title;
  Widget get widget;
  String get effectiveTitle;
  String? get effectiveSubtitle;
  Iterable<SettingsModel> get searchableItems => [this];

  const SettingsModel({
    this.subtitle,
    this.leading,
    this.contentPadding,
    this.titleStyle,
  });
}

/// 分类本身也是设置项，页面与搜索沿同一棵树访问实际设置。
class SettingsGroup extends SettingsModel {
  const SettingsGroup({
    required this.title,
    required this.children,
    super.subtitle,
    super.leading,
  });

  @override
  final String title;
  final List<SettingsModel> children;

  @override
  String get effectiveTitle => title;
  @override
  String? get effectiveSubtitle => subtitle;
  @override
  Iterable<SettingsModel> get searchableItems sync* {
    yield this;
    for (final child in children) {
      yield* child.searchableItems;
    }
  }

  @override
  Widget get widget => NormalItem(
    title: title,
    subtitle: subtitle,
    leading: leading,
    getTrailing: (_) => const Icon(Icons.chevron_right),
    onTap: (context, _) => Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SimpleScaffold(
          appBar: AppBar(title: Text(title)),
          body: ListView(
            padding: EdgeInsets.only(
              bottom: MediaQuery.viewPaddingOf(context).bottom + 32,
            ),
            children: [for (final child in children) child.widget],
          ),
        ),
      ),
    ),
  );
}

class SplitModel extends SettingsModel {
  const SplitModel({
    super.contentPadding,
    super.titleStyle,
    required this.normalModel,
    required this.switchModel,
  });

  @override
  String? get effectiveSubtitle => normalModel.effectiveSubtitle;

  @override
  String get effectiveTitle => normalModel.effectiveTitle;

  @override
  String? get title => normalModel.title;

  final NormalModel normalModel;

  final SwitchModel switchModel;

  @override
  Widget get widget => SetSwitchItem(
    title: effectiveTitle,
    subtitle: effectiveSubtitle,
    setKey: switchModel.setKey,
    defaultVal: switchModel.defaultVal,
    onChanged: switchModel.onChanged,
    needReboot: switchModel.needReboot,
    leading: normalModel.leading,
    onTap: switchModel.onTap,
    contentPadding: contentPadding,
    titleStyle: titleStyle,
    isSplit: true,
    children: [for (final child in switchModel.children) child.widget],
  );
}

class PopupModel<T extends EnumWithLabel> extends SettingsModel {
  const PopupModel({
    required this.title,
    super.leading,
    super.contentPadding,
    super.titleStyle,
    required this.value,
    required this.items,
    required this.onSelected,
  });

  @override
  String? get effectiveSubtitle => null;

  @override
  String get effectiveTitle => title;

  @override
  final String title;

  final ValueGetter<T> value;
  final Iterable<T> items;
  final PopupMenuItemSelected<T> onSelected;

  @override
  Widget get widget => PopupListTile<T>(
    safeArea: false,
    leading: leading,
    title: title,
    contentPadding: contentPadding,
    titleStyle: titleStyle,
    value: () {
      final v = value();
      return (v, v.label);
    },
    options: items.map((item) => (item, item.label)).toList(),
    onSelected: onSelected,
  );
}

class NormalModel extends SettingsModel {
  @override
  final String? title;
  final ValueGetter<String>? getTitle;
  final ValueGetter<String>? getSubtitle;
  final Widget Function(ThemeData theme)? getTrailing;
  final FutureOr<void> Function(BuildContext context, VoidCallback setState)?
  onTap;

  const NormalModel({
    super.subtitle,
    super.leading,
    super.contentPadding,
    super.titleStyle,
    this.title,
    this.getTitle,
    this.getSubtitle,
    this.getTrailing,
    this.onTap,
  }) : assert(title != null || getTitle != null);

  const NormalModel.split({
    super.subtitle,
    super.leading,
    super.contentPadding,
    super.titleStyle,
    this.title,
    this.getTitle,
    this.getSubtitle,
    this.getTrailing,
  }) : onTap = null,
       assert(title != null || getTitle != null);

  @override
  String get effectiveTitle => title ?? getTitle!();
  @override
  String? get effectiveSubtitle => subtitle ?? getSubtitle?.call();

  @override
  Widget get widget => NormalItem(
    title: title,
    getTitle: getTitle,
    subtitle: subtitle,
    getSubtitle: getSubtitle,
    leading: leading,
    getTrailing: getTrailing,
    onTap: onTap,
    contentPadding: contentPadding,
    titleStyle: titleStyle,
  );
}

class SwitchModel extends SettingsModel {
  @override
  final String? title;
  final String setKey;
  final bool defaultVal;
  final FutureOr<void> Function(bool)? onChanged;
  final bool needReboot;
  final void Function(BuildContext context)? onTap;
  final List<SettingsModel> children;

  const SwitchModel({
    super.subtitle,
    super.leading,
    super.contentPadding,
    super.titleStyle,
    required String this.title,
    required this.setKey,
    this.defaultVal = false,
    this.onChanged,
    this.needReboot = false,
    this.onTap,
    this.children = const [],
  });

  const SwitchModel.split({
    required this.setKey,
    this.defaultVal = false,
    this.needReboot = false,
    this.onChanged,
    this.onTap,
    this.children = const [],
  }) : title = null;

  @override
  String get effectiveTitle => title!;
  @override
  String? get effectiveSubtitle => subtitle;

  @override
  Iterable<SettingsModel> get searchableItems sync* {
    yield this;
    for (final child in children) {
      yield* child.searchableItems;
    }
  }

  @override
  Widget get widget => SetSwitchItem(
    title: title!,
    subtitle: subtitle,
    setKey: setKey,
    defaultVal: defaultVal,
    onChanged: onChanged,
    needReboot: needReboot,
    leading: leading,
    onTap: onTap,
    contentPadding: contentPadding,
    titleStyle: titleStyle,
    children: [for (final child in children) child.widget],
  );
}

// 编辑弹窗不改变 PageRoute；离开页面后永久废弃该次交互。
class _SettingEdit {
  _SettingEdit(this.context)
    : source = context.widget,
      route = ModalRoute.of(context) {
    routeObserver.addNavigationListener(_onNavigation);
  }

  final BuildContext context;
  final Widget source;
  final Route<dynamic>? route;
  bool _invalidated = false;

  void _onNavigation() {
    if (!identical(routeObserver.currentRoute, route)) _invalidated = true;
  }

  bool get isCurrent =>
      !_invalidated && context.mounted && identical(context.widget, source);

  void close() => routeObserver.removeNavigationListener(_onNavigation);

  void apply(VoidCallback callback) {
    try {
      callback();
    } catch (error, stackTrace) {
      logger.w('应用已保存的设置失败', error: error.runtimeType, stackTrace: stackTrace);
      if (isCurrent) SmartDialog.showToast('设置已保存，应用失败，请重启后重试');
    }
  }
}

SettingsModel getBanWordModel({
  required String title,
  required String key,
  required ValueChanged<RegExp> onChanged,
}) {
  String banWord = GStorage.setting.get(key, defaultValue: '');
  bool editing = false;
  return NormalModel(
    leading: const Icon(Icons.filter_alt_outlined),
    title: title,
    getSubtitle: () => banWord.isEmpty ? '点击添加' : banWord,
    onTap: (context, setState) async {
      if (editing) return;
      editing = true;
      final edit = _SettingEdit(context);
      try {
        await showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (_) => SettingInputDialog<RegExp>(
            title: title,
            initialValue: banWord,
            description: '使用|隔开，如：尝试|测试',
            parse: (value) => RegExp(value, caseSensitive: false),
            validationMessage: '请输入有效的正则表达式',
            isCurrent: () => edit.isCurrent,
            save: (pattern) async {
              await GStorage.setting.put(key, pattern.pattern);
              banWord = pattern.pattern;
              edit.apply(() => onChanged(pattern));
              setState();
            },
          ),
        );
      } finally {
        edit.close();
        editing = false;
      }
    },
  );
}

SettingsModel getVideoFilterSelectModel({
  required String title,
  String? subtitle,
  String? suffix,
  required String key,
  required List<int> values,
  int defaultValue = 0,
  bool isFilter = true,
  ValueChanged<int>? onChanged,
}) {
  assert(!isFilter || onChanged != null);
  int value = GStorage.setting.get(key, defaultValue: defaultValue);
  bool editing = false;
  return NormalModel(
    title: '$title${isFilter ? '过滤' : ''}',
    leading: const Icon(Icons.timelapse_outlined),
    subtitle: subtitle,
    getSubtitle: subtitle == null
        ? () => isFilter
              ? '过滤掉$title小于「$value${suffix ?? ""}」的视频'
              : '当前$title:「$value${suffix ?? ""}」'
        : null,
    onTap: (context, setState) async {
      if (editing) return;
      editing = true;
      final edit = _SettingEdit(context);
      Future<void> save(int next) async {
        await GStorage.setting.put(key, next);
        value = next;
        edit.apply(() => onChanged?.call(next));
        setState();
      }

      try {
        final choices = {...values, value}.toList()..sort();
        final result = await showDialog<int>(
          context: context,
          builder: (_) => SelectDialog<int>(
            title: '选择$title${isFilter ? '（0即不过滤）' : ''}',
            value: value,
            values: [
              for (final choice in choices)
                (choice, suffix == null ? '$choice' : '$choice $suffix'),
              (-1, '自定义'),
            ],
          ),
        );
        if (result == null || !context.mounted || !edit.isCurrent) return;
        if (result == -1) {
          await showDialog<void>(
            context: context,
            barrierDismissible: false,
            builder: (_) => SettingInputDialog<int>(
              title: '自定义$title',
              initialValue: '',
              suffix: suffix,
              numeric: true,
              parse: int.parse,
              validationMessage: '请输入有效的非负整数',
              isCurrent: () => edit.isCurrent,
              save: save,
            ),
          );
        } else {
          try {
            await save(result);
          } catch (error, stackTrace) {
            logger.w(
              '保存数字设置失败',
              error: error.runtimeType,
              stackTrace: stackTrace,
            );
            if (edit.isCurrent) SmartDialog.showToast('设置保存失败，请重试');
          }
        }
      } finally {
        edit.close();
        editing = false;
      }
    },
  );
}
