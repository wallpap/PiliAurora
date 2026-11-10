import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:material_ui/material_ui.dart' hide ListTile;
import 'package:pili_aurora/common/widgets/flutter/list_tile.dart';
import 'package:pili_aurora/common/widgets/route_aware_mixin.dart';
import 'package:pili_aurora/services/logger.dart';
import 'package:pili_aurora/utils/android/bindings.g.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';
import 'package:pili_aurora/utils/storage_pref.dart';

class DocProviderItem extends StatefulWidget {
  const DocProviderItem({
    super.key,
    this.updateProvider = AndroidHelper.updateDocProvider,
  });

  static const title = '允许三方APP访问私有存储';
  static const description = '允许三方APP（例如MT管理器）通过访问外部存储的方式访问私有存储下的文件';

  final ValueChanged<bool> updateProvider;

  @override
  State<DocProviderItem> createState() => _DocProviderItemState();
}

class _DocProviderItemState extends State<DocProviderItem> {
  late bool _savedValue = Pref.enableDocProvider;
  late bool _value = _savedValue;
  bool _busy = false;
  bool _needsSave = false;

  Future<void> _change([bool? next]) async {
    if (_busy) return;
    final route = ModalRoute.of(context);
    var invalidated = false;
    void onNavigation() {
      if (!identical(routeObserver.currentRoute, route)) invalidated = true;
    }

    next = _needsSave ? _value : next ?? !_value;
    String? message;
    setState(() => _busy = true);
    routeObserver.addNavigationListener(onNavigation);
    try {
      try {
        widget.updateProvider(next);
      } catch (error, stackTrace) {
        logger.w(
          '私有存储访问设置失败',
          error: error.runtimeType,
          stackTrace: stackTrace,
        );
        message = _needsSave ? '设置未保存，状态待确认，点击重试' : '设置失败，请重试';
        return;
      }
      _value = next;
      try {
        await GStorage.setting.put(SettingBoxKey.enableDocProvider, next);
        _savedValue = next;
        _needsSave = false;
      } catch (error, stackTrace) {
        logger.w(
          '私有存储访问设置保存失败',
          error: error.runtimeType,
          stackTrace: stackTrace,
        );
        _needsSave = true;
        try {
          // 偏好保存失败时恢复原生状态，使重进页面仍读取相同确认值。
          widget.updateProvider(_savedValue);
          _value = _savedValue;
          _needsSave = false;
        } catch (error, stackTrace) {
          logger.w(
            '私有存储访问设置恢复失败',
            error: error.runtimeType,
            stackTrace: stackTrace,
          );
        }
        message = _needsSave ? '设置未保存，状态待确认，点击重试' : '设置保存失败，请重试';
      }
    } finally {
      routeObserver.removeNavigationListener(onNavigation);
      if (mounted) {
        setState(() => _busy = false);
        if (!invalidated && (route?.isCurrent ?? true) && message != null) {
          SmartDialog.showToast(message);
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      onTap: _busy ? null : _change,
      leading: const Icon(Icons.storage),
      title: Text(DocProviderItem.title, style: theme.textTheme.titleMedium),
      subtitle: Text(
        _needsSave ? '设置未保存，状态待确认，点击重试' : DocProviderItem.description,
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.outline,
        ),
      ),
      trailing: Transform.scale(
        scale: 0.8,
        alignment: .centerRight,
        child: Switch(
          value: _value,
          onChanged: _busy || _needsSave ? null : _change,
        ),
      ),
    );
  }
}
