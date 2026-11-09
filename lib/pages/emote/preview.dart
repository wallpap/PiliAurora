import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/widgets/image/network_img_layer.dart';
import 'package:pili_aurora/common/widgets/loading_widget/loading_widget.dart';
import 'package:pili_aurora/common/widgets/scaffold/simple_scaffold.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/reply.dart';
import 'package:pili_aurora/models/common/image_type.dart';
import 'package:pili_aurora/models/remote/emote/emote.dart';
import 'package:pili_aurora/models/remote/emote/package.dart';
import 'package:pili_aurora/utils/accounts.dart';

class EmotePackagePreviewPage extends StatefulWidget {
  const EmotePackagePreviewPage({super.key, required this.package});

  final Package package;

  @override
  State<EmotePackagePreviewPage> createState() =>
      _EmotePackagePreviewPageState();
}

class _EmotePackagePreviewPageState extends State<EmotePackagePreviewPage> {
  LoadingState<Package> _state = LoadingState.loading();
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(EmotePackagePreviewPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.package.id != widget.package.id) _load();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    final account = Accounts.main;
    final id = widget.package.id;
    if (id == null) {
      setState(() => _state = const Error('表情包信息缺失'));
      return;
    }
    setState(() => _state = LoadingState.loading());
    final result = await ReplyHttp.getEmotePackageDetail(
      packageId: id,
      account: account,
    );
    if (!mounted || generation != _generation) return;
    setState(
      () => _state = identical(account, Accounts.main)
          ? result
          : const Error('账号已切换，请刷新重试'),
    );
  }

  @override
  Widget build(BuildContext context) => SimpleScaffold(
    appBar: AppBar(title: Text(widget.package.text ?? '表情包预览')),
    body: SafeArea(
      top: false,
      child: switch (_state) {
        Loading() => m3eLoading,
        Error(:final errMsg) => Center(
          child: TextButton.icon(
            onPressed: _load,
            icon: const Icon(Icons.refresh),
            label: Text('${errMsg ?? '加载失败'}，点击重试'),
          ),
        ),
        Success(:final response) => _buildEmotes(response),
      },
    ),
  );

  Widget _buildEmotes(Package package) {
    final emotes = package.emote ?? const <Emote>[];
    if (emotes.isEmpty) return const Center(child: Text('暂无可预览的表情'));
    final isTextEmote = package.type == 4;
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 112,
        mainAxisExtent: 110,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: emotes.length,
      itemBuilder: (context, index) {
        final emote = emotes[index];
        return InkWell(
          borderRadius: const BorderRadius.all(Radius.circular(8)),
          onTap: () => showDialog<void>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text(emote.text ?? '表情预览'),
              content: isTextEmote
                  ? Text(emote.text ?? '', style: const TextStyle(fontSize: 32))
                  : NetworkImgLayer(
                      src: emote.url,
                      width: 160,
                      height: 160,
                      type: ImageType.emote,
                      fit: BoxFit.contain,
                    ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('关闭'),
                ),
              ],
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (!isTextEmote) ...[
                  NetworkImgLayer(
                    src: emote.url,
                    width: 48,
                    height: 48,
                    type: ImageType.emote,
                    fit: BoxFit.contain,
                  ),
                  const SizedBox(height: 8),
                ],
                Text(
                  emote.text ?? '',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
