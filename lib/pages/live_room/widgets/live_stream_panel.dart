import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/models/common/video/live_quality.dart';
import 'package:pili_aurora/models/remote/live/live_room_play_info/stream.dart';

typedef LiveStreamSelection = ({int stream, int format, int codec, int url});

class LiveStreamPanel extends StatelessWidget {
  const LiveStreamPanel({
    super.key,
    required this.streams,
    required this.current,
    required this.onSelected,
    required this.onClose,
  });

  final List<Stream> streams;
  final LiveStreamSelection current;
  final ValueChanged<LiveStreamSelection> onSelected;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final routes = [
      for (final (si, stream) in streams.indexed)
        for (final (fi, format) in stream.format.indexed)
          for (final (ci, codec) in format.codec.indexed)
            for (final (ui, _) in codec.urlInfo.indexed)
              (
                selection: (stream: si, format: fi, codec: ci, url: ui),
                detail: [
                  LiveQuality.fromCode(codec.currentQn)?.desc ??
                      '画质 ${codec.currentQn}',
                  if (format.formatName case final name?) name.toUpperCase(),
                  switch (codec.codecName) {
                    'avc' => 'H.264',
                    'hevc' => 'H.265',
                    final name? => name.toUpperCase(),
                    null => '默认编码',
                  },
                ].join(' · '),
              ),
    ];
    final scheme = ColorScheme.of(context);
    final accent = scheme.brightness == Brightness.light
        ? scheme.inversePrimary
        : scheme.primary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 8, 0),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  '播放线路',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IconButton(
                tooltip: '关闭',
                onPressed: onClose,
                icon: const Icon(Icons.close, size: 20, color: Colors.white70),
              ),
            ],
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: Text(
            '卡顿或加载失败时，可以换一条线路。',
            style: TextStyle(color: Colors.white70, fontSize: 13),
          ),
        ),
        const Divider(height: 1, color: Colors.white12),
        if (routes.isEmpty)
          const Padding(
            padding: EdgeInsets.all(20),
            child: Text(
              '暂无可用线路，请刷新直播间后重试。',
              style: TextStyle(color: Colors.white70),
            ),
          )
        else
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: routes.length,
              itemBuilder: (context, index) {
                final route = routes[index];
                final selected = route.selection == current;
                return ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                  selected: selected,
                  selectedTileColor: Colors.white.withValues(alpha: 0.08),
                  leading: Icon(
                    selected ? Icons.check_circle : Icons.alt_route,
                    color: selected ? accent : Colors.white54,
                    size: 21,
                  ),
                  title: Text(
                    '线路 ${index + 1}',
                    style: TextStyle(
                      color: selected ? accent : Colors.white,
                      fontSize: 14,
                    ),
                  ),
                  subtitle: Text(
                    route.detail,
                    style: const TextStyle(
                      color: Colors.white60,
                      fontSize: 12,
                    ),
                  ),
                  trailing: selected
                      ? const Text(
                          '当前使用',
                          style: TextStyle(color: Colors.white70, fontSize: 12),
                        )
                      : null,
                  onTap: selected ? null : () => onSelected(route.selection),
                );
              },
            ),
          ),
      ],
    );
  }
}
