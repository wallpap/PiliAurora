import 'package:pili_aurora/common/widgets/flutter/list_tile.dart';
import 'package:pili_aurora/common/widgets/flutter/refresh_indicator.dart';
import 'package:pili_aurora/common/widgets/loading_widget/http_error.dart';
import 'package:pili_aurora/common/widgets/scaffold/simple_scaffold.dart';
import 'package:pili_aurora/common/widgets/view_sliver_safe_area.dart';
import 'package:pili_aurora/http/loading_state.dart' show Error;
import 'package:pili_aurora/models/remote/login_devices/device.dart';
import 'package:pili_aurora/pages/login_devices/controller.dart';
import 'package:pili_aurora/utils/extension/widget_ext.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart' hide ListTile;

class LoginDevicesPage extends ConsumerWidget {
  const LoginDevicesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshot = ref.watch(loginDevicesProvider);
    Future<void> reload() => ref
        .refresh(loginDevicesProvider.future)
        .then<void>((_) {}, onError: (Object _, StackTrace _) {});

    final colorScheme = Theme.of(context).colorScheme;
    return SimpleScaffold(
      appBar: AppBar(title: const Text('登录设备')),
      body: refreshIndicator(
        onRefresh: reload,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            ViewSliverSafeArea(
              sliver: snapshot.isLoading
                  ? const SliverToBoxAdapter()
                  : snapshot.hasError
                  ? HttpError(
                      errMsg: (snapshot.error is Error
                          ? (snapshot.error as Error).errMsg
                          : '加载失败，请重试'),
                      onReload: reload,
                    )
                  : _buildBody(colorScheme, snapshot.requireValue, reload),
            ),
          ],
        ),
      ).constraintWidth(),
    );
  }

  Widget _buildBody(
    ColorScheme colorScheme,
    List<LoginDevice> response,
    Future<void> Function() reload,
  ) {
    if (response.isNotEmpty) {
      final divider = Divider(
        height: 1,
        color: colorScheme.outline.withValues(alpha: 0.1),
      );
      return SliverList.separated(
        itemBuilder: (context, index) =>
            _buildItem(colorScheme, response[index]),
        itemCount: response.length,
        separatorBuilder: (_, _) => divider,
      );
    }
    return HttpError(onReload: reload);
  }

  Widget _buildItem(ColorScheme colorScheme, LoginDevice item) {
    final style = TextStyle(fontSize: 13, color: colorScheme.outline);
    return ListTile(
      dense: true,
      title: Text(
        item.deviceName ?? '',
        style: const TextStyle(fontSize: 14),
      ),
      subtitle: Text(
        '${item.latestLoginAt} ${item.source}',
        style: style,
      ),
      trailing: item.isCurrentDevice == true
          ? Text('(本机)', style: style)
          : null,
    );
  }
}
