import 'package:pili_aurora/common/widgets/loading_widget/http_error.dart';
import 'package:pili_aurora/common/widgets/loading_widget/loading_widget.dart';
import 'package:pili_aurora/common/widgets/scaffold/simple_scaffold.dart';
import 'package:pili_aurora/common/widgets/view_sliver_safe_area.dart';
import 'package:pili_aurora/pages/dlna/controller.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class DLNAPage extends StatefulWidget {
  const DLNAPage({super.key});

  @override
  State<DLNAPage> createState() => _DLNAPageState();
}

class _DLNAPageState extends State<DLNAPage> {
  final _controller = DlnaController();
  late final _url = Get.parameters['url'] ?? '';
  late final _title = Get.parameters['title'];

  @override
  void initState() {
    super.initState();
    _controller.addListener(_changed);
    _controller.search();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.of(context);
    return SimpleScaffold(
      appBar: AppBar(
        title: const Text('投屏'),
        actions: [
          IconButton(
            tooltip: '搜索',
            onPressed: _controller.searching || _controller.connecting
                ? null
                : _controller.search,
            icon: const Icon(Icons.refresh),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: CustomScrollView(
        slivers: [
          if (_controller.searching || _controller.connecting) linearLoading,
          if (_controller.searchError case final error?)
            if (_controller.devices.isNotEmpty)
              SliverToBoxAdapter(child: ListTile(title: Text(error))),
          ViewSliverSafeArea(sliver: _buildBody(colorScheme)),
        ],
      ),
    );
  }

  Widget _buildBody(ColorScheme colorScheme) {
    final devices = _controller.devices;
    if (!_controller.searching && devices.isEmpty) {
      return HttpError(
        errMsg: _controller.searchError ?? '没有设备',
        onReload: _controller.search,
      );
    }
    if (devices.isNotEmpty) {
      final keys = devices.keys.toList();
      return SliverList.builder(
        itemCount: keys.length,
        itemBuilder: (context, index) {
          final key = keys[index];
          final device = devices[key]!;
          final isCurr = key == _controller.selectedKey;
          return ListTile(
            enabled: !_controller.connecting,
            title: Text(
              device.info.friendlyName,
              style: isCurr ? TextStyle(color: colorScheme.primary) : null,
            ),
            subtitle: Text(key),
            onTap: () async {
              if (isCurr) return;
              final route = ModalRoute.of(context);
              bool current() => mounted && route?.isCurrent == true;
              final result = await _controller.connect(
                key: key,
                url: _url,
                title: _title ?? '',
                isCurrent: current,
              );
              if (current() && !result.isSuccess) result.toast();
            },
          );
        },
      );
    }
    return const SliverToBoxAdapter();
  }
}
